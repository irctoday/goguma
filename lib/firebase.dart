import 'dart:io';
import 'dart:convert' show json, base64;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'database.dart';
import 'push.dart';

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

		if (!await FirebaseMessaging.instance.isSupported()) {
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
	Future<String> createSubscription(NetworkEntry network, String? vapidKey) async {
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

	@override
	Future<void> deleteSubscription(NetworkEntry network, String endpoint) async {
		// TODO: don't hardcode paths
		endpoint = endpoint.replaceFirst('/push/', '/subscription/');

		var client = HttpClient();
		try {
			var req = await client.deleteUrl(Uri.parse(endpoint));
			var resp = await req.close();
			if (resp.statusCode ~/ 100 != 2) {
				throw Exception('HTTP error ${resp.statusCode}');
			}
		} finally {
			client.close();
		}
	}
}

// This function may called from a separate Isolate
@pragma('vm:entry-point')
Future<void> _handleFirebaseMessage(RemoteMessage message) async {
	print('Received Firebase push message: ${message.data}');

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

	List<int> ciphertext = base64.decode(encodedPayload);
	await handlePushMessage(db, sub, ciphertext);
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
