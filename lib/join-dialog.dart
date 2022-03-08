import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-page.dart';
import 'client-controller.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

class JoinDialog extends StatefulWidget {
	@override
	JoinDialogState createState() => JoinDialogState();
}

class JoinDialogState extends State<JoinDialog> {
	TextEditingController nameController = TextEditingController(text: '#');
	NetworkModel? network;

	@override
	void initState() {
		super.initState();
		network = context.read<NetworkListModel>().networks.first;
	}

	void submit(BuildContext context) {
		var client = context.read<ClientProvider>().get(network!);
		var db = context.read<DB>();
		var name = nameController.text;

		db.storeBuffer(BufferEntry(name: name, network: network!.networkId)).then((entry) {
			var buffer = BufferModel(entry: entry, network: network!);
			context.read<BufferListModel>().add(buffer);

			Navigator.pop(context);
			Navigator.push(context, MaterialPageRoute(builder: (context) {
				return buildBufferPage(context, buffer);
			}));

			if (client.isChannel(name)) {
				client.send(IrcMessage('JOIN', [name]));
			} else {
				fetchBufferUser(client, buffer);
				client.monitor([name]);
			}
		});
	}

	@override
	void dispose() {
		nameController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		var networks = context.watch<NetworkListModel>().networks;
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
				Flexible(child: DropdownButtonFormField<NetworkModel>(
					value: network,
					onChanged: (NetworkModel? value) {
						setState(() {
							network = value;
						});
					},
					items: networks.map((network) => DropdownMenuItem(
						value: network,
						child: Text(network.displayName),
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
