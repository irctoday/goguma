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
	final TextEditingController _nameController = TextEditingController(text: '#');
	late NetworkModel _network;

	@override
	void initState() {
		super.initState();
		_network = context.read<NetworkListModel>().networks.first;
	}

	void _submit(BuildContext context) {
		var client = context.read<ClientProvider>().get(_network);
		var db = context.read<DB>();
		var name = _nameController.text;

		db.storeBuffer(BufferEntry(name: name, network: _network.networkId)).then((entry) {
			var buffer = BufferModel(entry: entry, network: _network);
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
		_nameController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		var networks = context.watch<NetworkListModel>().networks;
		return AlertDialog(
			title: Text('Join channel'),
			content: Row(children: [
				Flexible(child: TextFormField(
					controller: _nameController,
					decoration: InputDecoration(hintText: 'Name'),
					autofocus: true,
					onFieldSubmitted: (_) {
						_submit(context);
					},
				)),
				SizedBox(width: 10),
				Flexible(child: DropdownButtonFormField<NetworkModel>(
					value: _network,
					onChanged: (NetworkModel? value) {
						setState(() {
							_network = value!;
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
						_submit(context);
					},
				),
			],
		);
	}
}
