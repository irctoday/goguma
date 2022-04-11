import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import 'buffer_list.dart';

class ConnectPage extends StatefulWidget {
	static const routeName = '/connect';

	const ConnectPage({ Key? key }) : super(key: key);

	@override
	ConnectPageState createState() => ConnectPageState();
}

Uri _parseServerUri(String rawUri) {
	if (!rawUri.contains('://')) {
		rawUri = 'ircs://' + rawUri;
	}

	var uri = Uri.parse(rawUri);
	if (uri.host == '') {
		throw FormatException('Host is required in URI');
	}
	switch (uri.scheme) {
	case 'ircs':
	case 'irc+insecure':
		break; // supported
	default:
		throw FormatException('Unsupported URI scheme: ' + uri.scheme);
	}

	return uri;
}

class ConnectPageState extends State<ConnectPage> {
	bool _loading = false;
	Exception? _error;
	bool _passwordRequired = false;

	final formKey = GlobalKey<FormState>();
	final serverController = TextEditingController();
	final nicknameController = TextEditingController();
	final passwordController = TextEditingController();

	void submit() async {
		if (!formKey.currentState!.validate() || _loading) {
			return;
		}

		Uri uri = _parseServerUri(serverController.text);
		var serverEntry = ServerEntry(
			host: uri.host,
			port: uri.hasPort ? uri.port : null,
			tls: uri.scheme != 'irc+insecure',
			saslPlainPassword: passwordController.text.isNotEmpty ? passwordController.text : null,
		);

		setState(() {
			_loading = true;
		});

		var db = context.read<DB>();
		var sharedPreferences = context.read<SharedPreferences>();

		// TODO: only connect once (but be careful not to loose messages
		// sent immediately after RPL_WELCOME)
		var clientParams = connectParamsFromServerEntry(
			serverEntry,
			defaultNickname: nicknameController.text,
		);
		var client = Client(clientParams, autoReconnect: false);
		NetworkEntry networkEntry;
		try {
			await client.connect();
			client.disconnect();

			await db.storeServer(serverEntry);
			networkEntry = await db.storeNetwork(NetworkEntry(server: serverEntry.id!));
		} on Exception catch (err) {
			client.disconnect();
			setState(() {
				_error = err;
				if (err is IrcException) {
					if (err.msg.cmd == 'FAIL' && err.msg.params[1] == 'ACCOUNT_REQUIRED') {
						_passwordRequired = true;
					}
				}
			});
			return;
		} finally {
			setState(() {
				_loading = false;
			});
		}

		await sharedPreferences.setString('nickname', nicknameController.text);

		client = Client(clientParams);
		var network = NetworkModel(serverEntry, networkEntry, client.nick, client.realname);
		context.read<NetworkListModel>().add(network);
		context.read<ClientProvider>().add(client, network);
		client.connect().ignore();

		Navigator.pushReplacementNamed(context, BufferListPage.routeName);
	}

	@override
	void dispose() {
		serverController.dispose();
		nicknameController.dispose();
		passwordController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		String? serverErr, nicknameErr, passwordErr;
		if (_error is IrcException) {
			final ircErr = _error as IrcException;
			switch (ircErr.msg.cmd) {
			case 'FAIL':
				var code = ircErr.msg.params[1];
				if (code == 'ACCOUNT_REQUIRED') {
					passwordErr = ircErr.toString();
				} else {
					serverErr = ircErr.toString();
				}
				break;
			case ERR_PASSWDMISMATCH:
			case ERR_SASLFAIL:
			case ERR_SASLTOOLONG:
			case ERR_SASLABORTED:
				passwordErr = ircErr.toString();
				break;
			case ERR_NICKLOCKED:
			case ERR_ERRONEUSNICKNAME:
			case ERR_NICKNAMEINUSE:
			case ERR_NICKCOLLISION:
			case ERR_YOUREBANNEDCREEP:
				nicknameErr = ircErr.toString();
				break;
			default:
				serverErr = ircErr.toString();
				break;
			}
		} else {
			serverErr = _error?.toString();
		}

		final focusNode = FocusScope.of(context);
		return Scaffold(
			appBar: AppBar(
				title: Text('Goguma'),
			),
			body: Form(
				key: formKey,
				child: Container(padding: EdgeInsets.all(10), child: Column(children: [
					TextFormField(
						keyboardType: TextInputType.url,
						decoration: InputDecoration(
							labelText: 'Server',
							errorText: serverErr,
						),
						controller: serverController,
						autofocus: true,
						onEditingComplete: () => focusNode.nextFocus(),
						validator: (value) {
							if (value!.isEmpty) {
								return 'Required';
							}
							try {
								_parseServerUri(value);
							} on FormatException catch(e) {
								return e.message;
							}
							return null;
						},
					),
					TextFormField(
						decoration: InputDecoration(
							labelText: 'Nickname',
							errorText: nicknameErr,
						),
						controller: nicknameController,
						onEditingComplete: () => focusNode.nextFocus(),
						validator: (value) {
							return (value!.isEmpty) ? 'Required' : null;
						},
					),
					TextFormField(
						obscureText: true,
						decoration: InputDecoration(
							labelText: _passwordRequired ? 'Password' : 'Password (optional)',
							errorText: passwordErr,
						),
						controller: passwordController,
						onFieldSubmitted: (_) {
							focusNode.unfocus();
							submit();
						},
						validator: (value) {
							return (_passwordRequired && value!.isEmpty) ? 'Required' : null;
						},
					),
					SizedBox(height: 20),
					_loading
						? CircularProgressIndicator()
						: FloatingActionButton.extended(
							onPressed: submit,
							label: Text('Connect'),
						),
				])),
			),
		);
	}
}
