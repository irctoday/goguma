import 'package:flutter/material.dart';

import 'client.dart';

typedef ConnectParamsCallback(ConnectParams);

class ConnectPage extends StatefulWidget {
	final ConnectParamsCallback? onSubmit;

	ConnectPage({ Key? key, this.onSubmit }) : super(key: key);

	@override
	ConnectPageState createState() => ConnectPageState();
}

class ConnectPageState extends State<ConnectPage> {
	final formKey = GlobalKey<FormState>();
	final serverController = TextEditingController();
	final usernameController = TextEditingController();
	final passwordController = TextEditingController();

	void submit() {
		if (!formKey.currentState!.validate()) {
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
						decoration: InputDecoration(labelText: 'Server'),
						controller: serverController,
						autofocus: true,
						onEditingComplete: () => focusNode.nextFocus(),
						validator: (value) {
							return (value!.isEmpty) ? 'Required' : null;
						},
					),
					TextFormField(
						decoration: InputDecoration(labelText: 'Username'),
						controller: usernameController,
						onEditingComplete: () => focusNode.nextFocus(),
						validator: (value) {
							return (value!.isEmpty) ? 'Required' : null;
						},
					),
					TextFormField(
						obscureText: true,
						decoration: InputDecoration(labelText: 'Password'),
						controller: passwordController,
						onFieldSubmitted: (_) {
							focusNode.unfocus();
							submit();
						},
					),
					SizedBox(height: 20),
					FloatingActionButton.extended(
						onPressed: submit,
						label: Text('Connect'),
					),
				])),
			),
		);
	}
}
