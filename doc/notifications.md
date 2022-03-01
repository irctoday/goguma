# Notifications

Traditional IRC clients keep their connection to the server alive while
they're running. This is an issue on mobile devices because Android will
enforce multiple restrictions for background apps to save battery power.

Goguma will open notifications for new messages even if the app is in the
background. Depending on the server, Goguma will pick a different strategy.

## Servers supporting chathistory

If all configured servers support the IRCv3 [chathistory] extension, Goguma
will setup a periodic background job to poll for new messages (via
[workmanager]). Android will wake up Goguma when the network connectivity and
battery status allows it.

Android may pause or kill Goguma between the periodic checks, so notifications
may not be instantaneous. The plan to fix this is to implement
[push notifications][web-push-rfc].

Note, some manufacturers have a flawed WorkManager implementation, and may not
wake up Goguma after the user has dismissed it from the recent apps or after
the device has rebooted.

## Servers not supporting chathistory

If one of the servers doesn't support the chathistory extension, Goguma needs
to keep running in the background and force the mobile device's radio to stay
on, or else risks dropping messages. Unfortunately, this will consume more
power from the battery.

Goguma will ask additional permissions to achieve this. When enabled, a
persistent notification will be displayed.

[chathistory]: https://ircv3.net/specs/extensions/chathistory
[workmanager]: https://pub.dev/packages/workmanager
[web-push-rfc]: https://github.com/ircv3/ircv3-specifications/pull/471
