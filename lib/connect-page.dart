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

class ConnectPageState extends State<ConnectPage> {
	final formKey = GlobalKey<FormState>();
	final serverController = TextEditingController();
	final usernameController = TextEditingController();
	final passwordController = TextEditingController();

	void submit() {
		if (!formKey.currentState!.validate() || widget.loading) {
			return;
		}

		var uri = Uri.parse('irc://' + serverController.text);

		widget.onSubmit?.call(ConnectParams(
			host: uri.host,
			port: uri.hasPort ? uri.port : 6697,
			nick: usernameController.text,
			pass: passwordController.text,
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
							return (value!.isEmpty) ? 'Required' : null;
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
