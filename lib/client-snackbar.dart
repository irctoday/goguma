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
	StreamSubscription? messagesSubscription;
	StreamSubscription? statesSubscription;

	@override
	void initState() {
		super.initState();

		statesSubscription = widget.client.states.listen((state) {
			String text;
			bool persistent = true;
			switch (state) {
			case ClientState.disconnected:
				text = 'Disconnected from server';
				break;
			case ClientState.connecting:
				text = 'Connecting to server…';
				break;
			case ClientState.registering:
				text = 'Logging in…';
				break;
			case ClientState.registered:
				text = 'Connected to server';
				persistent = false;
				break;
			}
			var snackbar;
			if (persistent) {
				snackbar = SnackBar(
					content: Text(text),
					dismissDirection: DismissDirection.none,
					// Apparently there is no way to disable this...
					duration: Duration(days: 365),
				);
			} else {
				snackbar = SnackBar(content: Text(text));
			}
			ScaffoldMessenger.of(context).clearSnackBars();
			ScaffoldMessenger.of(context).showSnackBar(snackbar);
		});

		messagesSubscription = widget.client.messages.listen((msg) {
			if (msg.isError()) {
				var snackbar = SnackBar(content: Text(msg.params[msg.params.length - 1]));
				ScaffoldMessenger.of(context).showSnackBar(snackbar);
			}
		});
	}

	@override
	void dispose() {
		messagesSubscription?.cancel();
		statesSubscription?.cancel();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return widget.child;
	}
}
