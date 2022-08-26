// firebase_options.dart is generated -- see doc/firebase.md
import 'firebase_options.dart';
import 'firebase.dart';
import 'main.dart' as base;

void main() {
	base.initPush = () => FirebasePushController.init(firebaseOptions);
	base.main();
}
