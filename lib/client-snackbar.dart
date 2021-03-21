import 'dart:async';
import 'package:flutter/material.dart';

import 'client.dart';
import 'irc.dart';

class ClientSnackbar extends StatefulWidget {
	final Widget child;
	final Client client;

	ClientSnackbar({ Key? key, required this.child, required this.client }) : super(key: key);

	@override
	ClientSnackbarState createState() => ClientSnackbarState();
}

class ClientSnackbarState extends State<ClientSnackbar> {
	StreamSubscription? subscription;

	@override
	void initState() {
		super.initState();
		subscription = widget.client.messages.listen((msg) {
			if (msg.isError()) {
				var snackbar = SnackBar(content: Text(msg.params[msg.params.length - 1]));
				ScaffoldMessenger.of(context).showSnackBar(snackbar);
			}
		});
	}

	@override
	void dispose() {
		subscription?.cancel();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return widget.child;
	}
}
