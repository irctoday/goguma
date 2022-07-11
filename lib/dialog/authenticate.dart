import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../models.dart';
import '../prefs.dart';

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

		_usernameController = TextEditingController(text: _client.params.saslPlain?.username ?? _client.nick);
	}

	void _submit() async {
		if (!_formKey.currentState!.validate()) {
			return;
		}

		setState(() {
			_loading = true;
		});

		var db = context.read<DB>();
		var prefs = context.read<Prefs>();
		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();
		var username = _usernameController.text;
		var password = _passwordController.text;

		var client = _client;
		var creds = SaslPlainCredentials(username, password);

		Exception? error;
		try {
			if (widget.network.networkEntry.bouncerId == null && client.state != ClientState.connected) {
				var clientParams = client.params.apply(saslPlain: creds);
				await client.connect(params: clientParams);
			} else {
				await client.authWithPlain(username, password);
			}
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

			// Reconnect all child networks
			for (var network in networkList.networks) {
				if (network.serverEntry != widget.network.serverEntry || network == widget.network) {
					continue;
				}

				var client = clientProvider.get(network);
				var clientParams = client.params.apply(saslPlain: creds);
				client.connect(params: clientParams).ignore();
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
