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
}
