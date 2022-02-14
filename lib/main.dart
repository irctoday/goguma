import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-list-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'connect-page.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

void main() {
	DB.open().then((db) {
		var serverList = ServerListModel();
		var bufferList = BufferListModel();
		runApp(MultiProvider(
			providers: [
				Provider<DB>.value(value: db),
				Provider<ClientController>.value(value: ClientController(bufferList)),
				ChangeNotifierProvider<ServerListModel>.value(value: serverList),
				ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
			],
			child: GogumaApp(),
		));
	});
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
	bool initing = true;
	bool loading = false;
	Exception? error = null;

	@override
	void initState() {
		super.initState();

		context.read<DB>().listServers().then((entries) {
			if (entries.length == 0) {
				return null;
			}

			var serverList = context.read<ServerListModel>();
			var clientController = context.read<ClientController>();
			entries.forEach((entry) {
				var server = ServerModel(entry);
				serverList.add(server);

				var client = Client(params: connectParamsFromServerEntry(entry));
				clientController.add(client, server);

				client.connect();
			});

			return Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
				return BufferListPage();
			}));
		}).whenComplete(() {
			setState(() {
				initing = false;
			});
		});
	}

	@override
	Widget build(BuildContext context) {
		if (initing) {
			return Container();
		}

		return ConnectPage(loading: loading, error: error, onSubmit: (entry) {
			setState(() {
				loading = true;
			});

			var client = Client(params: connectParamsFromServerEntry(entry));
			client.connect().then((_) {
				return context.read<DB>().storeServer(entry);
			}).then((_) {
				var server = ServerModel(entry);
				context.read<ServerListModel>().add(server);
				context.read<ClientController>().add(client, server);

				return Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
					return BufferListPage();
				}));
			}).catchError((err) {
				client.disconnect();
				setState(() {
					error = err;
				});
			}).whenComplete(() {
				setState(() {
					loading = false;
				});
			});
		});
	}
}
