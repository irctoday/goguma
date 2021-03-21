import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'irc.dart';
import 'models.dart';

class BufferPage extends StatefulWidget {
	@override
	BufferPageState createState() => BufferPageState();
}

class BufferPageState extends State<BufferPage> {
	final composerFocusNode = FocusNode();
	final composerFormKey = GlobalKey<FormState>();
	final composerController = TextEditingController();

	void submitComposer() {
		if (composerController.text != '') {
			var buffer = context.read<BufferModel>();
			var client = context.read<Client>();
			var msg = IRCMessage('PRIVMSG', params: [buffer.name, composerController.text]);
			client.send(msg);
			buffer.addMessage(IRCMessage(msg.cmd, params: msg.params, prefix: IRCPrefix(client.nick)));
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
								context.read<Client>().send(IRCMessage('PART', params: [buffer.name]));
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
						var msg = messages[messages.length - index - 1];
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
										TextSpan(text: body),
									],
									style: textStyle,
								)),
							),
						);
					},
				)),
				Material(elevation: 15, child: Container(
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
