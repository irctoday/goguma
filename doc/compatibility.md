# Server compatibility

Goguma can connect to any IRC server. However, some servers provide a better
experience.

The [soju] bouncer is a recommended companion for Goguma, because they have
been developped together.

## Push notifications

If the server supports the IRC [`soju.im/webpush`][webpush] extension, Goguma
can leverage Android's native push notification system. This lowers battery
consumption and provides instant notifications.

soju supports this feature.

## Background synchronization and infinite scrolling

If the server supports the IRC [chathistory] extension, Goguma can synchronize
conversations in the background (instead of missing messages, or having to keep
a persistent connection to the server). This extension also enables infinite
scrolling to easily access past messages in a conversation.

Ergo, soju and UnrealIRCd support this feature.

## IRCv3

Features such as typing indicators, replies, read marker synchronization and
more are supported via other [IRCv3 extensions]. See the [IRCv3 support matrix]
for more information.

[soju]: https://soju.im
[webpush]: https://git.sr.ht/~emersion/soju/tree/master/item/doc/ext/webpush.md
[chathistory]: https://ircv3.net/specs/extensions/chathistory
[IRCv3 extensions]: https://ircv3.net/irc/
[IRCv3 support matrix]: https://ircv3.net/software/clients#mobile-clients
