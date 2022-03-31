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
	late final TextEditingController _realnameController;
	late final bool _canEditRealname;
	late final int? _nicknameLen;
	late final int? _realnameLen;

	@override
	void initState() {
		super.initState();

		var client = context.read<ClientProvider>().get(widget.network);

		_nicknameController = TextEditingController(text: client.nick);
		_realnameController = TextEditingController(text: client.realname);

		_canEditRealname = client.caps.enabled.contains('setname');
		_nicknameLen = client.isupport.nickLen;
		_realnameLen = client.isupport.realnameLen;
	}

	@override
	void dispose() {
		_nicknameController.dispose();
		_realnameController.dispose();
		super.dispose();
	}

	void _submit() {
		Navigator.pop(context);

		var nickname = _nicknameController.text;
		var realname = _realnameController.text;

		var client = context.read<ClientProvider>().get(widget.network);
		if (nickname != client.nick) {
			client.setNickname(nickname).ignore();
		}
		if (realname != client.realname) {
			client.setRealname(realname).ignore();
		}
	}

	@override
	Widget build(BuildContext context) {
		return AlertDialog(
			title: Text('Edit profile'),
			content: Column(mainAxisSize: MainAxisSize.min, children: [
				TextFormField(
					controller: _nicknameController,
					decoration: InputDecoration(labelText: 'Nickname'),
					autofocus: true,
					maxLength: _nicknameLen,
				),
				if (_canEditRealname) TextFormField(
					controller: _realnameController,
					decoration: InputDecoration(labelText: 'Display name'),
					maxLength: _realnameLen,
				),
			]),
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
