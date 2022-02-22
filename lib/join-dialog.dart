import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models.dart';

typedef JoinDialogCallback(String, ServerModel);

class JoinDialog extends StatefulWidget {
	final JoinDialogCallback? onSubmit;

	JoinDialog({ Key? key, this.onSubmit }) : super(key: key);

	@override
	JoinDialogState createState() => JoinDialogState();
}

class JoinDialogState extends State<JoinDialog> {
	TextEditingController nameController = TextEditingController(text: '#');
	ServerModel? server;

	@override
	void initState() {
		super.initState();
		server = context.read<ServerListModel>().servers.first;
	}

	void submit(BuildContext context) {
		widget.onSubmit?.call(nameController.text, server!);
		Navigator.pop(context);
	}

	@override
	void dispose() {
		nameController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		var servers = context.watch<ServerListModel>().servers;
		return AlertDialog(
			title: Text('Join channel'),
			content: Row(children: [
				Flexible(child: TextFormField(
					controller: nameController,
					decoration: InputDecoration(hintText: 'Name'),
					autofocus: true,
					onFieldSubmitted: (_) {
						submit(context);
					},
				)),
				SizedBox(width: 10),
				Flexible(child: DropdownButtonFormField<ServerModel>(
					value: server,
					onChanged: (ServerModel? value) {
						setState(() {
							server = value;
						});
					},
					items: servers.map((server) => DropdownMenuItem(
						value: server,
						child: Text(server.network ?? server.bouncerNetwork?.name ?? server.entry.host),
					)).toList(),
				)),
			]),
			actions: [
				FlatButton(
					child: Text('Cancel'),
					onPressed: () {
						Navigator.pop(context);
					},
				),
				ElevatedButton(
					child: Text('Join'),
					onPressed: () {
						submit(context);
					},
				),
			],
		);
	}
}
