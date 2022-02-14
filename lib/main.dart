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
				Provider<ClientController>.value(value: ClientController(serverList, bufferList)),
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

		var clientController = context.read<ClientController>();
		context.read<DB>().listServers().then((servers) {
			if (servers.length == 0) {
				return;
			}

			servers.forEach((entry) {
				var server = clientController.addServer(entry);
				clientController.get(server).connect();
			});

			Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
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

			var clientController = context.read<ClientController>();
			var server = clientController.addServer(entry);
			clientController.get(server).connect().then((_) {
				return context.read<DB>().storeServer(entry);
			}).then((_) {
				Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
					return BufferListPage();
				}));
			}).catchError((err) {
				clientController.disconnectAll();
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
