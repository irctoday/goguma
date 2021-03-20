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
	List<Message> messages = [
		Message(sender: 'romangg', body: 'I think it would be a nice way to push improvements for multi-seat'),
		Message(sender: 'emersion', body: 'just need to make sure we didn\'t miss any use-case'),
		Message(sender: 'pq', body: 'iirc it uses text-input-unstable something something'),
	];

	final composerFocusNode = FocusNode();
	final composerFormKey = GlobalKey<FormState>();
	final composerController = TextEditingController();

	void submitComposer() {
		if (composerController.text != '') {
			setState(() {
				messages.add(Message(sender: 'emersion', body: composerController.text));
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
		BufferModel buffer = context.watch<BufferModel>();
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
					itemCount: messages.length,
					itemBuilder: (context, index) {
						var msg = messages[index];

						var colorSwatch = Colors.primaries[msg.sender.hashCode % Colors.primaries.length];
						var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);

						//var boxColor = Theme.of(context).accentColor;
						var boxColor = colorScheme.primary;
						var boxAlignment = Alignment.centerLeft;
						var textStyle = DefaultTextStyle.of(context).style.apply(color: colorScheme.onPrimary);
						if (msg.sender == 'emersion') {
							boxColor = Colors.grey[200]!;
							boxAlignment = Alignment.centerRight;
							textStyle = DefaultTextStyle.of(context).style;
						}

						const margin = 16.0;
						var marginTop = margin;
						if (index > 0) {
							marginTop = 0.0;
						}

						return Align(
							alignment: boxAlignment,
							child: Container(
								decoration: BoxDecoration(
									borderRadius: BorderRadius.circular(10),
									color: boxColor,
								),
								padding: EdgeInsets.all(10),
								margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: margin),
								child: RichText(text: TextSpan(
									children: [
										TextSpan(text: msg.sender + '\n', style: TextStyle(fontWeight: FontWeight.bold)),
										TextSpan(text: msg.body),
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
