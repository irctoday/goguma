import 'dart:async';
import 'dart:convert' show base64UrlEncode;
import 'dart:math';
import 'dart:typed_data';

import 'package:unifiedpush/constants.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'database.dart';
import 'push.dart';

UnifiedPushController? _singleton;
String? _distributor;

class UnifiedPushController extends PushController {
	final Map<String, Completer<PushSubscription>> _pendingSubscriptions = {};

	UnifiedPushController._();

	static Future<UnifiedPushController> init() async {
		_singleton ??= UnifiedPushController._();
		var controller = _singleton!;

		try {
			await UnifiedPush.initialize(
				onNewEndpoint: controller._handleNewEndpoint,
				onRegistrationFailed: controller._handleRegistrationFailed,
				onUnregistered: controller._handleUnregistered,
				onMessage: _handleMessage,
			);
		} on UnimplementedError {
			throw Exception('UnifiedPush not supported on this platform');
		}

		var distributor = await UnifiedPush.getDistributor();
		if (distributor == '') {
			var distributors = await UnifiedPush.getDistributors([featureAndroidBytesMessage]);
			if (distributors.length == 0) {
				throw Exception('No UnifiedPush distributor found');
			}
			// TODO: allow the user to select the distributor
			distributor = distributors.first;
			await UnifiedPush.saveDistributor(distributor);
		}
		print('Using UnifiedPush distributor: $distributor');
		_distributor = distributor;

		return controller;
	}

	@override
	String get providerName => 'unifiedpush:' + _distributor!;

	@override
	Future<PushSubscription> createSubscription(NetworkEntry network, String? vapidKey) async {
		var instance = _generateInstance();

		await UnifiedPush.registerApp(instance, [featureAndroidBytesMessage]);

		var completer = Completer<PushSubscription>();
		_pendingSubscriptions[instance] = completer;
		return completer.future;
	}

	@override
	Future<void> deleteSubscription(NetworkEntry network, PushSubscription sub) async {
		// Compat with old subscriptions
		// TODO: drop this
		var instance = sub.tag ?? 'network:${network.id}';
		await UnifiedPush.unregister(instance);
	}

	void _handleNewEndpoint(String endpoint, String instance) {
		var completer = _pendingSubscriptions.remove(instance);
		if (completer == null) {
			// TODO: handle endpoint changes
			return;
		}
		completer.complete(PushSubscription(
			endpoint: endpoint,
			tag: instance,
		));
	}

	void _handleRegistrationFailed(String instance) {
		var completer = _pendingSubscriptions.remove(instance);
		if (completer == null) {
			return;
		}
		completer.completeError(Exception('UnifiedPush registration failed'));
	}

	void _handleUnregistered(String instance) {
		print('UnifiedPush unregistered: $instance');
		// TODO: handle this
	}
}

// This function may called from a separate Isolate
@pragma('vm:entry-point')
void _handleMessage(Uint8List ciphertext, String instance) async {
	print('Got UnifiedPush message for $instance');

	var db = await DB.open();

	// TODO: drop old compat code
	var subs = await db.listWebPushSubscriptions();
	WebPushSubscriptionEntry? sub;
	var prefix = 'network:';
	if (instance.startsWith(prefix)) {
		var netId = int.parse(instance.replaceFirst(prefix, ''));
		sub = _findSubscriptionWithNetId(subs, netId);
	} else {
		sub = _findSubscriptionWithTag(subs, instance);
	}
	if (sub == null) {
		throw Exception('Got push message for an unknown instance: $instance');
	}

	await handlePushMessage(db, sub, ciphertext);
}

WebPushSubscriptionEntry? _findSubscriptionWithNetId(List<WebPushSubscriptionEntry> entries, int netId) {
	for (var entry in entries) {
		if (entry.network == netId) {
			return entry;
		}
	}
	return null;
}

WebPushSubscriptionEntry? _findSubscriptionWithTag(List<WebPushSubscriptionEntry> entries, String tag) {
	for (var entry in entries) {
		if (entry.tag == tag) {
			return entry;
		}
	}
	return null;
}

String _generateInstance() {
	var len = 16;
	var random = Random.secure();
	var values = List<int>.generate(len, (i) => random.nextInt(255));
	return base64UrlEncode(values).replaceAll('=', '');
}
