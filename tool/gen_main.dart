import 'dart:convert' show json;
import 'dart:io';

Never _usage() {
	stderr.writeln('usage: gen_main [--firebase google-services.json] lib/main_generated.dart');
	exit(1);
}

void main(List<String> args) async {
	String? outputFilename;
	String? firebaseFilename;
	for (var i = 0; i < args.length; i++) {
		var arg = args[i];
		if (arg.startsWith('-')) {
			switch (arg) {
			case '--firebase':
				if (i + 1 >= args.length) {
					_usage();
				}
				i++;
				firebaseFilename = args[i];
				break;
			default:
				_usage();
			}
		} else {
			if (outputFilename == null) {
				outputFilename = arg;
			} else {
				_usage();
			}
		}
	}
	if (outputFilename == null) {
		_usage();
	}

	var imports = '';
	var body = '';
	if (firebaseFilename != null) {
		var str = await File(firebaseFilename).readAsString();
		var data = json.decode(str);

		var projectId = data['project_info']['project_id'] as String;
		var messagingSenderId = data['project_info']['project_number'] as String;
		var appId = data['client'][0]['client_info']['mobilesdk_app_id'] as String;
		var apiKey = data['client'][0]['api_key'][0]['current_key'] as String;

		imports += '''import 'package:firebase_core/firebase_core.dart';
import 'firebase.dart';
''';
		body += '''	base.initPush = wrapFirebaseInitPush(base.initPush, const FirebaseOptions(
		apiKey: '$apiKey',
		appId: '$appId',
		messagingSenderId: '$messagingSenderId',
		projectId: '$projectId',
	));
''';
	}

	var gen = '''// This file has been generated by gen_main.dart - DO NOT EDIT
import 'main.dart' as base;

$imports
void main() {
$body
	base.main();
}
''';

	await File(outputFilename).writeAsString(gen);
}
