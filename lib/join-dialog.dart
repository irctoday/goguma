import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models.dart';

typedef JoinDialogCallback(String, NetworkModel);

class JoinDialog extends StatefulWidget {
	final JoinDialogCallback? onSubmit;

	JoinDialog({ Key? key, this.onSubmit }) : super(key: key);

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
		widget.onSubmit?.call(nameController.text, network!);
		Navigator.pop(context);
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
						child: Text(network.network ?? network.bouncerNetwork?.name ?? network.serverEntry.host),
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
