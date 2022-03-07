import 'dart:convert' show json;
import 'dart:io';

void main(List<String> args) async {
	if (args.length != 2) {
		stderr.writeln('usage: gen_firebase_options google-services.json firebase_options.dart');
		return;
	}

	var inputFilename = args[0];
	var outputFilename = args[1];

	var str = await File(inputFilename).readAsString();
	var data = json.decode(str);

	var projectId = data['project_info']['project_id'] as String;
	var messagingSenderId = data['project_info']['project_number'] as String;
	var appId = data['client'][0]['client_info']['mobilesdk_app_id'] as String;
	var apiKey = data['client'][0]['api_key'][0]['current_key'] as String;

	var gen = '''import 'package:firebase_core/firebase_core.dart';

const firebaseOptions = FirebaseOptions(
	apiKey: '$apiKey',
	appId: '$appId',
	messagingSenderId: '$messagingSenderId',
	projectId: '$projectId',
);
''';

	await File(outputFilename).writeAsString(gen);
}
