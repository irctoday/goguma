import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'client-snackbar.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

TextSpan _linkify(BuildContext context, String text, TextStyle textStyle) {
	var elements = linkify(text, options: LinkifyOptions(
		humanize: false,
		defaultToHttps: true,
	));
	var linkStyle = DefaultTextStyle.of(context).style.apply(color: Colors.blue);
	return buildTextSpan(
		elements,
		onOpen: (link) {
			launch(link.url);
		},
		style: textStyle,
		linkStyle: linkStyle,
	);
}

class BufferPage extends StatefulWidget {
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
		if (buffer.messageHistoryLoaded) {
			return;
		}

		// TODO: only load a partial view of the messages
		context.read<DB>().listMessages(buffer.id).then((entries) {
			buffer.populateMessageHistory(entries.map((entry) {
				return MessageModel(entry: entry, buffer: buffer);
			}).toList());
		});
	}

	void submitComposer() {
		if (composerController.text != '') {
			var buffer = context.read<BufferModel>();
			var client = context.read<Client>();

			var msg = IRCMessage('PRIVMSG', params: [buffer.name, composerController.text]);
			client.send(msg);

			msg = IRCMessage(msg.cmd, params: msg.params, prefix: IRCPrefix(client.nick));
			context.read<DB>().storeMessage(MessageEntry(msg, buffer.id)).then((entry) {
				if (!buffer.messageHistoryLoaded) {
					return;
				}
				buffer.addMessage(MessageModel(entry: entry, buffer: buffer));
			});
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
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var server = context.watch<ServerModel>();
		var connected = server.state == ClientState.registered;
		var messages = buffer.messages;
		return Scaffold(
			appBar: AppBar(
				title: Column(
					mainAxisAlignment: MainAxisAlignment.center,
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
						Text(buffer.name),
						Text(buffer.subtitle ?? "", style: TextStyle(fontSize: 12.0)),
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
			body: ClientSnackbar(client: client, child: Column(children: [
				Expanded(child: ListView.builder(
					reverse: true,
					itemCount: messages.length,
					itemBuilder: (context, index) {
						var msg = messages[messages.length - index - 1].msg;
						assert(msg.cmd == 'PRIVMSG' || msg.cmd == 'NOTICE');

						var sender = msg.prefix!.name;
						var body = msg.params[1];

						var colorSwatch = Colors.primaries[sender.hashCode % Colors.primaries.length];
						var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);

						//var boxColor = Theme.of(context).accentColor;
						var boxColor = colorScheme.primary;
						var boxAlignment = Alignment.centerLeft;
						var textStyle = DefaultTextStyle.of(context).style.apply(color: colorScheme.onPrimary);
						if (sender == client.nick) {
							boxColor = Colors.grey[200]!;
							boxAlignment = Alignment.centerRight;
							textStyle = DefaultTextStyle.of(context).style;
						}

						const margin = 16.0;
						var marginBottom = margin;
						if (index > 0) {
							marginBottom = 0.0;
						}

						return Align(
							alignment: boxAlignment,
							child: Container(
								decoration: BoxDecoration(
									borderRadius: BorderRadius.circular(10),
									color: boxColor,
								),
								padding: EdgeInsets.all(10),
								margin: EdgeInsets.only(left: margin, right: margin, top: margin, bottom: marginBottom),
								child: RichText(text: TextSpan(
									children: [
										TextSpan(text: sender + '\n', style: TextStyle(fontWeight: FontWeight.bold)),
										_linkify(context, body, textStyle),
									],
									style: textStyle,
								)),
							),
						);
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
			])),
		);
	}
}
