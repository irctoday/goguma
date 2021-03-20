import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-list-page.dart';
import 'client.dart';
import 'connect-page.dart';
import 'irc.dart';
import 'models.dart';

void main() {
	runApp(MultiProvider(
		providers: [
			ChangeNotifierProvider(create: (context) => BufferListModel()),
		],
		child: GogumaApp(),
	));
}

class GogumaApp extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return MaterialApp(
			title: 'Goguma',
			theme: ThemeData(primarySwatch: Colors.indigo),
			home: Goguma(),
			debugShowCheckedModeBanner: false,
		);
	}
}

class Goguma extends StatefulWidget {
	@override
	GogumaState createState() => GogumaState();
}

class GogumaState extends State<Goguma> {
	ConnectParams? connectParams;
	Client? client;

	connect(ConnectParams params) {
		connectParams = params;
		client = Client(params: params);

		client!.messages.listen((msg) {
			var bufferList = context.read<BufferListModel>();
			switch (msg.cmd) {
			case 'JOIN':
				if (msg.prefix?.name != client!.nick) {
					break;
				}
				bufferList.add(BufferModel(name: msg.params[0]));
				break;
			case RPL_TOPIC:
				var channel = msg.params[1];
				var topic = msg.params[2];
				bufferList.getByName(channel)?.subtitle = topic;
				break;
			case RPL_NOTOPIC:
				var channel = msg.params[1];
				bufferList.getByName(channel)?.subtitle = null;
				break;
			case 'TOPIC':
				var channel = msg.params[0];
				String? topic = null;
				if (msg.params.length > 1) {
					topic = msg.params[1];
				}
				bufferList.getByName(channel)?.subtitle = topic;
				break;
			case 'PRIVMSG':
				var target = msg.params[0];
				bufferList.getByName(target)?.messages.add(msg);
				break;
			}
		});
	}

	@override
	void dispose() {
		client?.disconnect();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		if (connectParams == null) {
			return ConnectPage(onSubmit: (params) {
				connect(params);

				Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
					return BufferListPage();
				}));
			});
		} else {
			return Provider<Client>.value(value: client!, child: BufferListPage());
		}
	}
}
