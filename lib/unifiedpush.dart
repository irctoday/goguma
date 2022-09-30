import 'dart:async';
import 'dart:typed_data';

import 'package:unifiedpush/constants.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'database.dart';
import 'push.dart';

UnifiedPushController? _singleton;

class UnifiedPushController extends PushController {
	final Map<String, Completer<String>> _pendingSubscriptions = {};

	UnifiedPushController._();

	static Future<UnifiedPushController> init() async {
		_singleton ??= UnifiedPushController._();
		var controller = _singleton!;

		// TODO: handle onUnregistered
		try {
			await UnifiedPush.initialize(
				onNewEndpoint: controller._handleNewEndpoint,
				onRegistrationFailed: controller._handleRegistrationFailed,
				onMessage: _handleMessage,
			);
		} on UnimplementedError {
			throw Exception('UnifiedPush not supported on this platform');
		}

		if (await UnifiedPush.getDistributor() == '') {
			var distributors = await UnifiedPush.getDistributors([featureAndroidBytesMessage]);
			if (distributors.length == 0) {
				throw Exception('No UnifiedPush distributor found');
			}
			// TODO: allow the user to select the distributor
			await UnifiedPush.saveDistributor(distributors.first);
		}

		return controller;
	}

	@override
	Future<String> createSubscription(NetworkEntry network, String? vapidKey) async {
		var instance = 'network:${network.id}';

		await UnifiedPush.registerApp(instance, [featureAndroidBytesMessage]);

		var completer = Completer<String>();
		_pendingSubscriptions[instance] = completer;
		return completer.future;
	}

	void _handleNewEndpoint(String endpoint, String instance) {
		var completer = _pendingSubscriptions.remove(instance);
		if (completer == null) {
			// TODO: handle endpoint changes
			return;
		}
		completer.complete(endpoint);
	}

	void _handleRegistrationFailed(String instance) {
		var completer = _pendingSubscriptions.remove(instance);
		if (completer == null) {
			return;
		}
		completer.completeError(Exception('UnifiedPush registration failed'));
	}
}

// This function may called from a separate Isolate
@pragma('vm:entry-point')
void _handleMessage(Uint8List ciphertext, String instance) async {
	print('Got UnifiedPush message for $instance');

	var prefix = 'network:';
	if (!instance.startsWith(prefix)) {
		throw FormatException('Invalid UnifiedPush instance name: "$instance"');
	}
	var netId = int.parse(instance.replaceFirst(prefix, ''));

	var db = await DB.open();

	var sub = await _fetchWebPushSubscription(db, netId);
	if (sub == null) {
		throw Exception('Got push message for an unknown network ID: $netId');
	}

	await handlePushMessage(db, sub, ciphertext);
}

Future<WebPushSubscriptionEntry?> _fetchWebPushSubscription(DB db, int netId) async {
	var entries = await db.listWebPushSubscriptions();
	for (var entry in entries) {
		if (entry.network == netId) {
			return entry;
		}
	}
	return null;
}
