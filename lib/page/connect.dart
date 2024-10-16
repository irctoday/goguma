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
import '../irc.dart';
import '../logging.dart';
import '../models.dart';
import '../prefs.dart';
import 'buffer_list.dart';

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
	bool _passwordRequired = false;
	bool _passwordUnsupported = false;
	Client? _fetchCapsClient;
	String? _pinnedCertSHA1;

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
				_passwordRequired = true;
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

	void _submit() async {
		if (!formKey.currentState!.validate() || _loading) {
			return;
		}

		_fetchCapsClient?.disconnect().ignore();
		_fetchCapsClient = null;

		var serverEntry = _generateServerEntry();

		setState(() {
			_loading = true;
		});

		var db = context.read<DB>();
		var prefs = context.read<Prefs>();
		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();

		prefs.nickname = nicknameController.text;

		// TODO: only connect once (but be careful not to loose messages
		// sent immediately after RPL_WELCOME)
		var clientParams = connectParamsFromServerEntry(serverEntry, prefs);
		var client = Client(clientParams, autoReconnect: false, requestCaps: {'sasl'});
		NetworkEntry networkEntry;
		try {
			await client.connect();
			client.dispose();
			await db.storeServer(serverEntry);
			networkEntry = await db.storeNetwork(NetworkEntry(server: serverEntry.id!));
		} on Exception catch (err) {
			client.dispose();
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

		client = Client(clientParams);
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

		IrcAvailableCapRegistry availableCaps;
		try {
			availableCaps = await _fetchAvailableCaps();
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
			_passwordUnsupported = !availableCaps.containsSasl('PLAIN');
			_passwordRequired = availableCaps.accountRequired;
		});

		if (!_passwordUnsupported) {
			passwordController.text = '';
		}
	}

	Future<IrcAvailableCapRegistry> _fetchAvailableCaps() async {
		_fetchCapsClient?.disconnect().ignore();
		_fetchCapsClient = null;

		var serverEntry = _generateServerEntry();
		var prefs = context.read<Prefs>();
		var clientParams = connectParamsFromServerEntry(serverEntry, prefs);
		var client = Client(clientParams, autoReconnect: false, requestCaps: {});
		_fetchCapsClient = client;
		IrcAvailableCapRegistry availableCaps;
		try {
			await client.connect(register: false);
			availableCaps = await client.fetchAvailableCaps();
		} on IrcException catch (err) {
			if (err.msg.cmd == ERR_UNKNOWNCOMMAND) {
				availableCaps = IrcAvailableCapRegistry();
			} else {
				rethrow;
			}
		} finally {
			client.dispose();
			if (_fetchCapsClient == client) {
				_fetchCapsClient = null;
			}
		}
		return availableCaps;
	}

	@override
	void dispose() {
		_fetchCapsClient?.disconnect();
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
				body: Container(padding: EdgeInsets.all(10), child: Column(children: [
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
				])),
			);
		}

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
		} else if (_error is BadCertException) {
			serverErr = 'Bad server certificate';
		} else {
			serverErr = _error?.toString();
		}

		final focusNode = FocusScope.of(context);

		var children = [
			Focus(onFocusChange: _handleServerFocusChange, child: TextFormField(
				keyboardType: TextInputType.url,
				autocorrect: false,
				decoration: InputDecoration(
					labelText: 'Server',
					errorText: serverErr,
				),
				controller: serverController,
				autofocus: !_ircToday,
				readOnly: _ircToday,
				onEditingComplete: () => focusNode.nextFocus(),
				onChanged: (value) {
					setState(() {
						_passwordUnsupported = false;
						_passwordRequired = false;
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
			),
			if (!_passwordUnsupported) TextFormField(
				obscureText: true,
				decoration: InputDecoration(
					labelText: _ircToday ? 'IRC Today Password' : (_passwordRequired ? 'Password' : 'Password (optional)'),
					errorText: passwordErr,
				),
				controller: passwordController,
				onFieldSubmitted: (_) {
					focusNode.unfocus();
					_submit();
				},
				validator: (value) {
					return (_passwordRequired && value!.isEmpty) ? 'Required' : null;
				},
			),
			SizedBox(height: 20),
			_loading
					? CircularProgressIndicator()
					: FloatingActionButton.extended(
				onPressed: _submit,
				label: Text(_ircToday ? 'Connect to IRC Today' : 'Connect'),
			),
			Spacer(),
		];

		if (!_ircToday) {
			children.add(Container(padding: EdgeInsets.symmetric(vertical: 10), child: OutlinedButton.icon(
				onPressed: () {
					launchUrl(Uri.parse('$ircTodayUrl/log-in-goguma'));
				},
				icon: Icon(Icons.account_circle_outlined),
				label: Text('Log in with IRC Today'),
			)));
		}
		children.add(Container(padding: EdgeInsets.symmetric(vertical: 10), child: OutlinedButton.icon(
			onPressed: () {
				setState(() {
					serverController.text = '';
					_tutorial = true;
				});
			},
			icon: Icon(Icons.info_outline),
			label: Text('No account?'),
		)));

		return Scaffold(
			appBar: AppBar(
				title: Text('Goguma'),
			),
			body: Form(
				key: formKey,
				child: Container(padding: EdgeInsets.all(10), child: Column(children: children)),
			),
		);
	}

	void askBadCertficate(BuildContext context, X509Certificate cert) {
		showDialog<void>(
			context: context,
			builder: (BuildContext context) {
				Widget noButton = TextButton(
					child: const Text('Reject'),
					onPressed:  () { Navigator.pop(context); },
				);
				Widget yesButton = TextButton(
					child: const Text('Accept Always'),
					onPressed:  () {
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
