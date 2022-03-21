import 'dart:async';
import 'dart:io';

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

	void showDirectMessage(List<MessageEntry> entries, BufferModel buffer) {
		var entry = entries.last;

		String title;
		if (entries.length == 1) {
			title = 'New message from ${entry.msg.source!.name}';
		} else {
			title = '${entries.length} messages from ${entry.msg.source!.name}';
		}

		_show(
			title: title,
			body: stripAnsiFormatting(entry.msg.params[1]),
			channel: _NotificationChannel(
				id: 'privmsg',
				name: 'Private messages',
				description: 'Private messages sent directly to you',
			),
			dateTime: entry.dateTime,
			styleInformation: _buildMessagingStyleInfo(entries, buffer, false),
			tag: 'buffer:${buffer.id}',
		);
	}

	void showHighlight(List<MessageEntry> entries, BufferModel buffer) {
		var entry = entries.last;

		String title;
		if (entries.length == 1) {
			title = '${entry.msg.source!.name} mentionned you in ${buffer.name}';
		} else {
			title = '${entries.length} mentions in ${buffer.name}';
		}

		_show(
			title: title,
			body: stripAnsiFormatting(entry.msg.params[1]),
			channel: _NotificationChannel(
				id: 'highlight',
				name: 'Mentions',
				description: 'Messages mentionning your nickname in a channel',
			),
			dateTime: entry.dateTime,
			styleInformation: _buildMessagingStyleInfo(entries, buffer, true),
			tag: 'buffer:${buffer.id}',
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
					stripAnsiFormatting(entry.msg.params[1]),
					entry.dateTime,
					Person(name: entry.msg.source!.name),
				);
			}).toList(),
		);
	}

	void cancelAllWithBuffer(BufferModel buffer) {
		_cancelAllWithTag('buffer:${buffer.id}');
	}

	void _cancelAllWithTag(String tag) {
		_active = _active.where((notif) {
			if (notif.tag != tag) {
				return true;
			}
			_plugin.cancel(notif.id, tag: notif.tag).ignore();
			return false;
		}).toList();
	}

	void _show({
		required String title,
		String? body,
		required _NotificationChannel channel,
		required String tag,
		DateTime? dateTime,
		StyleInformation? styleInformation,
	}) {
		_ActiveNotification? replace;
		for (var notif in _active) {
			if (notif.tag == tag) {
				replace = notif;
				break;
			}
		}

		var id = replace?.id ?? _nextId++;

		_plugin.show(id, title, body, NotificationDetails(
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
			),
		), payload: tag);
		_active.add(_ActiveNotification(id, tag));
	}
}
