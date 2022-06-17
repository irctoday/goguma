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
import 'webpush.dart';

bool _supported = false;
FirebaseOptions? firebaseOptions;

final _gatewayEndpoint = Uri.parse(
	String.fromEnvironment('pushgardenEndpoint', defaultValue: 'https://pushgarden.emersion.fr')
);

Future<String> createFirebaseSubscription(String? vapidKey) async {
	var token = await FirebaseMessaging.instance.getToken();
	var client = HttpClient();
	try {
		var url = _gatewayEndpoint.resolve('/firebase/${firebaseOptions!.projectId}/subscribe?token=$token');
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

Future<void> initFirebaseMessaging() async {
	if (!Platform.isAndroid || firebaseOptions == null) {
		return;
	}

	await Firebase.initializeApp(options: firebaseOptions!);

	if (!FirebaseMessaging.instance.isSupported()) {
		print('Firebase messaging is not supported');
		return;
	}

	// Workaround: isSupported() may return true on devices without Play Services:
	// https://github.com/firebase/flutterfire/issues/8917
	await FirebaseMessaging.instance.getToken();

	FirebaseMessaging.onBackgroundMessage(_handleFirebaseMessage);
	FirebaseMessaging.onMessage.listen(_handleFirebaseMessage);

	print('Firebase messaging initialized');
	_supported = true;
}

bool isFirebaseSupported() {
	return _supported;
}

// This function may called from a separate Isolate
Future<void> _handleFirebaseMessage(RemoteMessage message) async {
	print('Received push message: ${message.data}');

	var encodedPayload = message.data['payload'] as String;
	var endpoint = Uri.parse(message.data['endpoint'] as String);
	var vapidKey = message.data['vapid_key'] as String?;

	var db = await DB.open();
	var subs = await db.listWebPushSubscriptions();
	var sub = subs.firstWhere((sub) {
		// data['endpoint'] is typically missing the hostname
		var subEndpointUri = Uri.parse(sub.endpoint);
		var msgEndpointUri = subEndpointUri.resolveUri(endpoint);
		return subEndpointUri == msgEndpointUri;
	});

	if (sub.vapidKey != vapidKey) {
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

	// TODO: cancel existing notifications on READ
	if (msg.cmd != 'PRIVMSG' && msg.cmd != 'NOTICE') {
		print('Ignoring ${msg.cmd} message');
		return;
	}

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

	var msgEntry = MessageEntry(msg, bufferEntry.id!);

	var notifController = NotificationController();
	await notifController.initialize();

	if (isChannel) {
		notifController.showHighlight([msgEntry], buffer);
	} else {
		notifController.showDirectMessage([msgEntry], buffer);
	}
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
