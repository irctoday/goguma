import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../linkify.dart';
import '../models.dart';
import '../notification_controller.dart';
import '../prefs.dart';
import '../widget/composer.dart';
import '../widget/network_indicator.dart';
import '../widget/swipe_action.dart';
import 'buffer_details.dart';
import 'buffer_list.dart';

class BufferPage extends StatefulWidget {
	static const routeName = '/buffer';

	final String? unreadMarkerTime;

	const BufferPage({ Key? key, this.unreadMarkerTime }) : super(key: key);

	@override
	State<BufferPage> createState() => _BufferPageState();

	static void open(BuildContext context, String name, NetworkModel network) async {
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();
		var client = clientProvider.get(network);
		var navigator = Navigator.of(context);

		var buffer = bufferList.get(name, network);
		if (buffer == null) {
			var db = context.read<DB>();
			var entry = await db.storeBuffer(BufferEntry(name: name, network: network.networkId));
			buffer = BufferModel(entry: entry, network: network);
			bufferList.add(buffer);
		}

		// TODO: this is racy if the user has navigated away since the
		// BufferPage.open() call
		var until = ModalRoute.withName(BufferListPage.routeName);
		navigator.pushNamedAndRemoveUntil(routeName, until, arguments: buffer);

		if (client.isChannel(name)) {
			_join(client, buffer);
		} else {
			clientProvider.fetchBufferUser(buffer);
			client.monitor([name]);
		}
	}
}

void _join(Client client, BufferModel buffer) async {
	if (buffer.joined) {
		return;
	}

	buffer.joining = true;
	try {
		await client.join([buffer.name]);
	} on IrcException catch (err) {
		print('Failed to join "${buffer.name}": $err');
	} finally {
		buffer.joining = false;
	}
}

class _BufferPageState extends State<BufferPage> with WidgetsBindingObserver {
	final _scrollController = ScrollController();
	final _listKey = GlobalKey();
	final GlobalKey<ComposerState> _composerKey = GlobalKey();

	bool _activated = true;
	bool _chatHistoryLoading = false;

	bool _showJumpToBottom = false;

	@override
	void initState() {
		super.initState();

		WidgetsBinding.instance.addObserver(this);

		_scrollController.addListener(_handleScroll);

		// Timer.run prevents calling setState() from inside initState()
		Timer.run(_loadMessages);
	}

	void _loadMessages() async {
		var buffer = context.read<BufferModel>();
		if (!buffer.messageHistoryLoaded) {
			// TODO: only load a partial view of the messages
			var entries = await context.read<DB>().listMessages(buffer.id);
			buffer.populateMessageHistory(entries.map((entry) {
				return MessageModel(entry: entry);
			}).toList());

			if (!mounted) {
				return;
			}

			if (buffer.messages.length < 100) {
				_fetchChatHistory();
			}
		}

		_updateBufferFocus();
	}

	void _handleMessageSwipe(MessageModel msg) {
		var prefix = '${msg.msg.source!.name}: ';
		_composerKey.currentState!.setTextPrefix(prefix);
	}

	void _handleScroll() {
		if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
			_fetchChatHistory();
		}

		var showJumpToBottom = _scrollController.position.pixels > _scrollController.position.viewportDimension;
		if (_showJumpToBottom != showJumpToBottom) {
			setState(() {
				_showJumpToBottom = showJumpToBottom;
			});
		}
	}

	void _fetchChatHistory() async {
		if (_chatHistoryLoading) {
			return;
		}

		var clientProvider = context.read<ClientProvider>();
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		if (!buffer.messageHistoryLoaded || !client.caps.enabled.contains('draft/chathistory')) {
			return;
		}

		setState(() {
			_chatHistoryLoading = true;
		});

		try {
			await clientProvider.fetchChatHistory(buffer);
		} finally {
			setState(() {
				_chatHistoryLoading = false;
			});
		}
	}

	@override
	void dispose() {
		_scrollController.removeListener(_handleScroll);
		_scrollController.dispose();
		WidgetsBinding.instance.removeObserver(this);
		super.dispose();
	}

	@override
	void deactivate() {
		_activated = false;
		_updateBufferFocus();
		super.deactivate();
	}

	@override
	void activate() {
		super.activate();
		_activated = true;
		_updateBufferFocus();
	}

	@override
	void didChangeAppLifecycleState(AppLifecycleState state) {
		super.didChangeAppLifecycleState(state);
		_updateBufferFocus();
	}

	void _updateBufferFocus() {
		var buffer = context.read<BufferModel>();
		var state = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
		buffer.focused = state == AppLifecycleState.resumed && _activated;
		if (buffer.focused) {
			_markRead();
		}
	}

	void _markRead() {
		var buffer = context.read<BufferModel>();
		var notifController = context.read<NotificationController>();

		if (buffer.unreadCount > 0 && buffer.messages.length > 0) {
			buffer.entry.lastReadTime = buffer.messages.last.entry.time;
			context.read<DB>().storeBuffer(buffer.entry);

			var client = context.read<Client>();
			if (buffer.entry.lastReadTime != null && client.state != ClientState.disconnected) {
				client.setReadMarker(buffer.name, buffer.entry.lastReadTime!);
			}
		}
		buffer.unreadCount = 0;

		notifController.cancelAllWithBuffer(buffer);
	}

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var prefs = context.read<Prefs>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();

		var subtitle = buffer.topic ?? buffer.realname;
		var isOnline = network.state == NetworkState.synchronizing || network.state == NetworkState.online;
		var canSendMessage = isOnline;
		var isChannel = client.isChannel(buffer.name);
		if (isChannel) {
			canSendMessage = canSendMessage && buffer.joined;
		} else {
			canSendMessage = canSendMessage && buffer.online != false;
		}
		var messages = buffer.messages;

		var compact = prefs.bufferCompact;
		var showTyping = prefs.typingIndicator;
		if (!client.caps.enabled.contains('message-tags')) {
			showTyping = false;
		}

		if (canSendMessage && showTyping) {
			var typingNicks = buffer.typing;
			if (typingNicks.isNotEmpty) {
				subtitle = typingNicks.join(', ') + ' ${typingNicks.length > 1 ? 'are' : 'is'} typing...';
			}
		}

		Widget? joinBanner;
		if (isOnline && isChannel && !buffer.joined && !buffer.joining) {
			joinBanner = MaterialBanner(
				content: Text('You have left this channel.'),
				actions: [
					TextButton(
						child: Text('JOIN'),
						onPressed: () {
							_join(client, buffer);
						},
					),
				],
			);
		}

		var msgList = ListView.builder(
			key: _listKey,
			reverse: true,
			controller: _scrollController,
			itemCount: messages.length,
			itemBuilder: (context, index) {
				var msgIndex = messages.length - index - 1;
				var msg = messages[msgIndex];
				var prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;

				if (compact) {
					return _CompactMessageItem(msg: msg, prevMsg: prevMsg, last: msgIndex == messages.length - 1);
				}

				var nextMsg = msgIndex + 1 < messages.length ? messages[msgIndex + 1] : null;

				VoidCallback? onSwipe;
				if (isChannel) {
					onSwipe = () => _handleMessageSwipe(msg);
				}

				return _MessageItem(
					key: ValueKey(msg.id),
					msg: msg,
					prevMsg: prevMsg,
					nextMsg: nextMsg,
					unreadMarkerTime: widget.unreadMarkerTime,
					onSwipe: onSwipe,
				);
			},
		);

		Widget? composer;
		if (canSendMessage) {
			composer = Material(elevation: 15, child: Container(
				padding: EdgeInsets.all(10),
				child: Composer(key: _composerKey),
			));
		}

		Widget? jumpToBottom;
		if (_showJumpToBottom) {
			jumpToBottom = Positioned(
				right: 15,
				bottom: 15,
				child: FloatingActionButton(
					mini: true,
					tooltip: 'Jump to bottom',
					child: const Icon(Icons.keyboard_double_arrow_down, size: 18),
					backgroundColor: Colors.grey,
					foregroundColor: Colors.white,
					onPressed: () {
						_scrollController.animateTo(
							0,
							duration: Duration(milliseconds: 200),
							curve: Curves.easeInOut,
						);
					},
				),
			);
		}

		return Scaffold(
			appBar: AppBar(
				title: InkResponse(
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Text(buffer.name, overflow: TextOverflow.fade),
							if (subtitle != null) Text(
								stripAnsiFormatting(subtitle),
								style: TextStyle(fontSize: 12.0),
								overflow: TextOverflow.fade,
							),
						],
					),
					onTap: () {
						Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
					},
				),
				actions: [
					PopupMenuButton<String>(
						onSelected: (key) {
							switch (key) {
							case 'details':
								Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
								break;
							case 'pin':
								context.read<BufferListModel>().setPinned(buffer, !buffer.pinned);
								context.read<DB>().storeBuffer(buffer.entry);
								break;
							case 'mute':
								context.read<BufferListModel>().setMuted(buffer, !buffer.muted);
								context.read<DB>().storeBuffer(buffer.entry);
								break;
							case 'part':
								var client = context.read<Client>();
								if (client.isChannel(buffer.name)) {
									client.send(IrcMessage('PART', [buffer.name]));
								} else {
									client.unmonitor([buffer.name]);
								}
								context.read<BufferListModel>().remove(buffer);
								context.read<DB>().deleteBuffer(buffer.entry.id!);
								Navigator.pop(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Details'), value: 'details'),
								PopupMenuItem(child: Text(buffer.pinned ? 'Unpin' : 'Pin'), value: 'pin'),
								PopupMenuItem(child: Text(buffer.muted ? 'Unmute' : 'Mute'), value: 'mute'),
								if (isOnline) PopupMenuItem(child: Text('Leave'), value: 'part'),
							];
						},
					),
				],
			),
			body: NetworkIndicator(network: network, child: Column(children: [
				if (joinBanner != null) joinBanner,
				Expanded(child: Stack(children: [
					msgList,
					if (jumpToBottom != null) jumpToBottom,
				])),
				if (composer != null) composer,
			])),
		);
	}
}

class _CompactMessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg;
	final bool last;

	const _CompactMessageItem({
		Key? key,
		required this.msg,
		this.prevMsg,
		this.last = false,
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var prevIrcMsg = prevMsg?.msg;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;

		var textStyle = TextStyle(color: Theme.of(context).textTheme.bodyText1!.color);

		List<TextSpan> textSpans;
		if (ctcp != null && ctcp.cmd == 'ACTION') {
			textStyle = textStyle.apply(fontStyle: FontStyle.italic);

			if (ctcp.cmd == 'ACTION') {
				textSpans = applyAnsiFormatting(ctcp.param ?? '', textStyle);
			} else {
				textSpans = [TextSpan(text: 'has sent a CTCP "${ctcp.cmd}" command', style: textStyle)];
			}
		} else {
			textSpans = applyAnsiFormatting(ircMsg.params[1], textStyle);
		}

		textSpans = textSpans.map((span) {
			var linkStyle = span.style!.apply(decoration: TextDecoration.underline);
			return linkify(context, span.text!, textStyle: span.style!, linkStyle: linkStyle);
		}).toList();

		List<Widget> stack = [];
		List<TextSpan> content = [];

		if (!prevMsgSameSender) {
			var colorSwatch = Colors.primaries[sender.hashCode % Colors.primaries.length];
			var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);
			var senderStyle = TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold);
			stack.add(Positioned(
				top: 0,
				left: 0,
				child: Text(sender, style: senderStyle),
			));
			content.add(TextSpan(
				text: sender,
				style: senderStyle.apply(color: Color(0x00000000)),
			));
		}

		content.addAll(textSpans);

		var prevEntry = prevMsg?.entry;
		if (!prevMsgSameSender || prevEntry == null || entry.dateTime.difference(prevEntry.dateTime) > Duration(minutes: 2)) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var timeText = '\u00A0[$hh:$mm]';
			var timeStyle = TextStyle(color: Theme.of(context).textTheme.caption!.color);
			stack.add(Positioned(
				bottom: 0,
				right: 0,
				child: Text(timeText, style: timeStyle),
			));
			content.add(TextSpan(
				text: timeText,
				style: timeStyle.apply(color: Color(0x00000000)),
			));
		}

		stack.add(Container(
			margin: EdgeInsets.only(left: 4),
			child: SelectableText.rich(
				TextSpan(
					children: content,
				),
			),
		));

		return Container(
			margin: EdgeInsets.only(top: prevMsgSameSender ? 0 : 2.5, bottom: last ? 10 : 0, left: 4, right: 5),
			child: Stack(children: stack),
		);
	}
}

class _MessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg, nextMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onSwipe;

	const _MessageItem({
		Key? key,
		required this.msg,
		this.prevMsg,
		this.nextMsg,
		this.unreadMarkerTime,
		this.onSwipe
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();

		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var prevIrcMsg = prevMsg?.msg;
		var prevCtcp = prevIrcMsg != null ? CtcpMessage.parse(prevIrcMsg) : null;
		var prevEntry = prevMsg?.entry;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;
		var prevMsgIsAction = prevCtcp != null && prevCtcp.cmd == 'ACTION';

		var nextMsgSameSender = nextMsg != null && ircMsg.source!.name == nextMsg!.msg.source!.name;

		var isAction = ctcp != null && ctcp.cmd == 'ACTION';
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());
		var isFirstInGroup = showUnreadMarker || !prevMsgSameSender || (prevMsgIsAction != isAction);
		var showTime = !nextMsgSameSender || nextMsg!.entry.dateTime.difference(entry.dateTime) > Duration(minutes: 2);

		var unreadMarkerColor = Theme.of(context).colorScheme.secondary;
		var eventColor = DefaultTextStyle.of(context).style.color!.withOpacity(0.5);

		var boxColor = Colors.primaries[sender.hashCode % Colors.primaries.length].shade500;
		var boxAlignment = Alignment.centerLeft;
		var textStyle = DefaultTextStyle.of(context).style;

		if (client.isMyNick(sender)) {
			// Actions are displayed as if they were told by an external
			// narrator. To preserve this effect, always show actions on the
			// left side.
			boxColor = Colors.grey.shade200;
			if (!isAction) {
				boxAlignment = Alignment.centerRight;
			}
		}

		if (!isAction) {
			textStyle = DefaultTextStyle.of(context).style.apply(
				color: boxColor.computeLuminance() > 0.5 ? Colors.black : Colors.white,
			);
		}

		const margin = 16.0;
		var marginBottom = margin;
		if (nextMsg != null) {
			marginBottom = 0.0;
		}
		var marginTop = margin;
		if (!isFirstInGroup) {
			marginTop = margin / 4;
		}

		var senderTextSpan = TextSpan(
			text: sender,
			style: TextStyle(fontWeight: FontWeight.bold),
		);

		var linkStyle = textStyle.apply(decoration: TextDecoration.underline);

		List<InlineSpan> content;
		if (isAction) {
			// isAction can only ever be true if we have a ctcp
			var actionText = stripAnsiFormatting(ctcp!.param ?? '');

			content = [
				WidgetSpan(
					child: Container(
						width: 8.0,
						height: 8.0,
						margin: EdgeInsets.all(3.0),
						decoration: BoxDecoration(
							shape: BoxShape.circle,
							color: boxColor,
						),
					),
				),
				senderTextSpan,
				TextSpan(text: ' '),
				linkify(context, actionText, textStyle: textStyle, linkStyle: linkStyle),
			];
		} else {
			var body = stripAnsiFormatting(ircMsg.params[1]);
			content = [
				if (isFirstInGroup) senderTextSpan,
				if (isFirstInGroup) TextSpan(text: '\n'),
				linkify(context, body, textStyle: textStyle, linkStyle: linkStyle),
			];
		}

		Widget inner = SelectableText.rich(TextSpan(
			children: content,
			style: textStyle,
		));

		if (showTime) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var time = '   $hh:$mm';
			var timeStyle = textStyle.apply(
				color: textStyle.color!.withOpacity(0.5),
				fontSizeFactor: 0.8,
			);

			// Add a fully transparent text span with the time, so that the real
			// time text doesn't collide with the message text.
			content.add(TextSpan(text: time, style: timeStyle.apply(color: Color(0x00000000))));

			inner = Stack(children: [
				inner,
				Positioned(
					bottom: 0,
					right: 0,
					child: Text(time, style: timeStyle),
				),
			]);
		}

		Widget decoratedMessage;
		if (isAction) {
			decoratedMessage = Align(
				alignment: boxAlignment,
				child: Container(
					child: inner,
				),
			);
		} else {
			decoratedMessage = Align(
				alignment: boxAlignment,
				child: Container(
					decoration: BoxDecoration(
						borderRadius: BorderRadius.circular(10),
						color: boxColor,
					),
					padding: EdgeInsets.all(10),
					child: inner,
				),
			);
		}

		if (!client.isMyNick(sender)) {
			decoratedMessage = SwipeAction(
				child: decoratedMessage,
				background: Align(
					alignment: Alignment.centerLeft,
					child: Opacity(
						opacity: 0.6,
						child: Icon(Icons.reply),
					),
				),
				onSwipe: onSwipe,
			);
		}

		return Column(children: [
			if (showUnreadMarker) Container(
				margin: EdgeInsets.only(top: margin),
				child: Row(children: [
					Expanded(child: Divider(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Expanded(child: Divider(color: unreadMarkerColor)),
				]),
			),
			if (showDateMarker) Container(
				margin: EdgeInsets.symmetric(vertical: 20),
				child: Center(child: Text(_formatDate(localDateTime), style: TextStyle(color: eventColor))),
			),
			Container(
				margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: marginBottom),
				child: decoratedMessage,
			),
		]);
	}
}

bool _isSameDate(DateTime a, DateTime b) {
	return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.day.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}
