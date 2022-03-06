import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-details-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'database.dart';
import 'irc.dart';
import 'linkify.dart';
import 'models.dart';
import 'swipe-action.dart';

Widget buildBufferPage(BuildContext context, BufferModel buf) {
	var client = context.read<ClientProvider>().get(buf.network);
	return MultiProvider(
		providers: [
			ChangeNotifierProvider<BufferModel>.value(value: buf),
			ChangeNotifierProvider<NetworkModel>.value(value: buf.network),
			Provider<Client>.value(value: client),
		],
		child: BufferPage(unreadMarkerTime: buf.entry.lastReadTime),
	);
}

class BufferPage extends StatefulWidget {
	final String? unreadMarkerTime;

	BufferPage({ Key? key, this.unreadMarkerTime }) : super(key: key);

	@override
	BufferPageState createState() => BufferPageState();
}

class BufferPageState extends State<BufferPage> with WidgetsBindingObserver {
	final composerFocusNode = FocusNode();
	final composerFormKey = GlobalKey<FormState>();
	final composerController = TextEditingController();
	final scrollController = ScrollController();

	bool _activated = true;
	bool _chatHistoryLoading = false;

	@override
	void initState() {
		super.initState();

		WidgetsBinding.instance!.addObserver(this);

		scrollController.addListener(_handleScroll);

		var buffer = context.read<BufferModel>();
		var future = Future.value();
		if (!buffer.messageHistoryLoaded) {
			// TODO: only load a partial view of the messages
			future = context.read<DB>().listMessages(buffer.id).then((entries) {
				buffer.populateMessageHistory(entries.map((entry) {
					return MessageModel(entry: entry);
				}).toList());

				if (buffer.messages.length < 100) {
					_fetchChatHistory();
				}
			});
		}

		future.then((_) {
			_updateBufferFocus();
		});
	}

	void submitComposer() {
		if (composerController.text != '') {
			var buffer = context.read<BufferModel>();
			var client = context.read<Client>();

			var msg = IrcMessage('PRIVMSG', params: [buffer.name, composerController.text]);
			client.send(msg);

			if (!client.caps.enabled.contains('echo-message')) {
				msg = IrcMessage(msg.cmd, params: msg.params, source: IrcSource(client.nick));
				var entry = MessageEntry(msg, buffer.id);
				context.read<DB>().storeMessages([entry]).then((_) {
					if (buffer.messageHistoryLoaded) {
						buffer.addMessages([MessageModel(entry: entry)], append: true);
					}
					context.read<BufferListModel>().bumpLastDeliveredTime(buffer, entry.time);
				});
			}
		}
		composerController.text = '';
		composerFocusNode.requestFocus();
	}

	void _handleMessageSwipe(MessageModel msg) {
		composerController.text = '${msg.msg.source!.name}: ';
		composerController.selection = TextSelection.collapsed(offset: composerController.text.length);
		composerFocusNode.requestFocus();
	}

	void _handleScroll() {
		if (scrollController.position.pixels == scrollController.position.maxScrollExtent) {
			_fetchChatHistory();
		}
	}

	void _fetchChatHistory() {
		if (_chatHistoryLoading) {
			return;
		}

		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		if (!buffer.messageHistoryLoaded) {
			return;
		}

		setState(() {
			_chatHistoryLoading = true;
		});

		var limit = 100;
		Future<void> future;
		if (buffer.messages.length > 0) {
			var t = buffer.messages.first.entry.time;
			future = client.fetchChatHistoryBefore(buffer.name, t, limit);
		} else {
			future = client.fetchChatHistoryLatest(buffer.name, null, limit);
		}

		future.whenComplete(() {
			setState(() {
				_chatHistoryLoading = false;
			});
		}).ignore();
	}

	@override
	void dispose() {
		composerController.dispose();
		scrollController.removeListener(_handleScroll);
		scrollController.dispose();
		WidgetsBinding.instance!.removeObserver(this);
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
		var state = WidgetsBinding.instance!.lifecycleState ?? AppLifecycleState.resumed;
		buffer.focused = state == AppLifecycleState.resumed && _activated;
		if (buffer.focused) {
			_markRead();
		}
	}

	void _markRead() {
		var buffer = context.read<BufferModel>();
		if (buffer.unreadCount > 0 && buffer.messages.length > 0) {
			buffer.entry.lastReadTime = buffer.messages.last.entry.time;
			context.read<DB>().storeBuffer(buffer.entry);

			var client = context.read<Client>();
			if (buffer.entry.lastReadTime != null) {
				client.setRead(buffer.name, buffer.entry.lastReadTime!);
			}
		}
		buffer.unreadCount = 0;
	}

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var subtitle = buffer.topic ?? buffer.realname;
		var canSendMessage = network.state == NetworkState.synchronizing || network.state == NetworkState.online;
		var isChannel = client.isChannel(buffer.name);
		if (isChannel) {
			canSendMessage = canSendMessage && buffer.joined;
		}
		var messages = buffer.messages;
		return Scaffold(
			appBar: AppBar(
				title: InkResponse(
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Text(buffer.name, overflow: TextOverflow.fade),
							if (subtitle != null) Text(
								subtitle,
								style: TextStyle(fontSize: 12.0),
								overflow: TextOverflow.fade,
							),
						],
					),
					onTap: () {
						Navigator.push(context, MaterialPageRoute(builder: (context) {
							return buildBufferDetailsPage(context, buffer);
						}));
					},
				),
				actions: [
					PopupMenuButton<String>(
						onSelected: (key) {
							switch (key) {
							case 'details':
								Navigator.push(context, MaterialPageRoute(builder: (context) {
									return buildBufferDetailsPage(context, buffer);
								}));
								break;
							case 'part':
								var client = context.read<Client>();
								if (client.isChannel(buffer.name)) {
									client.send(IrcMessage('PART', params: [buffer.name]));
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
								PopupMenuItem(child: Text('Leave'), value: 'part'),
							];
						},
					),
				],
			),
			body: Column(children: [
				Expanded(child: ListView.builder(
					reverse: true,
					controller: scrollController,
					itemCount: messages.length,
					itemBuilder: (context, index) {
						var msgIndex = messages.length - index - 1;
						var msg = messages[msgIndex];
						var prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;
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
				)),
				if (canSendMessage) Material(elevation: 15, child: Container(
					padding: EdgeInsets.all(10),
					child: Form(key: composerFormKey, child: Row(children: [
						Expanded(child: TextFormField(
							decoration: InputDecoration(
								hintText: 'Write a message...',
								border: InputBorder.none,
							),
							onFieldSubmitted: (value) {
								submitComposer();
							},
							focusNode: composerFocusNode,
							controller: composerController,
							textInputAction: TextInputAction.send,
						)),
						FloatingActionButton(
							onPressed: () {
								submitComposer();
							},
							tooltip: 'Send',
							child: Icon(Icons.send, size: 18),
							mini: true,
							elevation: 0,
						),
					])),
				)),
			]),
		);
	}
}

class _MessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg, nextMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onSwipe;

	_MessageItem({ Key? key, required this.msg, this.prevMsg, this.nextMsg, this.unreadMarkerTime, this.onSwipe }) : super(key: key);

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();

		var ircMsg = msg.msg;
		var entry = msg.entry;
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var prevIrcMsg = prevMsg?.msg;
		var prevEntry = prevMsg?.entry;

		var ctcp = CtcpMessage.parse(ircMsg);
		var sender = ircMsg.source!.name;
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showSender = showUnreadMarker || prevIrcMsg == null || ircMsg.source!.name != prevIrcMsg.source!.name;

		var unreadMarkerColor = Theme.of(context).accentColor;

		var colorSwatch = Colors.primaries[sender.hashCode % Colors.primaries.length];
		var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);

		//var boxColor = Theme.of(context).accentColor;
		var boxColor = colorScheme.primary;
		var boxAlignment = Alignment.centerLeft;
		var textStyle = DefaultTextStyle.of(context).style.apply(color: colorScheme.onPrimary);
		if (client.isMyNick(sender)) {
			boxColor = Colors.grey[200]!;
			boxAlignment = Alignment.centerRight;
			textStyle = DefaultTextStyle.of(context).style;
		}

		const margin = 16.0;
		var marginBottom = margin;
		if (nextMsg != null) {
			marginBottom = 0.0;
		}
		var marginTop = margin;
		if (!showSender) {
			marginTop = margin / 4;
		}

		var senderTextSpan = TextSpan(
			text: sender,
			style: TextStyle(fontWeight: FontWeight.bold),
		);

		var linkStyle = textStyle.apply(decoration: TextDecoration.underline);

		List<InlineSpan> content;
		if (ctcp != null && ctcp.cmd == 'ACTION') {
			textStyle = textStyle.apply(fontStyle: FontStyle.italic);

			String actionText;
			if (ctcp.cmd == 'ACTION') {
				actionText = stripAnsiFormatting(ctcp.param ?? '');
			} else {
				actionText = 'has sent a CTCP "${ctcp.cmd}" command';
			}

			content = [
				senderTextSpan,
				TextSpan(text: ' '),
				linkify(actionText, textStyle: textStyle, linkStyle: linkStyle),
			];
		} else {
			var body = stripAnsiFormatting(ircMsg.params[1]);
			content = [
				if (showSender) senderTextSpan,
				if (showSender) TextSpan(text: '\n'),
				linkify(body, textStyle: textStyle, linkStyle: linkStyle),
			];
		}

		Widget bubble = Align(
			alignment: boxAlignment,
			child: Container(
				decoration: BoxDecoration(
					borderRadius: BorderRadius.circular(10),
					color: boxColor,
				),
				padding: EdgeInsets.all(10),
				child: RichText(text: TextSpan(
					children: content,
					style: textStyle,
				)),
			),
		);
		if (!client.isMyNick(sender)) {
			bubble = SwipeAction(
				child: bubble,
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
			Container(
				margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: marginBottom),
				child: bubble,
			),
		]);
	}
}
