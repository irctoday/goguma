# Permissions

On Android, Goguma requests the following permissions:

- `INTERNET`: to connect to IRC servers.
- `WAKE_LOCK`, `FOREGROUND_SERVICE`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`:
  to keep running in the background when the server doesn't support the IRC
  chathistory extension ([flutter_background]).
- `RECEIVE_BOOT_COMPLETED`, `VIBRATE`, `USE_FULL_SCREEN_INTENT`,
  `SCHEDULE_EXACT_ALARM`, `POST_NOTIFICATIONS`: requested by
  [flutter_local_notifications] to open notifications. We don't actually need
  all of these, see [issue #1687][1687].

[flutter_background]: https://pub.dev/packages/flutter_background#android
[flutter_local_notifications]: https://github.com/MaikuB/flutter_local_notifications/blob/master/flutter_local_notifications/android/src/main/AndroidManifest.xml
[1687]: https://github.com/MaikuB/flutter_local_notifications/issues/1687
