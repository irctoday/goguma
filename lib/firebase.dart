import 'dart:convert' show json, utf8, base64;
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

import 'database.dart';
import 'irc.dart';
import 'models.dart';
import 'notification_controller.dart';
import 'prefs.dart';
import 'push.dart';
import 'webpush.dart';

final _gatewayEndpoint = Uri.parse(
	String.fromEnvironment('pushgardenEndpoint', defaultValue: 'https://pushgarden.emersion.fr')
);

class FirebasePushController extends PushController {
	final FirebaseOptions options;

	FirebasePushController._(this.options);

	static Future<FirebasePushController> init(FirebaseOptions options) async {
		if (!Platform.isAndroid) {
			throw Exception('Firebase is only supported on Android');
		}

		await Firebase.initializeApp(options: options);

		if (!FirebaseMessaging.instance.isSupported()) {
			throw Exception('Firebase messaging is unsupported on this platform');
		}

		// Workaround: isSupported() may return true on devices without Play Services:
		// https://github.com/firebase/flutterfire/issues/8917
		await FirebaseMessaging.instance.getToken();

		FirebaseMessaging.onBackgroundMessage(_handleFirebaseMessage);
		FirebaseMessaging.onMessage.listen(_handleFirebaseMessage);

		print('Firebase messaging initialized');
		return FirebasePushController._(options);
	}

	@override
	Future<String> createSubscription(String? vapidKey) async {
		var token = await FirebaseMessaging.instance.getToken();
		var client = HttpClient();
		try {
			var url = _gatewayEndpoint.resolve('/firebase/${options.projectId}/subscribe?token=$token');
			var req = await client.postUrl(url);
			req.headers.contentType = ContentType('application', 'webpush-options+json', charset: 'utf-8');
			req.write(json.encode({
				'vapid': vapidKey,
			}));
			var resp = await req.close();
			if (resp.statusCode ~/ 100 != 2) {
				throw Exception('HTTP error ${resp.statusCode}');
			}

			// TODO: parse subscription resource URL as well

			String? pushLink;
			for (var rawLink in resp.headers['Link'] ?? <String>[]) {
				var link = HeaderValue.parse(rawLink);
				if (link.parameters['rel'] == 'urn:ietf:params:push') {
					pushLink = link.value;
					break;
				}
			}

			if (pushLink == null || !pushLink.startsWith('<') || !pushLink.endsWith('>')) {
				throw FormatException('No valid urn:ietf:params:push Link found');
			}
			var pushUrl = pushLink.substring(1, pushLink.length - 1);
			return _gatewayEndpoint.resolve(pushUrl).toString();
		} finally {
			client.close();
		}
	}
}

// This function may called from a separate Isolate
Future<void> _handleFirebaseMessage(RemoteMessage message) async {
	print('Received push message: ${message.data}');

	var encodedPayload = message.data['payload'] as String;
	var endpoint = Uri.parse(message.data['endpoint'] as String);
	var vapidKey = message.data['vapid_key'] as String?;

	var db = await DB.open();

	var sub = await _fetchWebPushSubscription(db, endpoint);
	if (sub == null) {
		throw Exception('Got push message for an unknown endpoint: $endpoint');
	} else if (sub.vapidKey != vapidKey) {
		throw Exception('VAPID public key mismatch');
	}

	var config = WebPushConfig(
		p256dhPublicKey: sub.p256dhPublicKey,
		p256dhPrivateKey: sub.p256dhPrivateKey,
		authKey: sub.authKey,
	);
	var webPush = await WebPush.import(config);

	List<int> ciphertext = base64.decode(encodedPayload);
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

	var notifController = NotificationController();
	await notifController.initialize();

	switch (msg.cmd) {
	case 'PRIVMSG':
	case 'NOTICE':
		var target = msg.params[0];
		var isChannel = target.length > 0 && networkEntry.isupport.chanTypes.contains(target[0]);
		if (!isChannel) {
			target = msg.source!.name;
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

Future<WebPushSubscriptionEntry?> _fetchWebPushSubscription(DB db, Uri endpoint) async {
	var entries = await db.listWebPushSubscriptions();
	for (var entry in entries) {
		// data['endpoint'] is typically missing the hostname
		var subEndpointUri = Uri.parse(entry.endpoint);
		var msgEndpointUri = subEndpointUri.resolveUri(endpoint);
		if (subEndpointUri == msgEndpointUri) {
			return entry;
		}
	}
	return null;
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
