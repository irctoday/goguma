# Android debugging

## From a computer

To obtain Android logs from a computer:

- Connect your phone to your computer via USB.
- Run `adb devices`, check that the phone appears in the list, authorize your
  computer from your phone if necessary.
- Run `adb logcat -c` to clear the current logs.
- Run `adb logcat >adb.log` to start collecting logs.
- Reproduce the bug in Goguma.
- Stop collecting logs and share the file.

It's possible to filter the logs with "flutter", however this will hide
messages produced by the Android libraries used by Goguma.

## From a phone

The [Logcat Reader] app can be used to read Android's logs directly from the
Android device. Note, a one-time setup with a computer is necessary before
being able to use it.

[Logcat Reader]: https://f-droid.org/en/packages/com.dp.logcatapp/
