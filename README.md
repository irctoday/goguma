# goguma

An IRC client for mobile devices.

Goals:

- Modern: support for many IRCv3 extensions, plus some special support for IRC
  bouncers.
- Easy to use: offer a simple, straightforward interface.
- Offline-first: users should be able to read past conversations while offline,
  and network disruptions should be handled transparently
- Lightweight: go easy on resource usage to run smoothly on older phones and
  save battery power.
- Cross-platform: the main target platforms are Linux and Android.

<img src="https://l.sr.ht/4ZD5.png" style="width: 350px;">

## Compiling

### For the Linux platform

Setup the project with:

    flutter config --enable-linux-desktop
    flutter create --project-name goguma --platforms linux .

Develop with:

    flutter run -d linux

Build with:

    flutter build linux

The built binary is in `build/linux/release/bundle/goguma`.

### For the Android platform

Build with:

    flutter create --org fr.emersion --project-name goguma --platforms android --no-overwrite .
    flutter build apk

The built APK is in `build/app/outputs/flutter-apk/app-release.apk`.

## License

AGPLv3, see LICENSE.

Copyright (C) 2021 The goguma Contributors
