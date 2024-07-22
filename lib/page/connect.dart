import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hex/hex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc/irc.dart';
import '../logging.dart';
import '../models.dart';
import '../prefs.dart';
import 'buffer_list.dart';

class _ServerFeatures {
	bool passwordRequired;
	bool passwordUnsupported;
	String? networkName;
	int? nickLen;

	_ServerFeatures({
		this.passwordRequired = false,
		this.passwordUnsupported = false,
		this.networkName,
		this.nickLen,
	});
}

class ConnectPage extends StatefulWidget {
	static const routeName = '/connect';

	final IrcUri? initialUri;

	const ConnectPage({ super.key, this.initialUri });

	@override
	State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
	static const ircTodayUrl = 'https://irctoday.com';
	static const ircTodayServer = 'irctoday.com';

	bool _tutorial = false;
	bool _ircToday = false;
	bool _loading = false;
	Exception? _error;
	_ServerFeatures _serverFeatures = _ServerFeatures();
	Client? _client;
	String? _pinnedCertSHA1;
	bool _obscurePassword = true;

	final formKey = GlobalKey<FormState>();
	final serverController = TextEditingController();
	final nicknameController = TextEditingController();
	final passwordController = TextEditingController();

	@override
	void initState() {
		super.initState();

		if (widget.initialUri != null) {
			_populateFromUri(widget.initialUri!);
			_ircToday = widget.initialUri?.host == ircTodayServer;
			if (_ircToday) {
				_serverFeatures.passwordUnsupported = false;
				_serverFeatures.passwordRequired = true;
			}
		}
	}

	void _populateFromUri(IrcUri uri) {
		var server = '';
		if (uri.host != null) {
			server = uri.host!;
		}
		if (uri.port != null) {
			server += ':${uri.port}';
		}
		serverController.text = server;

		if (uri.auth != null) {
			nicknameController.text = uri.auth!.username;
			if (uri.auth!.password != null) {
				passwordController.text = uri.auth!.password!;
			}
		}
	}

	ServerEntry _generateServerEntry() {
		Uri uri = parseServerUri(serverController.text);
		var useSaslPlain = !passwordController.text.isEmpty;
		return ServerEntry(
			host: uri.host,
			port: uri.hasPort ? uri.port : null,
			tls: uri.scheme != 'irc+insecure',
			saslPlainUsername: useSaslPlain ? nicknameController.text : null,
			saslPlainPassword: useSaslPlain ? passwordController.text : null,
			pinnedCertSHA1: _pinnedCertSHA1,
		);
	}

	Future<Client> _connect() async {
		var prefs = context.read<Prefs>();

		var client = _client;
		if (client != null && client.state == ClientState.connected) {
			try {
				// Make sure the connection is still alive and usable
				// Note, some servers reject PING before registration
				await client.fetchAvailableCaps();
				return client;
			} on Exception {
				log.print('Failed to reuse client, creating a new one');
			}
		}

		_disconnect();

		var serverEntry = _generateServerEntry();
		var clientParams = connectParamsFromServerEntry(serverEntry, prefs);
		client = Client(clientParams, autoReconnect: false, requestCaps: {});
		_client = client;
		try {
			await client.connect(register: false);
			return client;
		} on Exception {
			client.dispose();
			if (_client == client) {
				_client = null;
			}
			rethrow;
		}
	}

	void _disconnect() {
		_client?.disconnect();
		_client = null;
	}

	void _submit() async {
		if (!formKey.currentState!.validate() || _loading) {
			return;
		}

		var db = context.read<DB>();
		var prefs = context.read<Prefs>();
		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();

		prefs.nickname = nicknameController.text;

		var serverEntry = _generateServerEntry();
		var clientParams = connectParamsFromServerEntry(serverEntry, prefs);

		setState(() {
			_loading = true;
			_obscurePassword = true;
		});

		// TODO: only connect once (but be careful not to loose messages
		// sent immediately after RPL_WELCOME, and request all caps)
		Client client;
		try {
			client = await _connect();
			if (clientParams.saslPlain != null) {
				client.send(IrcMessage('CAP', ['REQ', 'sasl']));
			}
			await client.register(clientParams);
		} on Exception catch (err) {
			setState(() {
				_loading = false;
				_error = err;
				if (err is IrcException) {
					if (err.msg.cmd == 'FAIL' && err.msg.params[1] == 'ACCOUNT_REQUIRED') {
						_serverFeatures.passwordRequired = true;
					}
				}
			});
			return;
		} finally {
			_disconnect();
		}

		await db.storeServer(serverEntry);
		var networkEntry = await db.storeNetwork(NetworkEntry(server: serverEntry.id!));

		client = Client(clientParams, lastIsupport: client.isupport, lastAvailableCaps: client.caps.available);
		var network = NetworkModel(serverEntry, networkEntry, client.nick, client.realname);
		networkList.add(network);
		clientProvider.add(client, network);
		client.connect().ignore();

		if (mounted) {
			unawaited(Navigator.pushReplacementNamed(context, BufferListPage.routeName));
		}
	}

	void _handleServerFocusChange(bool hasFocus) async {
		if (hasFocus || serverController.text.isEmpty) {
			return;
		}

		var serverText = serverController.text;

		_ServerFeatures features;
		try {
			features = await _fetchServerFeatures();
		} on Exception catch (err) {
			if (serverText != serverController.text || !mounted) {
				return;
			}
			log.print('Failed to fetch server caps', error: err);
			setState(() {
				_error = err;
			});

			if (err is BadCertException) {
				askBadCertficate(context, err.badCert);
			}

			return;
		}

		if (serverText != serverController.text || !mounted) {
			return;
		}

		setState(() {
			_error = null;
			_serverFeatures = features;
		});

		if (features.passwordUnsupported) {
			passwordController.text = '';
		}
	}

	Future<_ServerFeatures> _fetchServerFeatures() async {
		IrcAvailableCapRegistry availableCaps;
		IrcIsupportRegistry isupport;
		try {
			var client = await _connect();

			try {
				availableCaps = await client.fetchAvailableCaps();
			} on IrcException catch (err) {
				if (err.msg.cmd == ERR_UNKNOWNCOMMAND) {
					availableCaps = IrcAvailableCapRegistry();
				} else {
					rethrow;
				}
			}

			if (availableCaps.containsKey('draft/extended-isupport') && availableCaps.containsKey('batch')) {
				client.send(IrcMessage('CAP', ['REQ', 'batch draft/extended-isupport']));
				isupport = await client.fetchIsupport();
			} else {
				isupport = IrcIsupportRegistry();
			}
		} on IrcException {
			_disconnect();
			rethrow;
		}
		return _ServerFeatures(
			passwordUnsupported: !availableCaps.containsSasl('PLAIN'),
			passwordRequired: availableCaps.accountRequired || isupport.accountRequired,
			networkName: isupport.network,
			nickLen: isupport.nickLen,
		);
	}

	@override
	void dispose() {
		_client?.dispose();
		serverController.dispose();
		nicknameController.dispose();
		passwordController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		if (_tutorial) {
			return Scaffold(
				appBar: AppBar(
					title: Text('Goguma'),
				),
				body: Container(padding: EdgeInsets.all(10), child: SafeArea(child: Column(children: [
					Expanded(child: ListView(children: [
						ListTile(
							leading: Icon(Icons.check),
							title: Text('In order to have an optimal IRC experience (message history, notifications when highlighted, multiple networks, sharing files over chat), you will need an IRC bouncer that will stay connected to IRC for you.', textScaler: TextScaler.linear(0.9)),
						),
						ListTile(
							leading: Icon(Icons.check),
							title: Text('You can use Goguma without an IRC bouncer and connect directly to a single IRC network, but you will miss these key features.', textScaler: TextScaler.linear(0.9)),
						),
						ListTile(
								leading: Icon(Icons.check),
								title: Text.rich(TextSpan(children: [
									TextSpan(text: 'If you do not have a bouncer account yet, we recommend using the bouncer service '),
									TextSpan(
										text: 'IRC Today',
										style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
										recognizer: TapGestureRecognizer()
											..onTap = () async {
												await launchUrl(Uri.parse(ircTodayUrl));
											}
									),
									TextSpan(text: '.'),
								]), textScaler: TextScaler.linear(0.9))),
						ListTile(
							leading: Icon(Icons.check),
							title: Text('You can change accounts at any time by signing out in the app options.', textScaler: TextScaler.linear(0.9)),
						),
					])),
					Container(padding: EdgeInsets.symmetric(vertical: 15), child: OutlinedButton(
						onPressed: () {
							launchUrl(Uri.parse(ircTodayUrl));
						},
						child: Row(mainAxisSize: MainAxisSize.min, children: [
							Text('Open the IRC Today website'),
							Container(padding: EdgeInsets.only(left: 10), child: Icon(Icons.launch)),
						]),
					)),
					Container(padding: EdgeInsets.symmetric(vertical: 10), child: OutlinedButton.icon(
						onPressed: () {
							setState(() {
								_tutorial = false;
								_ircToday = false;
							});
						},
						icon: Icon(Icons.arrow_back),
						label: Text('Back to Connect'),
					)),
				]))),
			);
		}

		var err = _error;
		String? serverErr, nicknameErr, passwordErr;
		if (err is IrcException) {
			switch (err.msg.cmd) {
			case 'FAIL':
				var code = err.msg.params[1];
				if (code == 'ACCOUNT_REQUIRED') {
					passwordErr = err.toString();
				} else {
					serverErr = err.toString();
				}
				break;
			case ERR_PASSWDMISMATCH:
				serverErr = 'Server password required but not supported ($err)';
				break;
			case ERR_SASLFAIL:
			case ERR_SASLTOOLONG:
			case ERR_SASLABORTED:
				passwordErr = err.toString();
				break;
			case ERR_NICKLOCKED:
			case ERR_ERRONEUSNICKNAME:
			case ERR_NICKNAMEINUSE:
			case ERR_NICKCOLLISION:
			case ERR_YOUREBANNEDCREEP:
				nicknameErr = err.toString();
				break;
			default:
				serverErr = err.toString();
				break;
			}
		} else if (err is BadCertException) {
			serverErr = 'Bad server certificate';
		} else if (err is SocketException) {
			serverErr = 'Network error: ${err.message}';
		} else {
			serverErr = _error?.toString();
		}

		var focusNode = FocusScope.of(context);
		return Scaffold(
			appBar: AppBar(
				title: Text('Goguma'),
			),
			body: Form(
				key: formKey,
				child: Container(padding: EdgeInsets.all(10), child: SafeArea(child: AutofillGroup(child: Column(children: [
					Focus(onFocusChange: _handleServerFocusChange, child: TextFormField(
						keyboardType: TextInputType.url,
						autocorrect: false,
						decoration: InputDecoration(
							labelText: 'Server',
							errorText: serverErr,
							errorMaxLines: 10,
						),
						controller: serverController,
						autofocus: !_ircToday,
						readOnly: _ircToday,
						onEditingComplete: () => focusNode.nextFocus(),
						onChanged: (value) {
							_disconnect();
							setState(() {
								_serverFeatures = _ServerFeatures();
								_pinnedCertSHA1 = null;
							});
						},
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
						autofillHints: [AutofillHints.url],
					)),
					TextFormField(
						decoration: InputDecoration(
							labelText: _ircToday ? 'IRC Today Username' : 'Nickname',
							errorText: nicknameErr,
						),
						autocorrect: false,
						controller: nicknameController,
						onEditingComplete: () => focusNode.nextFocus(),
						validator: (value) {
							return (value!.isEmpty) ? 'Required' : null;
						},
						maxLength: _serverFeatures.nickLen,
						autofillHints: [AutofillHints.username],
					),
					if (!_serverFeatures.passwordUnsupported) TextFormField(
						obscureText: _obscurePassword,
						decoration: InputDecoration(
							labelText: _ircToday ? 'IRC Today Password' : (_serverFeatures.passwordRequired ? 'Password' : 'Password (optional)'),
							errorText: passwordErr,
							suffixIcon: IconButton(
								tooltip: _obscurePassword ? 'Show password' : 'Hide password',
								onPressed: () {
									setState(() {
										_obscurePassword = !_obscurePassword;
									});
								},
								icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
							),
						),
						controller: passwordController,
						onFieldSubmitted: (_) {
							focusNode.unfocus();
							_submit();
						},
						validator: (value) {
							return (_serverFeatures.passwordRequired && value!.isEmpty) ? 'Required' : null;
						},
						autofillHints: [AutofillHints.password],
					),
					SizedBox(height: 20),
					_loading
						? CircularProgressIndicator()
						: FloatingActionButton.extended(
							onPressed: _submit,
							label: Text(_ircToday ? 'Connect to IRC Today' : (_serverFeatures.networkName != null ? 'Connect to ${_serverFeatures.networkName}' : 'Connect')),
						),
					Spacer(),
					if (!_ircToday) Container(padding: EdgeInsets.symmetric(vertical: 10), child: OutlinedButton.icon(
						onPressed: () {
							launchUrl(Uri.parse('$ircTodayUrl/log-in-goguma'));
						},
						icon: Icon(Icons.account_circle_outlined),
						label: Text('Log in with IRC Today'),
					)),
					if (!_ircToday) Container(padding: EdgeInsets.symmetric(vertical: 10), child: OutlinedButton.icon(
						onPressed: () {
							setState(() {
								serverController.text = '';
								_tutorial = true;
							});
						},
						icon: Icon(Icons.info_outline),
						label: Text('No account?'),
					)),
				]))),
			),
		));
	}

	void askBadCertficate(BuildContext context, X509Certificate cert) {
		showDialog<void>(
			context: context,
			builder: (BuildContext context) {
				Widget noButton = TextButton(
					child: const Text('Reject'),
					onPressed: () { Navigator.pop(context); },
				);
				Widget yesButton = TextButton(
					child: const Text('Accept Always'),
					onPressed: () {
						Navigator.pop(context);
						setState(() => _pinnedCertSHA1 = HEX.encode(cert.sha1));
						_handleServerFocusChange(false);
					},
				);
				return AlertDialog(
					title: const Text('Bad Certificate'),
					content: SingleChildScrollView(
						child: Text(
							'Untrusted server certificate. '
							'Only accept this certificate if you know what you\'re doing.\n\n'
							'Issuer: ${cert.issuer}\n'
							'SHA1 Fingerprint: ${HEX.encode(cert.sha1)}\n'
							'From: ${cert.startValidity}\n'
							'To: ${cert.endValidity}'
						)
					),
					actions: [ noButton, yesButton ],
				);
			},
		);
	}
}
