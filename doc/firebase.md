# Firebase Cloud Messaging

Firebase Cloud Messaging can be used in combination with [pushgarden] to enable
Web Push support on Android.

First, create a Firebase app and obtain the `google-services.json` file. Then
run:

    flutter pub run tool/gen_firebase_options.dart /path/to/google-services.json lib/firebase_options.dart

Then build Goguma with the Firebase main entrypoint, the Firebase Android
project property and your pushgarden instance:

    flutter build apk --target=lib/main_firebase.dart --android-project-arg=firebase=true --dart-define=pushgardenEndpoint='https://example.org'

For instance, to connect from the Android emulator to a locally running
instance of pushgarden, one can use `http://10.0.2.2:8080`.

[pushgarden]: https://git.sr.ht/~emersion/pushgarden
