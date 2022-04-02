import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
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
	final GlobalKey<FormState> _formKey = GlobalKey();
	late final TextEditingController _nicknameController;
	late final TextEditingController _realnameController;
	late final bool _canEditRealname;
	late final int? _nicknameLen;
	late final int? _realnameLen;

	@override
	void initState() {
		super.initState();

		var client = context.read<ClientProvider>().get(widget.network);

		var realname = client.realname;
		if (isStubRealname(realname, client.nick)) {
			realname = '';
		}

		_nicknameController = TextEditingController(text: client.nick);
		_realnameController = TextEditingController(text: realname);

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

	void _submit() async {
		if (!_formKey.currentState!.validate()) {
			return;
		}

		Navigator.pop(context);

		var client = context.read<ClientProvider>().get(widget.network);

		var nickname = _nicknameController.text;
		var realname = _realnameController.text;
		if (realname == '') {
			realname = nickname;
		}

		if (nickname != client.nick) {
			// Make sure the server accepts the new nickname before saving it
			// in our DB to avoid saving a bogus nickname.
			await client.setNickname(nickname);

			var db = context.read<DB>();
			widget.network.serverEntry.nick = nickname;
			await db.storeServer(widget.network.serverEntry);
		}
		if (realname != client.realname) {
			await client.setRealname(realname);
			// TODO: save it in the DB
		}
	}

	@override
	Widget build(BuildContext context) {
		return AlertDialog(
			title: Text('Edit profile'),
			content: Form(key: _formKey, child: Column(mainAxisSize: MainAxisSize.min, children: [
				TextFormField(
					controller: _nicknameController,
					decoration: InputDecoration(labelText: 'Nickname'),
					autofocus: true,
					maxLength: _nicknameLen,
					validator: (value) {
						if (value == null || value == '') {
							return 'A nickname is required';
						}
						return null;
					},
				),
				if (_canEditRealname) TextFormField(
					controller: _realnameController,
					decoration: InputDecoration(labelText: 'Display name (optional)'),
					maxLength: _realnameLen,
				),
			])),
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
