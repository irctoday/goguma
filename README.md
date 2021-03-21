# goguma

An IRC client for mobile devices.

## Compiling

### For the Linux platform

Develop with:

    flutter run -d linux

Build with:

    flutter create --project-name goguma --platforms linux .
    flutter build linux

The built binary is in `build/linux/release/bundle/goguma`.

### For the Android platform

Build with:

    flutter create --org fr.emersion --project-name goguma --platforms android .
    flutter build apk

The built APK is in `build/app/outputs/flutter-apk/app-release.apk`.

## License

AGPLv3, see LICENSE.

Copyright (C) 2021 The goguma Contributors
