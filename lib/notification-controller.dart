import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'database.dart';
import 'irc.dart';
import 'models.dart';

var nextId = 1;

class _NotificationChannel {
	final String id;
	final String name;
	final String? description;

	_NotificationChannel({ required this.id, required this.name, this.description });
}

class NotificationController {
	final FlutterLocalNotificationsPlugin _notifsPlugin = FlutterLocalNotificationsPlugin();
	final StreamController<String?> _selectionsController = StreamController();

	Stream<String?> get selections => _selectionsController.stream;

	Future<String?> initialize() {
		return _notifsPlugin.initialize(InitializationSettings(
			linux: LinuxInitializationSettings(defaultActionName: 'Open'),
			android: AndroidInitializationSettings('ic_stat_name'),
		), onSelectNotification: _handleSelectNotification).then((_) {
			if (Platform.isAndroid) {
				return _notifsPlugin.getNotificationAppLaunchDetails();
			} else {
				return Future.value(null);
			}
		}).then((NotificationAppLaunchDetails? details) {
			if (details == null || !details.didNotificationLaunchApp) {
				return null;
			}
			return details.payload;
		});
	}

	void _handleSelectNotification(String? payload) {
		_selectionsController.add(payload);
	}

	void showDirectMessage(MessageEntry entry, BufferModel buffer, bool showNetworkName) {
		_show(
			title: 'New message from ${entry.msg.source!.name}',
			body: stripAnsiFormatting(entry.msg.params[1]),
			subText: showNetworkName ? buffer.network.displayName : null,
			channel: _NotificationChannel(
				id: 'privmsg',
				name: 'Private messages',
				description: 'Private messages sent directly to you',
			),
			dateTime: entry.dateTime,
			payload: 'buffer:${entry.buffer}',
		);
	}

	void showHighlight(MessageEntry entry, BufferModel buffer, bool showNetworkName) {
		_show(
			title: '${entry.msg.source!.name} mentionned you in ${buffer.name}',
			body: stripAnsiFormatting(entry.msg.params[1]),
			subText: showNetworkName ? buffer.network.displayName : null,
			channel: _NotificationChannel(
				id: 'highlight',
				name: 'Mentions',
				description: 'Messages mentionning your nickname in a channel',
			),
			dateTime: entry.dateTime,
			payload: 'buffer:${entry.buffer}',
		);
	}

	void _show({ required String title, required String body, String? subText, required _NotificationChannel channel, required String payload, DateTime? dateTime }) {
		_notifsPlugin.show(nextId++, title, body, NotificationDetails(
			linux: LinuxNotificationDetails(
				category: LinuxNotificationCategory.imReceived(),
			),
			android: AndroidNotificationDetails(channel.id, channel.name,
				channelDescription: channel.description,
				importance: Importance.high,
				priority: Priority.high,
				category: 'msg',
				subText: subText,
				when: dateTime?.millisecondsSinceEpoch,
			),
		), payload: payload);
	}
}
