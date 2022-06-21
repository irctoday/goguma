import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../irc.dart';
import '../models.dart';

class EditBouncerNetworkPage extends StatefulWidget {
	static const routeName = '/settings/network/edit-bouncer';

	final BouncerNetworkModel? network;
	final IrcUri? initialUri;

	const EditBouncerNetworkPage({ Key? key, this.network, this.initialUri }) : super(key: key);

	@override
	State<EditBouncerNetworkPage> createState() => _EditBouncerNetworkPageState();
}

class _EditBouncerNetworkPageState extends State<EditBouncerNetworkPage> {
	final GlobalKey<FormState> _formKey = GlobalKey();

	late final TextEditingController _nameController;
	late final TextEditingController _urlController;
	late final TextEditingController _nicknameController;
	late final TextEditingController _usernameController;
	late final TextEditingController _realnameController;
	late final TextEditingController _passController;

	bool _expanded = false;
	bool _loading = false;

	@override
	void initState() {
		super.initState();

		String? host;
		int? port;
		var tls = true;

		var initialUri = widget.initialUri;
		var network = widget.network;
		if (initialUri != null) {
			host = initialUri.host;
			port = initialUri.port;
		} else if (network != null) {
			host = network.host;
			port = network.port;
			tls = network.tls != false;
		}

		var url = host ?? '';
		var defaultPort = 6697;
		if (!tls) {
			url = 'irc+insecure://' + url;
			defaultPort = 6667;
		}
		if (port != null && port != defaultPort) {
			url = url + ':$port';
		}

		var name = network?.name;
		if (name == network?.host) {
			name = null;
		}

		_nameController = TextEditingController(text: name);
		_urlController = TextEditingController(text: url);
		_nicknameController = TextEditingController(text:  network?.nickname);
		_usernameController = TextEditingController(text: network?.username);
		_realnameController = TextEditingController(text: network?.realname);
		_passController = TextEditingController(text: network?.pass);
	}

	@override
	void dispose() {
		_urlController.dispose();
		_nicknameController.dispose();
		_usernameController.dispose();
		_realnameController.dispose();
		_passController.dispose();
		super.dispose();
	}

	void _submit() async {
		if (!_formKey.currentState!.validate() || _loading) {
			return;
		}

		var networkList = context.read<NetworkListModel>();

		NetworkModel? mainNetwork;
		for (var network in networkList.networks) {
			if (network.networkEntry.bouncerId == null) {
				mainNetwork = network;
				break;
			}
		}
		if (mainNetwork == null) {
			throw Exception('No main network found');
		}

		var client = context.read<ClientProvider>().get(mainNetwork);

		Uri uri = parseServerUri(_urlController.text);
		var attrs = {
			'name': _nameController.text,
			'host': uri.host,
			'port': uri.hasPort ? uri.port.toString() : null,
			'tls': uri.scheme != 'irc+insecure' ? '1' : '0',
			'nickname': _nicknameController.text,
			'username': _usernameController.text,
			'realname': _realnameController.text,
			'pass': _passController.text,
		};

		setState(() {
			_loading = true;
		});

		try {
			if (widget.network == null) {
				await client.addBouncerNetwork(attrs);
			} else {
				await client.changeBouncerNetwork(widget.network!.id, attrs);
			}

			if (mounted) {
				Navigator.pop(context);
			}
		} on Exception catch (err) {
			// TODO: surface the error to the user
			print('Failed to save network: $err');

			if (mounted) {
				setState(() {
					_loading = false;
				});
			}
		}
	}

	@override
	Widget build(BuildContext context) {
		List<Widget> expandedFields = [
			TextFormField(
				controller: _nameController,
				decoration: InputDecoration(labelText: 'Network name (optional)'),
			),
			TextFormField(
				controller: _nicknameController,
				decoration: InputDecoration(labelText: 'Nickname (optional)'),
			),
			TextFormField(
				controller: _usernameController,
				decoration: InputDecoration(labelText: 'Username (optional)'),
			),
			TextFormField(
				controller: _realnameController,
				decoration: InputDecoration(labelText: 'Display name (optional)'),
			),
			TextFormField(
				obscureText: true,
				controller: _passController,
				decoration: InputDecoration(labelText: 'Server password (optional)'),
			),
		];

		return Scaffold(
			appBar: AppBar(
				title: Text(widget.network == null ? 'Add network' : 'Edit network'),
			),
			body: Form(
				key: _formKey,
				child: Container(padding: EdgeInsets.all(10), child: Column(children: [
					TextFormField(
						keyboardType: TextInputType.url,
						controller: _urlController,
						decoration: InputDecoration(labelText: 'Server'),
						validator: (value) {
							if (value!.isEmpty) {
								return 'Required';
							}
							try {
								parseServerUri(value);
							} on FormatException catch(e) {
								return e.message;
							}
							return null;
						},
					),
					AnimatedCrossFade(
						duration: const Duration(milliseconds: 300),
						firstChild: Row(
							mainAxisAlignment: MainAxisAlignment.center,
							children: [Container(
								padding: EdgeInsets.all(10),
								child: TextButton.icon(
									label: Text('ADVANCED'),
									icon: Icon(Icons.expand_more, size: 18),
									onPressed: () {
										setState(() {
											_expanded = true;
										});
									},
								),
							)],
						),
						secondChild: Column(children: expandedFields),
						crossFadeState: !_expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
					),
					SizedBox(height: 20),
					if (_loading) FloatingActionButton.extended(
						onPressed: _submit,
						label: Text(widget.network == null ? 'Add' : 'Save'),
					),
				])),
			),
		);
	}
}
