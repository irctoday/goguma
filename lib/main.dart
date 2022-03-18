import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';

import 'android_le.dart';
import 'app.dart';
import 'client.dart';
import 'client_controller.dart';
import 'database.dart';
import 'models.dart';
import 'notification_controller.dart';

// Debugging knobs for work manager.
const _debugWorkManager = false;
const _resetWorkManager = false;

void main() {
	var syncReceivePort = ReceivePort('main:sync');
	IsolateNameServer.registerPortWithName(syncReceivePort.sendPort, 'main:sync');

	WidgetsFlutterBinding.ensureInitialized();
	_initWorkManager();

	if (Platform.isAndroid) {
		trustIsrgRootX1();
	}

	var notifController = NotificationController();

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
		var clientProvider = ClientProvider(
			db: db,
			networkList: networkList,
			bufferList: bufferList,
			bouncerNetworkList: bouncerNetworkList,
			notifController: notifController,
		);

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
				Provider<NotificationController>.value(value: notifController),
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
		default:
			break;
		}
	};
	network.addListener(listener);
	return completer.future.timeout(Duration(minutes: 5)).whenComplete(() {
		network.removeListener(listener);
	});
}
