// firebase_options.dart is generated -- see doc/firebase.md
import 'firebase_options.dart';
import 'firebase.dart';
import 'main.dart' as base;

void main() {
	var initPush = base.initPush;
	base.initPush = () async {
		try {
			return await FirebasePushController.init(firebaseOptions);
		} on Exception catch (err) {
			print('Warning: failed to initialize Firebase: $err');
		}
		return await initPush();
	};

	base.main();
}
