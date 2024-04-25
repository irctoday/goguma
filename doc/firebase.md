# Firebase Cloud Messaging

Firebase Cloud Messaging can be used in combination with [pushgarden] to enable
Web Push support on Android.

First, create a Firebase app and obtain the `google-services.json` file. Then
run:

    dart run tool/gen_main.dart --firebase /path/to/google-services.json lib/main_generated.dart

Then build Goguma with the generated main entrypoint, the Firebase Android
project property and your pushgarden instance:

    flutter build apk --target=lib/main_generated.dart --android-project-arg=firebase=true --dart-define=pushgardenEndpoint='https://example.org'

For instance, to connect from the Android emulator to a locally running
instance of pushgarden, one can use `http://10.0.2.2:8080`.

[pushgarden]: https://git.sr.ht/~emersion/pushgarden
