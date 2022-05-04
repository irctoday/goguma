import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'database.dart';
import 'irc.dart';
import 'models.dart';

var _nextId = 1;

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

	Stream<String?> get selections => _selectionsController.stream;

	Future<String?> initialize() async {
		await _plugin.initialize(InitializationSettings(
			linux: LinuxInitializationSettings(defaultActionName: 'Open'),
			android: AndroidInitializationSettings('ic_stat_name'),
		), onSelectNotification: _handleSelectNotification);

		var androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
		if (androidPlugin != null) {
			try {
				var activeNotifs = await androidPlugin.getActiveNotifications();
				if (activeNotifs != null) {
					_populateActive(androidPlugin, activeNotifs);
				}
			} on Exception catch (err) {
				print('Failed to list active notifications: $err');
			}
		}

		var launchDetails = await _plugin.getNotificationAppLaunchDetails();
		if (launchDetails == null || !launchDetails.didNotificationLaunchApp) {
			return null;
		}
		return launchDetails.payload;
	}

	void _populateActive(AndroidFlutterLocalNotificationsPlugin androidPlugin, List<ActiveNotification> activeNotifs) async {
		for (var notif in activeNotifs) {
			if (_nextId <= notif.id) {
				_nextId = notif.id + 1;
			}

			if (notif.tag == null || notif.title == null) {
				print('Found an active notification without a tag or title');
				continue;
			}

			MessagingStyleInformation? messagingStyleInfo;
			try {
				messagingStyleInfo = await androidPlugin.getActiveNotificationMessagingStyle(notif.id, tag: notif.tag);
			} on Exception catch (err) {
				print('Failed to get active notification messagign style: $err');
			}

			_active.add(_ActiveNotification(notif.id, notif.tag!, notif.title!, messagingStyleInfo));
		}
	}

	void _handleSelectNotification(String? payload) {
		_selectionsController.add(payload);
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
			id = _nextId++;
		}
		_active.add(_ActiveNotification(id, tag, title, messagingStyleInfo));

		await _plugin.show(id, title, body, NotificationDetails(
			linux: LinuxNotificationDetails(
				category: LinuxNotificationCategory.imReceived(),
			),
			android: AndroidNotificationDetails(channel.id, channel.name,
				channelDescription: channel.description,
				importance: Importance.high,
				priority: Priority.high,
				category: 'msg',
				when: dateTime?.millisecondsSinceEpoch,
				styleInformation: messagingStyleInfo,
				tag: tag,
				enableLights: true,
			),
		), payload: tag);
	}
}
