import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../irc.dart';
import '../models.dart';
import 'buffer.dart';

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

	bool _autoOpenBuffer = true;
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
		var navigatorState = Navigator.of(context);

		NetworkModel? mainNetwork;
		for (var network in networkList.networks) {
			if (network.networkEntry.caps.containsKey('soju.im/bouncer-networks')) {
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

		String bouncerNetId;
		try {
			if (widget.network == null) {
				bouncerNetId = await client.addBouncerNetwork(attrs);
			} else {
				bouncerNetId = widget.network!.id;
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

			return;
		}

		var entity = widget.initialUri?.entity;
		if (entity == null || !_autoOpenBuffer) {
			return;
		}

		try {
			var network = await _waitForNetwork(bouncerNetId);
			await _waitNetworkOnline(network);
			// TODO: show a spinner until we reach this point
			BufferPage.open(navigatorState.context, entity.name, network);
		} on Exception catch (err) {
			print('Failed to auto-open buffer "${entity.name}": $err');
		}
	}

	Future<NetworkModel> _waitForNetwork(String bouncerNetID) {
		var networkList = context.read<NetworkListModel>();
		var completer = Completer<NetworkModel>();

		void handleNetworkListChange() {
			for (var net in networkList.networks) {
				if (net.networkEntry.bouncerId == bouncerNetID) {
					completer.complete(net);
					break;
				}
			}
		}

		networkList.addListener(handleNetworkListChange);
		handleNetworkListChange();

		return completer.future.timeout(const Duration(seconds: 30)).whenComplete(() {
			networkList.removeListener(handleNetworkListChange);
		});
	}

	Future<void> _waitNetworkOnline(NetworkModel network) {
		var completer = Completer<void>();

		void handleNetworkChange() {
			if (network.state == NetworkState.online) {
				completer.complete();
			}
		}

		network.addListener(handleNetworkChange);
		handleNetworkChange();

		return completer.future.timeout(const Duration(seconds: 30)).whenComplete(() {
			network.removeListener(handleNetworkChange);
		});
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

		Widget? openBuffer;
		var entity = widget.initialUri?.entity;
		if (entity != null) {
			String content;
			switch (entity.type) {
			case IrcUriEntityType.channel:
				content = 'Join the channel ${entity.name}';
				break;
			case IrcUriEntityType.user:
				content = 'Start a conversation with ${entity.name}';
				break;
			}

			// TODO: for some reason without this the colors have bad contrast?
			var color = Theme.of(context).colorScheme.primaryContainer;

			openBuffer = InkWell(
				onTap: () {
					setState(() {
						_autoOpenBuffer = !_autoOpenBuffer;
					});
				},
				child: Row(children: [
					Checkbox(
						value: _autoOpenBuffer,
						activeColor: color,
						onChanged: (newValue) {
							setState(() {
								_autoOpenBuffer = newValue!;
							});
						},
					),
					Expanded(child: Text(content)),
				]),
			);
		}

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
					SizedBox(height: 10),
					if (openBuffer != null) openBuffer,
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
					if (!_loading) FloatingActionButton.extended(
						onPressed: _submit,
						label: Text(widget.network == null ? 'Add' : 'Save'),
					),
				])),
			),
		);
	}
}
