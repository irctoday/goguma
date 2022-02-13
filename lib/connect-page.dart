import 'package:flutter/material.dart';

import 'client.dart';
import 'irc.dart';

typedef ConnectParamsCallback(ConnectParams);

class ConnectPage extends StatefulWidget {
	final ConnectParamsCallback? onSubmit;
	final bool loading;
	final Exception? error;

	ConnectPage({ Key? key, this.onSubmit, this.loading = false, this.error = null }) : super(key: key);

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

	if (!uri.hasPort) {
		uri = uri.replace(port: uri.scheme == 'irc+insecure' ? 6667 : 6697);
	}

	return uri;
}

class ConnectPageState extends State<ConnectPage> {
	final formKey = GlobalKey<FormState>();
	final serverController = TextEditingController();
	final usernameController = TextEditingController();
	final passwordController = TextEditingController();

	void submit() {
		if (!formKey.currentState!.validate() || widget.loading) {
			return;
		}

		Uri uri = _parseServerUri(serverController.text);
		widget.onSubmit?.call(ConnectParams(
			host: uri.host,
			port: uri.port,
			nick: usernameController.text,
			pass: passwordController.text.isNotEmpty ? passwordController.text : null,
			tls: uri.scheme != 'irc+insecure',
		));
	}

	@override
	void dispose() {
		serverController.dispose();
		usernameController.dispose();
		passwordController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		String? serverErr = null, usernameErr = null, passwordErr = null;
		if (widget.error is IRCException) {
			final ircErr = widget.error as IRCException;
			switch (ircErr.msg.cmd) {
			case ERR_PASSWDMISMATCH:
				passwordErr = ircErr.toString();
				break;
			case ERR_NICKLOCKED:
			case ERR_ERRONEUSNICKNAME:
			case ERR_NICKNAMEINUSE:
			case ERR_NICKCOLLISION:
			case ERR_YOUREBANNEDCREEP:
				usernameErr = ircErr.toString();
				break;
			default:
				serverErr = ircErr.toString();
				break;
			}
		} else {
			serverErr = widget.error?.toString();
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
							labelText: 'Username',
							errorText: usernameErr,
						),
						controller: usernameController,
						onEditingComplete: () => focusNode.nextFocus(),
						validator: (value) {
							return (value!.isEmpty) ? 'Required' : null;
						},
					),
					TextFormField(
						obscureText: true,
						decoration: InputDecoration(
							labelText: 'Password',
							errorText: passwordErr,
						),
						controller: passwordController,
						onFieldSubmitted: (_) {
							focusNode.unfocus();
							submit();
						},
					),
					SizedBox(height: 20),
					widget.loading
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
