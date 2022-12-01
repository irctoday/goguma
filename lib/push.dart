import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:shared_preferences_android/shared_preferences_android.dart';

import 'database.dart';
import 'irc.dart';
import 'models.dart';
import 'notification_controller.dart';
import 'prefs.dart';
import 'webpush.dart';

class PushSubscription {
	final String endpoint;
	final String? tag;

	PushSubscription({
		required this.endpoint,
		this.tag,
	});
}

abstract class PushController {
	String get providerName;
	Future<PushSubscription> createSubscription(NetworkEntry network, String? vapidKey);
	Future<void> deleteSubscription(NetworkEntry network, PushSubscription sub);
}

// This function may called from a separate Isolate
Future<void> handlePushMessage(DB db, WebPushSubscriptionEntry sub, List<int> ciphertext) async {
	var config = WebPushConfig(
		p256dhPublicKey: sub.p256dhPublicKey,
		p256dhPrivateKey: sub.p256dhPrivateKey,
		authKey: sub.authKey,
	);
	var webPush = await WebPush.import(config);

	var bytes = await webPush.decrypt(ciphertext);
	var str = utf8.decode(bytes);
	var msg = IrcMessage.parse(str);

	print('Decrypted push message payload: $msg');

	var networkEntry = await _fetchNetwork(db, sub.network);
	if (networkEntry == null) {
		throw Exception('Got push message for an unknown network #${sub.network}');
	}
	var serverEntry = await _fetchServer(db, networkEntry.server);
	if (serverEntry == null) {
		throw Exception('Network #${sub.network} has an unknown server #${networkEntry.server}');
	}

	// See: https://github.com/flutter/flutter/issues/98473#issuecomment-1060952450
	if (Platform.isAndroid) {
		SharedPreferencesAndroid.registerWith();
	}
	var prefs = await Prefs.load();

	var nickname = serverEntry.nick ?? prefs.nickname;
	var realname = prefs.realname ?? nickname;
	var network = NetworkModel(serverEntry, networkEntry, nickname, realname);

	var notifController = await NotificationController.init();

	switch (msg.cmd) {
	case 'PRIVMSG':
	case 'NOTICE':
		var target = msg.params[0];
		var isChannel = _isChannel(target, networkEntry.isupport);
		if (!isChannel) {
			var channelCtx = msg.tags['+draft/channel-context'];
			if (channelCtx != null && _isChannel(channelCtx, networkEntry.isupport) && await _fetchBuffer(db, channelCtx, networkEntry) != null) {
				target = channelCtx;
				isChannel = true;
			} else {
				target = msg.source!.name;
			}
		}

		var bufferEntry = await _fetchBuffer(db, target, networkEntry);
		if (bufferEntry == null) {
			bufferEntry = BufferEntry(name: target, network: sub.network);
			await db.storeBuffer(bufferEntry);
		}

		var buffer = BufferModel(entry: bufferEntry, network: network);
		if (buffer.muted) {
			break;
		}

		var msgEntry = MessageEntry(msg, bufferEntry.id!);

		if (isChannel) {
			notifController.showHighlight([msgEntry], buffer);
		} else {
			notifController.showDirectMessage([msgEntry], buffer);
		}
		break;
	case 'INVITE':
		notifController.showInvite(msg, network);
		break;
	case 'MARKREAD':
		var target = msg.params[0];
		var bound = msg.params[1];
		if (bound == '*') {
			break;
		}
		if (!bound.startsWith('timestamp=')) {
			throw FormatException('Invalid MARKREAD bound: $msg');
		}
		//var time = bound.replaceFirst('timestamp=', '');

		var bufferEntry = await _fetchBuffer(db, target, networkEntry);
		if (bufferEntry == null) {
			break;
		}

		// TODO: we should check lastReadTime here, but we might be racing
		// against the main Isolate, which also receives MARKREAD via the TCP
		// connection and isn't aware about notifications opened via push

		// TODO: don't clear notifications whose timestamp is after the read
		// marker
		var buffer = BufferModel(entry: bufferEntry, network: network);
		notifController.cancelAllWithBuffer(buffer);
		break;
	default:
		print('Ignoring ${msg.cmd} message');
		return;
	}
}

bool _isChannel(String name, IrcIsupportRegistry isupport) {
	return name.length > 0 && isupport.chanTypes.contains(name[0]);
}

Future<NetworkEntry?> _fetchNetwork(DB db, int id) async {
	var entries = await db.listNetworks();
	for (var entry in entries) {
		if (entry.id == id) {
			return entry;
		}
	}
	return null;
}

Future<ServerEntry?> _fetchServer(DB db, int id) async {
	var entries = await db.listServers();
	for (var entry in entries) {
		if (entry.id == id) {
			return entry;
		}
	}
	return null;
}

Future<BufferEntry?> _fetchBuffer(DB db, String name, NetworkEntry network) async {
	var cm = network.isupport.caseMapping;
	var entries = await db.listBuffers();
	for (var entry in entries) {
		if (entry.network == network.id && cm(entry.name) == cm(name)) {
			return entry;
		}
	}
	return null;
}
