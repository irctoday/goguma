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
	final String payload;

	_ActiveNotification(this.id, this.payload);
}

class NotificationController {
	final FlutterLocalNotificationsPlugin _notifsPlugin = FlutterLocalNotificationsPlugin();
	final StreamController<String?> _selectionsController = StreamController();
	List<_ActiveNotification> _active = [];

	Stream<String?> get selections => _selectionsController.stream;

	Future<String?> initialize() {
		return _notifsPlugin.initialize(InitializationSettings(
			linux: LinuxInitializationSettings(defaultActionName: 'Open'),
			android: AndroidInitializationSettings('ic_stat_name'),
		), onSelectNotification: _handleSelectNotification).then((_) {
			var androidPlugin = _notifsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
			return androidPlugin?.getActiveNotifications() ?? Future.value(null);
		}).then((List<ActiveNotification>? activeNotifs) {
			for (var notif in activeNotifs ?? []) {
				// We can't get back the payload here, so we (ab)use the
				// Android tag to store the payload
				var payload = notif.tag;
				if (payload != null) {
					_active.add(_ActiveNotification(notif.id, payload));
				}
			}

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
		// TODO: this removes too much, we should try to remove per ID instead,
		// but we don't have it here...
		if (payload != null) {
			_cancelAllWithPayload(payload);
		}
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

	void cancelAllWithBuffer(BufferModel buffer) {
		_cancelAllWithPayload('buffer:${buffer.id}');
	}

	void _cancelAllWithPayload(String payload) {
		_active = _active.where((notif) {
			if (notif.payload != payload) {
				return true;
			}
			// See initialize() for the tag vs. payload trick
			_notifsPlugin.cancel(notif.id, tag: notif.payload).ignore();
			return false;
		}).toList();
	}

	void _show({ required String title, required String body, String? subText, required _NotificationChannel channel, required String payload, DateTime? dateTime }) {
		var id = _nextId++;
		_notifsPlugin.show(id, title, body, NotificationDetails(
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
				tag: payload, // see initialize()
			),
		), payload: payload);
		_active.add(_ActiveNotification(id, payload));
	}
}
