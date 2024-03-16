# [goguma]

[![builds.sr.ht status](https://builds.sr.ht/~emersion/goguma/commits/master.svg)](https://builds.sr.ht/~emersion/goguma/commits/master?)

An IRC client for mobile devices.

Goals:

- Modern: support for many IRCv3 extensions, plus some special support for IRC
  bouncers.
- Easy to use: offer a simple, straightforward interface.
- Offline-first: users should be able to read past conversations while offline,
  and network disruptions should be handled transparently
- Lightweight: go easy on resource usage to run smoothly on older phones and
  save battery power.
- Cross-platform: the main target platforms are Linux and Android, iOS is also
  supported.

If you want to try out goguma on Android, you can use [our F-Droid repository]
which provides nightly builds. Goguma is also available on the
[official F-Droid repository]. Community-supported Goguma versions are
available on the [Google Play Store] and the [Apple App Store].

For more information about using Goguma, see our [documentation].

<img src="https://l.sr.ht/ah3N.png" width="220" alt="Conversation list">
<img src="https://l.sr.ht/5NNh.png" width="220" alt="Conversation view">
<img src="https://l.sr.ht/7tDh.png" width="220" alt="Conversation details">
<img src="https://l.sr.ht/VoM9.png" width="220" alt="Conversation view, dark">

## Compiling

### For the Linux platform

Develop with:

    flutter run -d linux

Build with:

    flutter build linux

The built binary is in `build/linux/release/bundle/goguma`.

### For the Android platform

Build with:

    flutter build apk

The built APK is in `build/app/outputs/flutter-apk/app-release.apk`.

### For the iOS platform

Build with:

    flutter build ios # Build .app
    flutter build ipa # Build .ipa
    flutter build ipa --release # Build .ipa for App Store/Testflight

The built ipa file is in `build/ios/ipa`, ready for upload with [Transporter].

Please note that the bundle identifier is currently hardcoded to the one currently
being used for App Store distribution. You may want to change it if you want to
distribute Goguma yourself on the App Store, or a third-party platform.

## Contributing

Send patches to the [mailing list], report bugs on the [issue tracker]. Discuss
in [#emersion on Libera Chat].

If you aren't familiar with `git send-email`, you can use the
[web interface][git-send-email-web] to submit patches.

## License

AGPLv3 (see LICENSE) with an application store exception. As an additional
permission under section 7, you are allowed to distribute the software through
an application store, even if that store has restrictive terms and conditions
that are incompatible with the AGPL, provided that the source is also available
under the AGPL with or without this permission through a channel without those
restrictive terms and conditions.

Copyright (C) 2021 The goguma Contributors

[goguma]: https://sr.ht/~emersion/goguma/
[our F-Droid repository]: https://fdroid.emersion.fr/#goguma-nightly
[official F-Droid repository]: https://f-droid.org/packages/fr.emersion.goguma/
[Google Play Store]: https://play.google.com/store/apps/details?id=fr.emersion.goguma.play
[Apple App Store]: https://apps.apple.com/fr/app/goguma-irc/id6470394620
[documentation]: doc/README.md
[mailing list]: https://lists.sr.ht/~emersion/goguma-dev
[issue tracker]: https://todo.sr.ht/~emersion/goguma
[#emersion on Libera Chat]: ircs://irc.libera.chat/#emersion
[git-send-email-web]: https://man.sr.ht/git.sr.ht/#sending-patches-upstream
[Transporter]: https://apps.apple.com/us/app/transporter/id1450874784
