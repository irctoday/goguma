import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_apns_only/flutter_apns_only.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database.dart';
import 'logging.dart';
import 'push.dart';

final _gatewayEndpoint = Uri.parse(
	String.fromEnvironment('pushgardenEndpoint', defaultValue: 'https://pushgarden.emersion.fr')
);
const _environment = kReleaseMode ? 'production' : 'development';
const _appId = 'me.jeanthomas.goguma';

class ApnsPushController extends PushController {
	final String _token;

	ApnsPushController._(this._token);

	static Future<ApnsPushController> init() async {
		if (!Platform.isIOS) {
			throw Exception('APNs is only supported on iOS');
		}
		var connector = ApnsPushConnectorOnly();
		connector.configureApns(
			onMessage: _handleApnsMessage,
			onBackgroundMessage: _handleApnsMessage,
			onLaunch: _handleApnsMessage,
			onResume: _handleApnsMessage,
		);
		var token = await _waitToken(connector);
		await _updateToken(token);
		// TODO: listen to token changes
		return ApnsPushController._(token);
	}

	@override
	String get providerName => 'apns:' + _gatewayEndpoint.toString();

	@override
	Future<PushSubscription> createSubscription(NetworkEntry network, String? vapidKey) async {
		var tag = _generateTag();
		var pushUrl = _gatewayEndpoint.resolve('/apple/$_appId/$_environment/push?token=$_token&state=$tag');
		return PushSubscription(
			endpoint: pushUrl.toString(),
			tag: tag,
		);
	}

	@override
	Future<void> deleteSubscription(NetworkEntry network, PushSubscription sub) async {
		// No-op: we use the stateless pushgarden API
	}
}

// This function may called from a separate Isolate
@pragma('vm:entry-point')
Future<void> _handleApnsMessage(ApnsRemoteMessage msg) async {
	log.print('Received APNs push message: ${msg.payload}');

	var encodedPayload = msg.payload['data']['payload'] as String;
	var vapidKey = msg.payload['data']['vapid_key'] as String?;
	var tag = msg.payload['data']['state'] as String;

	var db = await DB.open();

	var sub = await _fetchWebPushSubscription(db, tag);
	if (sub == null) {
		throw Exception('Got APNs push message for an unknown tag: $tag');
	} else if (sub.vapidKey != vapidKey) {
		throw Exception('VAPID public key mismatch');
	}

	List<int> ciphertext = base64.decode(encodedPayload);
	await handlePushMessage(db, sub, ciphertext);
}

Future<WebPushSubscriptionEntry?> _fetchWebPushSubscription(DB db, String tag) async {
	var entries = await db.listWebPushSubscriptions();
	for (var entry in entries) {
		if (entry.tag == tag) {
			return entry;
		}
	}
	return null;
}

Future<String> _waitToken(ApnsPushConnectorOnly connector) async {
	if (connector.token.value != null) {
		return Future.value(connector.token.value);
	}

	var completer = Completer<String>();
	void listener() {
		if (connector.token.value != null) {
			completer.complete(connector.token.value);
		}
	}
	connector.token.addListener(listener);

	try {
		return await completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
			throw TimeoutException('Timed out waiting for APNs token');
		});
	} finally {
		connector.token.removeListener(listener);
	}
}

Future<void> _updateToken(String token) async {
	var prefs = await SharedPreferences.getInstance();
	var oldToken = prefs.getString('apns_token');
	var updated = oldToken != null && oldToken != token;
	await prefs.setString('apns_token', token);
	if (!updated) {
		return;
	}

	log.print('APNs token changed, deleting all subscriptions');

	var db = await DB.open();
	var subs = await db.listWebPushSubscriptions();
	for (var sub in subs) {
		await db.deleteWebPushSubscription(sub.id!);
	}
	// TODO: send WEBPUSH UNREGISTER to the IRC server
}

String _generateTag() {
	var len = 32;
	var random = Random.secure();
	var values = List<int>.generate(len, (i) => random.nextInt(255));
	return base64UrlEncode(values);
}

Future<PushController> Function() wrapApnsInitPush(Future<PushController> Function() next) {
	return () async {
		try {
			return await ApnsPushController.init();
		} on Exception catch (err) {
			log.print('Warning: failed to initialize APNs', error: err);
		}
		return await next();
	};
}
