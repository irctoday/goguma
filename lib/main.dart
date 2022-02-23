import 'dart:async';

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
		var networkList = NetworkListModel();
		var bufferList = BufferListModel();
		var bouncerNetworkList = BouncerNetworkListModel();
		runApp(MultiProvider(
			providers: [
				Provider<DB>.value(value: db),
				Provider<ClientProvider>.value(value: ClientProvider(db, networkList, bufferList, bouncerNetworkList)),
				ChangeNotifierProvider<NetworkListModel>.value(value: networkList),
				ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
				ChangeNotifierProvider<BouncerNetworkListModel>.value(value: bouncerNetworkList),
			],
			child: GogumaApp(),
		));
	});
}

class GogumaApp extends StatefulWidget {
	@override
	GogumaAppState createState() => GogumaAppState();
}

class GogumaAppState extends State<GogumaApp> with WidgetsBindingObserver {
	Timer? _pingTimer;

	@override
	void initState() {
		super.initState();
		WidgetsBinding.instance!.addObserver(this);

		var state = WidgetsBinding.instance!.lifecycleState;
		if (state == AppLifecycleState.resumed || state == null) {
			_enablePingTimer();
		}
	}

	@override
	void dispose() {
		WidgetsBinding.instance!.removeObserver(this);
		_pingTimer?.cancel();
		super.dispose();
	}

	@override
	void didChangeAppLifecycleState(AppLifecycleState state) {
		super.didChangeAppLifecycleState(state);

		if (state == AppLifecycleState.resumed) {
			// Send PINGs to make sure the connections are healthy
			_pingAll();
			_enablePingTimer();
		} else {
			_pingTimer?.cancel();
			_pingTimer = null;
		}
	}

	void _enablePingTimer() {
		_pingTimer?.cancel();
		_pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
			_pingAll();
		});
	}

	void _pingAll() {
		context.read<ClientProvider>().clients.forEach((client) {
			if (client.state == ClientState.registered) {
				client.ping().catchError((err) {
					print('PING failed: ${err}');
					return null;
				});
			}
		});
	}

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
		var networkList = context.read<NetworkListModel>();
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();

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

				var network = NetworkModel(serverEntry, networkEntry);
				networkList.add(network);

				var clientParams = connectParamsFromServerEntry(serverEntry);
				if (networkEntry.bouncerId != null) {
					clientParams = clientParams.replaceBouncerNetId(networkEntry.bouncerId);
				}
				var client = Client(clientParams);
				clientProvider.add(client, network);
			});

			bufferEntries.forEach((entry) {
				var network = networkList.networks.firstWhere((network) => network.networkId == entry.network);
				var buffer = BufferModel(entry: entry, network: network);
				bufferList.add(buffer);

				buffer.unreadCount = unreadCounts[buffer.id] ?? 0;
				if (lastDeliveredTimes[buffer.id] != null) {
					bufferList.bumpLastDeliveredTime(buffer, lastDeliveredTimes[buffer.id]!);
				}
			});

			clientProvider.clients.forEach((client) {
				client.connect().ignore();
			});

			if (networkList.networks.length > 0) {
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

			// TODO: only connect once (but be careful not to loose messages
			// sent immediately after RPL_WELCOME)
			var clientParams = connectParamsFromServerEntry(serverEntry);
			var client = Client(clientParams);
			client.connect().then((_) {
				client.disconnect();
				return db.storeServer(serverEntry);
			}).then((serverEntry) {
				return db.storeNetwork(NetworkEntry(server: serverEntry.id!));
			}).then((networkEntry) {
				var client = Client(clientParams);
				var network = NetworkModel(serverEntry, networkEntry);
				context.read<NetworkListModel>().add(network);
				context.read<ClientProvider>().add(client, network);
				client.connect();

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
