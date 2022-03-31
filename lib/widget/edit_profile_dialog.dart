import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../models.dart';

class EditProfileDialog extends StatefulWidget {
	final NetworkModel network;

	static void show(BuildContext context, NetworkModel network) {
		showDialog<void>(context: context, builder: (context) {
			return EditProfileDialog(network: network);
		});
	}

	const EditProfileDialog({ Key? key, required this.network }) : super(key: key);

	@override
	_EditProfileDialogState createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<EditProfileDialog> {
	late final TextEditingController _nicknameController;
	late final int? _nicknameLen;

	@override
	void initState() {
		super.initState();

		var client = context.read<ClientProvider>().get(widget.network);

		_nicknameController = TextEditingController(text: client.nick);

		_nicknameLen = client.isupport.nickLen;
	}

	@override
	void dispose() {
		_nicknameController.dispose();
		super.dispose();
	}

	void _submit() {
		Navigator.pop(context);

		var nickname = _nicknameController.text;

		var client = context.read<ClientProvider>().get(widget.network);
		if (nickname != client.nick) {
			client.setNickname(nickname).ignore();
		}
	}

	@override
	Widget build(BuildContext context) {
		return AlertDialog(
			title: Text('Edit profile'),
			content: TextFormField(
				controller: _nicknameController,
				decoration: InputDecoration(labelText: 'Nickname'),
				autofocus: true,
				maxLength: _nicknameLen,
				onFieldSubmitted: (_) {
					_submit();
				},
			),
			actions: [
				TextButton(
					child: Text('Cancel'),
					onPressed: () {
						Navigator.pop(context);
					},
				),
				ElevatedButton(
					child: Text('Save'),
					onPressed: () {
						_submit();
					},
				),
			],
		);
	}
}
