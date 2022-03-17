# [goguma]

[![builds.sr.ht status](https://builds.sr.ht/~emersion/goguma/commits.svg)](https://builds.sr.ht/~emersion/goguma/commits?)

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

If you want to try out goguma on Android, our CI provides
[nightly builds][android-ci] (check out build artifacts).

<img src="https://l.sr.ht/ah3N.png" width="220" alt="Conversation list">
<img src="https://l.sr.ht/5NNh.png" width="220" alt="Conversation view">
<img src="https://l.sr.ht/7tDh.png" width="220" alt="Conversation details">
<img src="https://l.sr.ht/VoM9.png" width="220" alt="Conversation view, dark">

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

    flutter build apk

The built APK is in `build/app/outputs/flutter-apk/app-release.apk`.

## Contributing

Send patches to the [mailing list], report bugs on the [issue tracker]. Discuss
in [#emersion on Libera Chat].

If you aren't familiar with `git send-email`, you can use the
[web interface][git-send-email-web] to submit patches.

## License

AGPLv3, see LICENSE.

Copyright (C) 2021 The goguma Contributors

[goguma]: https://sr.ht/~emersion/goguma/
[android-ci]: https://builds.sr.ht/~emersion/goguma/commits/android
[mailing list]: https://lists.sr.ht/~emersion/public-inbox
[issue tracker]: https://todo.sr.ht/~emersion/goguma
[#emersion on Libera Chat]: ircs://irc.libera.chat/#emersion
[git-send-email-web]: https://man.sr.ht/git.sr.ht/#sending-patches-upstream
