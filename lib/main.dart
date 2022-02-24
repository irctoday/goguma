import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';

import 'buffer-list-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'connect-page.dart';
import 'database.dart';
import 'models.dart';

// Debugging knobs for work manager.
const _debugWorkManager = false;
const _resetWorkManager = false;

void main() {
	var syncReceivePort = ReceivePort('main:sync');
	IsolateNameServer.registerPortWithName(syncReceivePort.sendPort, 'main:sync');

	WidgetsFlutterBinding.ensureInitialized();
	_initWorkManager();

	List<ServerEntry> serverEntries = [];
	List<NetworkEntry> networkEntries = [];
	List<BufferEntry> bufferEntries = [];
	Map<int, int> unreadCounts = Map();
	Map<int, String> lastDeliveredTimes = Map();
	DB.open().then((db) {
		return Future.wait([
			db.listServers().then((entries) => serverEntries = entries),
			db.listNetworks().then((entries) => networkEntries = entries),
			db.listBuffers().then((entries) => bufferEntries = entries),
			db.fetchBuffersUnreadCount().then((m) => unreadCounts = m),
			db.fetchBuffersLastDeliveredTime().then((m) => lastDeliveredTimes = m),
		]).then((_) => db);
	}).then((db) {
		var networkList = NetworkListModel();
		var bufferList = BufferListModel();
		var bouncerNetworkList = BouncerNetworkListModel();
		var clientProvider = ClientProvider(db, networkList, bufferList, bouncerNetworkList);

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

		// Listen for sync requests coming from the work manager Isolate
		syncReceivePort.listen((sendPort) {
			print('Starting chat history synchronization');

			// Make sure all connected clients are alive
			Future.wait(clientProvider.clients.map((client) {
				if (client.state != ClientState.connected) {
					return Future.value(null);
				}
				// Ignore errors because the client will just try reconnecting
				return client.ping().catchError((_) => null);
			})).then((_) {
				return Future.wait(networkList.networks.map((network) {
					return _waitNetworkOnline(network).catchError((err) {
						throw Exception('Failed to bring network "${network.serverEntry.host}" online: $err');
					});
				}));
			}).then((_) {
				print('Finished chat history synchronization');
				sendPort.send(true);
			}).catchError((err) {
				print('Failed chat history synchronization: $err');
				sendPort.send(false);
			});
		});

		runApp(MultiProvider(
			providers: [
				Provider<DB>.value(value: db),
				Provider<ClientProvider>.value(value: clientProvider),
				ChangeNotifierProvider<NetworkListModel>.value(value: networkList),
				ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
				ChangeNotifierProvider<BouncerNetworkListModel>.value(value: bouncerNetworkList),
			],
			child: GogumaApp(),
		));
	});
}

void _initWorkManager() {
	if (!Platform.isAndroid) {
		return;
	}
	Workmanager().initialize(_dispatchWorkManager, isInDebugMode: _debugWorkManager);
	if (_resetWorkManager && WidgetsBinding.instance!.lifecycleState == AppLifecycleState.resumed) {
		Workmanager().cancelAll();
	}
}

// This function is called from a separate Isolate.
void _dispatchWorkManager() {
	Workmanager().executeTask((taskName, data) {
		print('Executing work manager task: $taskName');
		switch (taskName) {
		case 'sync':
			var receivePort = ReceivePort('work-manager:sync');
			var sendPort = IsolateNameServer.lookupPortByName('main:sync')!;
			sendPort.send(receivePort.sendPort);
			return receivePort.first.then((data) {
				receivePort.close();
				return data as bool;
			});
		default:
			throw Exception('Unknown work manager task name: $taskName');
		}
	});
}

Future<void> _waitNetworkOnline(NetworkModel network) {
	if (network.state == NetworkState.online) {
		return Future.value(null);
	}

	var completer = Completer<void>();
	var attempts = 0;
	var listener = () {
		switch (network.state) {
		case NetworkState.offline:
			attempts++;
			if (attempts == 5) {
				completer.completeError(TimeoutException('Failed connecting after $attempts attempts'));
			}
			break;
		case NetworkState.online:
			completer.complete();
			break;
		}
	};
	network.addListener(listener);
	return completer.future.timeout(Duration(minutes: 5)).whenComplete(() {
		network.removeListener(listener);
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
			if (client.state == ClientState.connected) {
				client.ping().catchError((err) {
					print('PING failed: ${err}');
					return null;
				});
			}
		});
	}

	@override
	Widget build(BuildContext context) {
		var networkList = context.read<NetworkListModel>();

		Widget home;
		if (networkList.networks.length > 0) {
			home = BufferListPage();
		} else {
			home = GogumaApp();
		}

		return MaterialApp(
			title: 'Goguma',
			theme: ThemeData(primarySwatch: Colors.indigo),
			home: home,
			debugShowCheckedModeBanner: false,
		);
	}
}

class Goguma extends StatefulWidget {
	@override
	GogumaState createState() => GogumaState();
}

class GogumaState extends State<Goguma> {
	bool loading = false;
	Exception? error = null;

	@override
	Widget build(BuildContext context) {
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
