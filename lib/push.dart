import 'dart:async';

abstract class PushController {
	Future<String> createSubscription(String? vapidKey);
}
