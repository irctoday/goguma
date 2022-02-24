import 'dart:async';
import 'package:flutter/material.dart';

import 'client.dart';
import 'irc.dart';
import 'models.dart';

class ClientSnackbar extends StatefulWidget {
	final Widget child;
	final Client client;
	final NetworkModel network;

	ClientSnackbar({ Key? key, required this.child, required this.client, required this.network }) : super(key: key);

	@override
	ClientSnackbarState createState() => ClientSnackbarState();
}

class ClientSnackbarState extends State<ClientSnackbar> {
	StreamSubscription? messagesSubscription;
	NetworkState? _prevNetworkState;

	@override
	void initState() {
		super.initState();

		widget.network.addListener(_handleNetworkChange);

		messagesSubscription = widget.client.messages.listen((msg) {
			if (msg.isError()) {
				var snackbar = SnackBar(content: Text(msg.params[msg.params.length - 1]));
				ScaffoldMessenger.of(context).showSnackBar(snackbar);
			}
		});
	}

	@override
	void dispose() {
		widget.network.removeListener(_handleNetworkChange);
		messagesSubscription?.cancel();
		super.dispose();
	}

	void _handleNetworkChange() {
		if (_prevNetworkState == widget.network.state) {
			return;
		}
		_prevNetworkState = widget.network.state;

		String text;
		bool persistent = true;
		switch (widget.network.state) {
		case NetworkState.offline:
			text = 'Disconnected from server';
			break;
		case NetworkState.connecting:
			text = 'Connecting to server…';
			break;
		case NetworkState.registering:
			text = 'Logging in…';
			break;
		case NetworkState.synchronizing:
			text = 'Synchronizing…';
			break;
		case NetworkState.online:
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
	}

	@override
	Widget build(BuildContext context) {
		return widget.child;
	}
}
