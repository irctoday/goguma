import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-list-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'connect-page.dart';
import 'database.dart';
import 'models.dart';

void main() {
	DB.open().then((db) {
		var serverList = ServerListModel();
		var bufferList = BufferListModel();
		var bouncerNetworkList = BouncerNetworkListModel();
		runApp(MultiProvider(
			providers: [
				Provider<DB>.value(value: db),
				Provider<ClientController>.value(value: ClientController(db, serverList, bufferList, bouncerNetworkList)),
				ChangeNotifierProvider<ServerListModel>.value(value: serverList),
				ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
				ChangeNotifierProvider<BouncerNetworkListModel>.value(value: bouncerNetworkList),
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

		var db = context.read<DB>();
		var serverList = context.read<ServerListModel>();
		var bufferList = context.read<BufferListModel>();
		var clientController = context.read<ClientController>();

		List<ServerEntry> serverEntries = [];
		List<NetworkEntry> networkEntries = [];
		List<BufferEntry> bufferEntries = [];
		Map<int, int> unreadCounts = Map();
		Map<int, String> lastDeliveredTimes = Map();
		Future.wait([
			db.listServers().then((entries) => serverEntries = entries),
			db.listNetworks().then((entries) => networkEntries = entries),
			db.listBuffers().then((entries) => bufferEntries = entries),
			db.fetchBuffersUnreadCount().then((m) => unreadCounts = m),
			db.fetchBuffersLastDeliveredTime().then((m) => lastDeliveredTimes = m),
		]).then((_) {
			Map<int, ServerEntry> serverMap = Map.fromEntries(serverEntries.map((entry) {
				return MapEntry(entry.id!, entry);
			}));

			networkEntries.forEach((networkEntry) {
				var serverEntry = serverMap[networkEntry.server]!;

				var server = ServerModel(serverEntry, networkEntry);
				serverList.add(server);

				var clientParams = connectParamsFromServerEntry(serverEntry);
				if (networkEntry.bouncerId != null) {
					clientParams = clientParams.replaceBouncerNetId(networkEntry.bouncerId);
				}
				var client = Client(clientParams);
				clientController.add(client, server);
			});

			bufferEntries.forEach((entry) {
				var server = serverList.servers.firstWhere((server) => server.networkId == entry.network);
				var buffer = BufferModel(entry: entry, server: server);
				bufferList.add(buffer);

				buffer.unreadCount = unreadCounts[buffer.id] ?? 0;
				if (lastDeliveredTimes[buffer.id] != null) {
					bufferList.bumpLastDeliveredTime(buffer, lastDeliveredTimes[buffer.id]!);
				}
			});

			clientController.clients.forEach((client) => client.connect());

			if (serverList.servers.length > 0) {
				return Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
					return BufferListPage();
				}));
			} else {
				return null;
			}
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

		return ConnectPage(loading: loading, error: error, onSubmit: (serverEntry) {
			setState(() {
				loading = true;
			});

			var db = context.read<DB>();

			var client = Client(connectParamsFromServerEntry(serverEntry));
			client.connect().then((_) {
				return db.storeServer(serverEntry);
			}).then((serverEntry) {
				return db.storeNetwork(NetworkEntry(server: serverEntry.id!));
			}).then((networkEntry) {
				var server = ServerModel(serverEntry, networkEntry);
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
