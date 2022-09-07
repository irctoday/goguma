# Permissions

On Android, Goguma requests the following permissions:

- `INTERNET`: to connect to IRC servers.
- `ACCESS_NETWORK_STATE`: to reconnect to IRC servers when becoming online.
- `WAKE_LOCK`, `FOREGROUND_SERVICE`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`:
  to keep running in the background when the server doesn't support the IRC
  chathistory extension ([flutter_background]).
- `VIBRATE`, `POST_NOTIFICATIONS`: to show notifications
  ([flutter_local_notifications]).

[flutter_background]: https://pub.dev/packages/flutter_background#android
[flutter_local_notifications]: https://github.com/MaikuB/flutter_local_notifications/blob/master/flutter_local_notifications/android/src/main/AndroidManifest.xml
