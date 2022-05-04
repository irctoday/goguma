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

	_ActiveNotification(this.id, this.tag);
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
			var activeNotifs = await androidPlugin.getActiveNotifications();
			for (var notif in activeNotifs ?? <ActiveNotification>[]) {
				if (notif.tag != null) {
					_active.add(_ActiveNotification(notif.id, notif.tag!));
				}
				if (_nextId <= notif.id) {
					_nextId = notif.id + 1;
				}
			}

			var launchDetails = await _plugin.getNotificationAppLaunchDetails();
			if (launchDetails == null || !launchDetails.didNotificationLaunchApp) {
				return null;
			}
			return launchDetails.payload;
		}

		return null;
	}

	void _handleSelectNotification(String? payload) {
		_selectionsController.add(payload);
	}

	String _bufferTag(BufferModel buffer) {
		return 'buffer:${buffer.id}';
	}

	Future<void> showDirectMessage(List<MessageEntry> entries, BufferModel buffer) async {
		var entry = entries.last;

		String title;
		if (entries.length == 1) {
			title = 'New message from ${entry.msg.source!.name}';
		} else {
			title = '${entries.length} messages from ${entry.msg.source!.name}';
		}

		await _show(
			title: title,
			body: _getMessageBody(entry),
			channel: _NotificationChannel(
				id: 'privmsg',
				name: 'Private messages',
				description: 'Private messages sent directly to you',
			),
			dateTime: entry.dateTime,
			styleInformation: _buildMessagingStyleInfo(entries, buffer, false),
			tag: _bufferTag(buffer),
		);
	}

	Future<void> showHighlight(List<MessageEntry> entries, BufferModel buffer) async {
		var entry = entries.last;

		String title;
		if (entries.length == 1) {
			title = '${entry.msg.source!.name} mentionned you in ${buffer.name}';
		} else {
			title = '${entries.length} mentions in ${buffer.name}';
		}

		await _show(
			title: title,
			body: _getMessageBody(entry),
			channel: _NotificationChannel(
				id: 'highlight',
				name: 'Mentions',
				description: 'Messages mentionning your nickname in a channel',
			),
			dateTime: entry.dateTime,
			styleInformation: _buildMessagingStyleInfo(entries, buffer, true),
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

	MessagingStyleInformation _buildMessagingStyleInfo(List<MessageEntry> entries, BufferModel buffer, bool isChannel) {
		// TODO: Person.key, Person.bot, Person.uri
		return MessagingStyleInformation(
			Person(name: buffer.name),
			conversationTitle: buffer.name,
			groupConversation: isChannel,
			messages: entries.map((entry) {
				return Message(
					_getMessageBody(entry),
					entry.dateTime,
					Person(name: entry.msg.source!.name),
				);
			}).toList(),
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

	Future<void> _show({
		required String title,
		String? body,
		required _NotificationChannel channel,
		required String tag,
		DateTime? dateTime,
		StyleInformation? styleInformation,
	}) async {
		_ActiveNotification? replace;
		for (var notif in _active) {
			if (notif.tag == tag) {
				replace = notif;
				break;
			}
		}

		int id;
		if (replace != null) {
			_active.remove(replace);
			id = replace.id;
		} else {
			id = _nextId++;
		}
		_active.add(_ActiveNotification(id, tag));

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
				styleInformation: styleInformation,
				tag: tag,
				enableLights: true,
			),
		), payload: tag);
	}
}
