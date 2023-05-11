import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'ansi.dart';
import 'database.dart';
import 'irc.dart';
import 'logging.dart';
import 'models.dart';

var _nextId = 1;
const _maxId = 0x7FFFFFFF; // 2^31 - 1

class _NotificationChannel {
	final String id;
	final String name;
	final String? description;

	_NotificationChannel({ required this.id, required this.name, this.description });
}

class _ActiveNotification {
	final int id;
	final String tag;
	final String title;
	final MessagingStyleInformation? messagingStyleInfo;

	_ActiveNotification(this.id, this.tag, this.title, this.messagingStyleInfo);
}

class NotificationController {
	final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
	final StreamController<String?> _selectionsController = StreamController(sync: true);
	List<_ActiveNotification> _active = [];

	static NotificationController? _instance;

	Stream<String?> get selections => _selectionsController.stream;

	NotificationController._();

	Future<void> _init() async {
		await _plugin.initialize(InitializationSettings(
			iOS: DarwinInitializationSettings(
				requestAlertPermission: true,
				requestBadgePermission: true,
				requestSoundPermission: true,
			),
			linux: LinuxInitializationSettings(defaultActionName: 'Open'),
			android: AndroidInitializationSettings('ic_stat_name'),
		), onDidReceiveNotificationResponse: _handleNotificationResponse);

		var androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
		if (androidPlugin != null) {
			try {
				var activeNotifs = await androidPlugin.getActiveNotifications();
				_populateActive(androidPlugin, activeNotifs);
			} on Exception catch (err) {
				log.print('Failed to list active notifications', error: err);
			}
		}
	}

	static Future<NotificationController> init() async {
		// Use a singleton because flutter_local_notifications gets confused
		// when initialized multiple times per Isolate
		if (_instance == null) {
			_instance = NotificationController._();
			await _instance!._init();
		}
		return _instance!;
	}

	Future<String?> getLaunchSelection() async {
		NotificationAppLaunchDetails? launchDetails;
		try {
			launchDetails = await _plugin.getNotificationAppLaunchDetails();
		} on UnimplementedError {
			// Ignore
		}
		if (launchDetails == null || !launchDetails.didNotificationLaunchApp) {
			return null;
		}
		return launchDetails.notificationResponse?.payload;
	}

	void _populateActive(AndroidFlutterLocalNotificationsPlugin androidPlugin, List<ActiveNotification> activeNotifs) async {
		for (var notif in activeNotifs) {
			if (notif.id == null) {
				continue; // not created by the flutter_local_notifications plugin
			}

			if (_nextId <= notif.id!) {
				_nextId = notif.id! + 1;
				_nextId = _nextId % _maxId;
			}

			if (notif.tag == null || notif.title == null) {
				log.print('Found an active notification without a tag or title');
				continue;
			}

			MessagingStyleInformation? messagingStyleInfo;
			try {
				messagingStyleInfo = await androidPlugin.getActiveNotificationMessagingStyle(notif.id!, tag: notif.tag);
			} on Exception catch (err) {
				log.print('Failed to get active notification messaging style', error: err);
			}

			_active.add(_ActiveNotification(notif.id!, notif.tag!, notif.title!, messagingStyleInfo));
		}
	}

	void _handleNotificationResponse(NotificationResponse resp) {
		_selectionsController.add(resp.payload);
	}

	String _bufferTag(BufferModel buffer) {
		return 'buffer:${buffer.id}';
	}

	Future<void> showDirectMessage(List<MessageEntry> entries, BufferModel buffer) async {
		var entry = entries.first;
		String tag = _bufferTag(buffer);
		_ActiveNotification? replace = _getActiveWithTag(tag);

		String title;
		if (replace == null) {
			title = 'New message from ${entry.msg.source!.name}';
		} else {
			title = _incrementTitleCount(replace.title, entries.length, ' messages from ${entry.msg.source!.name}');
		}

		List<Message> messages = replace?.messagingStyleInfo?.messages ?? [];
		messages.addAll(entries.map(_buildMessage));

		await _show(
			title: title,
			body: _getMessageBody(entry),
			channel: _NotificationChannel(
				id: 'privmsg',
				name: 'Private messages',
				description: 'Private messages sent directly to you',
			),
			dateTime: entry.dateTime,
			messagingStyleInfo: _buildMessagingStyleInfo(messages, buffer, false),
			tag: _bufferTag(buffer),
		);
	}

	Future<void> showHighlight(List<MessageEntry> entries, BufferModel buffer) async {
		var entry = entries.first;
		String tag = _bufferTag(buffer);
		_ActiveNotification? replace = _getActiveWithTag(tag);

		String title;
		if (replace == null) {
			title = '${entry.msg.source!.name} mentionned you in ${buffer.name}';
		} else {
			title = _incrementTitleCount(replace.title, entries.length, ' mentions in ${buffer.name}');
		}

		List<Message> messages = replace?.messagingStyleInfo?.messages ?? [];
		messages.addAll(entries.map(_buildMessage));

		await _show(
			title: title,
			body: _getMessageBody(entry),
			channel: _NotificationChannel(
				id: 'highlight',
				name: 'Mentions',
				description: 'Messages mentionning your nickname in a channel',
			),
			dateTime: entry.dateTime,
			messagingStyleInfo: _buildMessagingStyleInfo(messages, buffer, true),
			tag: _bufferTag(buffer),
		);
	}

	Future<void> showInvite(IrcMessage msg, NetworkModel network) async {
		assert(msg.cmd == 'INVITE');
		var channel = msg.params[1];

		await _show(
			title: '${msg.source!.name} invited you to $channel',
			channel: _NotificationChannel(
				id: 'invite',
				name: 'Invitations',
				description: 'Invitations to join a channel',
			),
			tag: 'invite:${network.networkEntry.id}:$channel',
		);
	}

	String _incrementTitleCount(String title, int incr, String suffix) {
		int total;
		if (!title.endsWith(suffix)) {
			total = 1;
		} else {
			total = int.parse(title.substring(0, title.length - suffix.length));
		}
		total += incr;
		return '$total$suffix';
	}

	MessagingStyleInformation _buildMessagingStyleInfo(List<Message> messages, BufferModel buffer, bool isChannel) {
		// TODO: Person.key, Person.bot, Person.uri
		return MessagingStyleInformation(
			Person(name: buffer.name),
			conversationTitle: buffer.name,
			groupConversation: isChannel,
			messages: messages,
		);
	}

	Message _buildMessage(MessageEntry entry) {
		return Message(
			_getMessageBody(entry),
			entry.dateTime,
			Person(name: entry.msg.source!.name),
		);
	}

	String _getMessageBody(MessageEntry entry) {
		var sender = entry.msg.source!.name;
		var ctcp = CtcpMessage.parse(entry.msg);
		if (ctcp == null) {
			return stripAnsiFormatting(entry.msg.params[1]);
		}
		if (ctcp.cmd == 'ACTION') {
			var action = stripAnsiFormatting(ctcp.param ?? '');
			return '$sender $action';
		} else {
			return '$sender has sent a CTCP "${ctcp.cmd}" command';
		}
	}

	Future<void> cancelAllWithBuffer(BufferModel buffer) async {
		await _cancelAllWithTag(_bufferTag(buffer));
	}

	Future<void> _cancelAllWithTag(String tag) async {
		List<Future<void>> futures = [];
		List<_ActiveNotification> others = [];
		for (var notif in _active) {
			if (notif.tag == tag) {
				futures.add(_plugin.cancel(notif.id, tag: notif.tag));
			} else {
				others.add(notif);
			}
		}
		_active = others;
		await Future.wait(futures);
	}

	_ActiveNotification? _getActiveWithTag(String tag) {
		for (var notif in _active) {
			if (notif.tag == tag) {
				return notif;
			}
		}
		return null;
	}

	bool _isIdAvailable(int id) {
		for (var notif in _active) {
			if (notif.id == id) {
				return false;
			}
		}
		return true;
	}

	Future<void> _show({
		required String title,
		String? body,
		required _NotificationChannel channel,
		required String tag,
		DateTime? dateTime,
		MessagingStyleInformation? messagingStyleInfo,
	}) async {
		_ActiveNotification? replace = _getActiveWithTag(tag);
		int id;
		if (replace != null) {
			_active.remove(replace);
			id = replace.id;
		} else {
			while (true) {
				id = _nextId++;
				_nextId = _nextId % _maxId;
				if (_isIdAvailable(id)) {
					break;
				}
			}
		}
		_active.add(_ActiveNotification(id, tag, title, messagingStyleInfo));

		await _plugin.show(id, title, body, NotificationDetails(
			linux: LinuxNotificationDetails(
				category: LinuxNotificationCategory.imReceived,
			),
			android: AndroidNotificationDetails(channel.id, channel.name,
				channelDescription: channel.description,
				importance: Importance.high,
				priority: Priority.high,
				category: AndroidNotificationCategory.message,
				when: dateTime?.millisecondsSinceEpoch,
				styleInformation: messagingStyleInfo,
				tag: tag,
				enableLights: true,
			),
		), payload: tag);
	}
}
