import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../models.dart';

class AuthenticateDialog extends StatefulWidget {
	final NetworkModel network;

	static void show(BuildContext context, NetworkModel network) {
		showDialog<void>(context: context, builder: (context) {
			return AuthenticateDialog(network: network);
		});
	}

	const AuthenticateDialog({ Key? key, required this.network }) : super(key: key);

	@override
	State<AuthenticateDialog> createState() => _AuthenticateDialogState();
}

class _AuthenticateDialogState extends State<AuthenticateDialog> {
	final GlobalKey<FormState> _formKey = GlobalKey();
	late final TextEditingController _usernameController;
	final TextEditingController _passwordController = TextEditingController();

	bool _loading = false;
	Exception? _error;

	Client get _client => context.read<ClientProvider>().get(widget.network);

	@override
	void initState() {
		super.initState();

		_usernameController = TextEditingController(text: _client.nick);
	}

	void _submit() async {
		if (!_formKey.currentState!.validate()) {
			return;
		}

		setState(() {
			_loading = true;
		});

		var db = context.read<DB>();
		var username = _usernameController.text;
		var password = _passwordController.text;

		Exception? error;
		try {
			await _client.authWithPlain(username, password);
		} on Exception catch (err) {
			error = err;
		}

		if (!mounted) {
			return;
		}

		setState(() {
			_error = error;
			_loading = false;
		});

		if (error == null) {
			Navigator.pop(context);

			if (widget.network.networkEntry.bouncerId == null) {
				// TODO: also save SASL username
				widget.network.serverEntry.saslPlainPassword = password;
				db.storeServer(widget.network.serverEntry);
			}
		}
	}

	@override
	Widget build(BuildContext context) {
		var network = widget.network; // TODO: watch

		Widget content;
		if (!_loading) {
			content = Form(
				key: _formKey,
				child: Column(
					mainAxisSize: MainAxisSize.min,
					children: [
						TextFormField(
							controller: _usernameController,
							decoration: InputDecoration(labelText: 'Username'),
							validator: (value) {
								if (value == null || value == '') {
									return 'Required';
								}
								return null;
							},
						),
						TextFormField(
							controller: _passwordController,
							obscureText: true,
							decoration: InputDecoration(
								labelText: 'Password',
								errorText: _error?.toString(),
							),
							autofocus: true,
							validator: (value) {
								if (value == null || value == '') {
									return 'Required';
								}
								return null;
							},
						),
					],
				),
			);
		} else {
			content = Column(
				mainAxisSize: MainAxisSize.min,
				children: const [CircularProgressIndicator()],
			);
		}

		return AlertDialog(
			title: Text('Log in to ${network.displayName}'),
			content: content,
			actions: [
				TextButton(
					child: Text('CANCEL'),
					onPressed: () {
						Navigator.pop(context);
					},
				),
				if (!_loading) ElevatedButton(
					child: Text('LOG IN'),
					onPressed: () {
						_submit();
					},
				),
			],
		);
	}
}
