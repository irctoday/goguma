import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sentry/sentry.dart';

const _sentryDsn = String.fromEnvironment('SENTRY_DSN');
var _sentryEnabled = false;

const log = Logger();

class Logger {
	const Logger();

	Future<void> init() async {
		if (_sentryDsn == '') {
			return;
		}

		try {
			await Sentry.init((options) {
				options.enablePrintBreadcrumbs = false;
			});
			_sentryEnabled = true;
			log.print('Sentry error reporting enabled');
		} on Exception catch (err) {
			log.print('Failed to initialize Sentry', error: err);
		}
	}

	void print(String msg, { Object? error }) {
		if (error != null) {
			msg += ': $error';
		}
		debugPrint(msg);
	}

	void reportFlutterError(FlutterErrorDetails details) async {
		FlutterError.dumpErrorToConsole(details, forceReport: true);

		if (details.silent) {
			return;
		}

		// Workaround: we get some uncaught SocketException on Android without
		// a stack. Ignore these.
		// TODO: figure out where they're coming from.
		if (_sentryEnabled && !(details.exception is SocketException)) {
			await Sentry.captureException(details.exception, stackTrace: details.stack);
		}

		if (kReleaseMode && details.exception is Error) {
			exit(1);
		}
	}
}
