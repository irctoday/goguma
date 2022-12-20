import 'dart:io';

import 'package:flutter/foundation.dart';

const log = Logger();

class Logger {
	const Logger();

	void print(String msg, { Object? error }) {
		if (error != null) {
			msg += ': $error';
		}
		debugPrint(msg);
	}

	void reportFlutterError(FlutterErrorDetails details) {
		FlutterError.dumpErrorToConsole(details, forceReport: true);
		if (kReleaseMode && details.exception is Error) {
			exit(1);
		}
	}
}
