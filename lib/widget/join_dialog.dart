import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../database.dart';
import '../models.dart';
import '../page/buffer.dart';

class JoinDialog extends StatefulWidget {
	static void show(BuildContext context) {
		showDialog(context: context, builder: (context) {
			return JoinDialog();
		});
	}

	@override
	JoinDialogState createState() => JoinDialogState();
}

class JoinDialogState extends State<JoinDialog> {
	final TextEditingController nameController = TextEditingController(text: '#');
	late NetworkModel network;

	@override
	void initState() {
		super.initState();
		network = context.read<NetworkListModel>().networks.first;
	}

	void submit(BuildContext context) {
		var client = context.read<ClientProvider>().get(network);
		var db = context.read<DB>();
		var name = nameController.text;

		db.storeBuffer(BufferEntry(name: name, network: network.networkId)).then((entry) {
			var buffer = BufferModel(entry: entry, network: network);
			context.read<BufferListModel>().add(buffer);

			Navigator.pop(context);
			Navigator.pushNamed(context, BufferPage.routeName, arguments: buffer);

			if (client.isChannel(name)) {
				join(client, buffer);
			} else if (client.isNick(name)) {
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
							network = value!;
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
