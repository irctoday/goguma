import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'client-controller.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

TextSpan _linkify(BuildContext context, String text, TextStyle textStyle) {
	var elements = linkify(text, options: LinkifyOptions(
		humanize: false,
		defaultToHttps: true,
	));
	var linkStyle = textStyle.apply(decoration: TextDecoration.underline);
	return buildTextSpan(
		elements,
		onOpen: (link) {
			launch(link.url);
		},
		style: textStyle,
		linkStyle: linkStyle,
	);
}

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

class BufferPageState extends State<BufferPage> {
	final composerFocusNode = FocusNode();
	final composerFormKey = GlobalKey<FormState>();
	final composerController = TextEditingController();

	@override
	void initState() {
		super.initState();

		var buffer = context.read<BufferModel>();
		var future = Future.value();
		if (!buffer.messageHistoryLoaded) {
			// TODO: only load a partial view of the messages
			future = context.read<DB>().listMessages(buffer.id).then((entries) {
				buffer.populateMessageHistory(entries.map((entry) {
					return MessageModel(entry: entry);
				}).toList());
			});
		}

		future.then((_) {
			if (buffer.unreadCount > 0 && buffer.messages.length > 0) {
				buffer.entry.lastReadTime = buffer.messages.last.entry.time;
				context.read<DB>().storeBuffer(buffer.entry);

				var client = context.read<Client>();
				if (buffer.entry.lastReadTime != null) {
					client.setRead(buffer.name, buffer.entry.lastReadTime!);
				}
			}
			buffer.unreadCount = 0;
		});

		buffer.focused = true;
	}

	void submitComposer() {
		if (composerController.text != '') {
			var buffer = context.read<BufferModel>();
			var client = context.read<Client>();

			var msg = IRCMessage('PRIVMSG', params: [buffer.name, composerController.text]);
			client.send(msg);

			if (!client.caps.enabled.contains('echo-message')) {
				msg = IRCMessage(msg.cmd, params: msg.params, prefix: IRCPrefix(client.nick));
				var entry = MessageEntry(msg, buffer.id);
				context.read<DB>().storeMessages([entry]).then((_) {
					if (buffer.messageHistoryLoaded) {
						buffer.addMessage(MessageModel(entry: entry));
					}
					context.read<BufferListModel>().bumpLastDeliveredTime(buffer, entry.time);
				});
			}
		}
		composerFormKey.currentState!.reset();
		composerFocusNode.requestFocus();
	}

	@override
	void dispose() {
		composerController.dispose();
		super.dispose();
	}

	@override
	void deactivate() {
		context.read<BufferModel>().focused = false;
		super.deactivate();
	}

	@override
	void activate() {
		context.read<BufferModel>().focused = true;
		super.activate();
	}

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var connected = network.state == NetworkState.synchronizing || network.state == NetworkState.online;
		var messages = buffer.messages;
		return Scaffold(
			appBar: AppBar(
				title: Column(
					mainAxisAlignment: MainAxisAlignment.center,
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
						Text(buffer.name, overflow: TextOverflow.fade),
						if (buffer.subtitle != null) Text(
							buffer.subtitle!,
							style: TextStyle(fontSize: 12.0),
							overflow: TextOverflow.fade,
						),
					],
				),
				actions: [
					PopupMenuButton<String>(
						onSelected: (key) {
							switch (key) {
							case 'part':
								var client = context.read<Client>();
								if (client.isChannel(buffer.name)) {
									client.send(IRCMessage('PART', params: [buffer.name]));
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
					itemCount: messages.length,
					itemBuilder: (context, index) {
						var msgIndex = messages.length - index - 1;
						var msg = messages[msgIndex].msg;
						var entry = messages[msgIndex].entry;
						assert(msg.cmd == 'PRIVMSG' || msg.cmd == 'NOTICE');

						var prevMsg = msgIndex > 0 ? messages[msgIndex - 1].msg : null;
						var prevEntry = prevMsg != null ? messages[msgIndex - 1].entry : null;

						var ctcp = CtcpMessage.parse(msg);
						var sender = msg.prefix!.name;
						var showUnreadMarker = prevEntry != null && widget.unreadMarkerTime != null && widget.unreadMarkerTime!.compareTo(entry.time) < 0 && widget.unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
						var showSender = showUnreadMarker || prevMsg == null || msg.prefix!.name != prevMsg.prefix!.name;

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
						if (index > 0) {
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
								_linkify(context, actionText, textStyle),
							];
						} else {
							var body = stripAnsiFormatting(msg.params[1]);
							content = [
								if (showSender) senderTextSpan,
								if (showSender) TextSpan(text: '\n'),
								_linkify(context, body, textStyle),
							];
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
							Align(
								alignment: boxAlignment,
								child: Container(
									decoration: BoxDecoration(
										borderRadius: BorderRadius.circular(10),
										color: boxColor,
									),
									padding: EdgeInsets.all(10),
									margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: marginBottom),
									child: RichText(text: TextSpan(
										children: content,
										style: textStyle,
									)),
								),
							),
						]);
					},
				)),
				if (connected) Material(elevation: 15, child: Container(
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
