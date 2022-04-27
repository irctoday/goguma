import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
	FlutterError.onError = _handleFlutterError;

	runZonedGuarded(_main, (Object error, StackTrace stack) {
		FlutterError.reportError(FlutterErrorDetails(
			exception: error,
			stack: stack,
			library: 'goguma',
		));
	});
}

void _main() async {
	var syncReceivePort = ReceivePort('main:sync');
	IsolateNameServer.registerPortWithName(syncReceivePort.sendPort, 'main:sync');

	WidgetsFlutterBinding.ensureInitialized();
	_initWorkManager();

	if (Platform.isAndroid) {
		trustIsrgRootX1();
	}

	var notifController = NotificationController();

	var sharedPreferences = await SharedPreferences.getInstance();

	var db = await DB.open();

	// Load all the data we need concurrently
	var serverEntriesFuture = db.listServers();
	var networkEntriesFuture = db.listNetworks();
	var bufferEntriesFuture = db.listBuffers();
	var unreadCountsFuture = db.fetchBuffersUnreadCount();
	var lastDeliveredTimesFuture = db.fetchBuffersLastDeliveredTime();

	var serverEntries = await serverEntriesFuture;
	var networkEntries = await networkEntriesFuture;
	var bufferEntries = await bufferEntriesFuture;
	var unreadCounts = await unreadCountsFuture;
	var lastDeliveredTimes = await lastDeliveredTimesFuture;

	var defaultNickname = sharedPreferences.getString('nickname');
	var defaultRealname = sharedPreferences.getString('realname');

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

	for (var networkEntry in networkEntries) {
		var serverEntry = serverMap[networkEntry.server]!;

		var clientParams = connectParamsFromServerEntry(
			serverEntry,
			defaultNickname: defaultNickname ?? 'user',
			defaultRealname: defaultRealname,
		);
		if (networkEntry.bouncerId != null) {
			clientParams = clientParams.apply(bouncerNetId: networkEntry.bouncerId);
		}

		var network = NetworkModel(serverEntry, networkEntry, clientParams.nick, clientParams.realname);
		networkList.add(network);

		var client = Client(clientParams);
		clientProvider.add(client, network);
	}

	for (var entry in bufferEntries) {
		var network = networkList.networks.firstWhere((network) => network.networkId == entry.network);
		var buffer = BufferModel(entry: entry, network: network);
		bufferList.add(buffer);

		buffer.unreadCount = unreadCounts[buffer.id] ?? 0;
		if (lastDeliveredTimes[buffer.id] != null) {
			bufferList.bumpLastDeliveredTime(buffer, lastDeliveredTimes[buffer.id]!);
		}
	}

	for (var client in clientProvider.clients) {
		client.connect().ignore();
	}

	// Listen for sync requests coming from the work manager Isolate
	syncReceivePort.listen((sendPort) {
		_syncChatHistory(sendPort as SendPort, clientProvider, networkList);
	});

	runApp(MultiProvider(
		providers: [
			Provider<DB>.value(value: db),
			Provider<ClientProvider>.value(value: clientProvider),
			Provider<NotificationController>.value(value: notifController),
			Provider<SharedPreferences>.value(value: sharedPreferences),
			ChangeNotifierProvider<NetworkListModel>.value(value: networkList),
			ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
			ChangeNotifierProvider<BouncerNetworkListModel>.value(value: bouncerNetworkList),
		],
		child: App(),
	));
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

void _syncChatHistory(SendPort sendPort, ClientProvider clientProvider, NetworkListModel networkList) async {
	print('Starting chat history synchronization');

	var autoReconnectLock = ClientAutoReconnectLock.acquire(clientProvider);

	try {
		// Make sure all connected clients are alive
		await Future.wait(clientProvider.clients.map((client) async {
			if (client.state != ClientState.connected) {
				return;
			}

			// Ignore errors because the client will just try reconnecting
			try {
				await client.ping();
			} on Exception catch (_) {}
		}));

		await Future.wait(networkList.networks.map((network) async {
			try {
				await _waitNetworkOnline(network);
			} on Exception catch (err) {
				throw Exception('Failed to bring network "${network.serverEntry.host}" online: $err');
			}
		}));

		print('Finished chat history synchronization');
		sendPort.send(true);
	} on Object catch (err) {
		print('Failed chat history synchronization: $err');
		sendPort.send(false);
	} finally {
		autoReconnectLock.release();
	}
}

// This function is called from a separate Isolate.
void _dispatchWorkManager() {
	Workmanager().executeTask((taskName, data) async {
		print('Executing work manager task: $taskName');
		switch (taskName) {
		case 'sync':
			var receivePort = ReceivePort('work-manager:sync');
			var sendPort = IsolateNameServer.lookupPortByName('main:sync')!;
			sendPort.send(receivePort.sendPort);
			var data = await receivePort.first;
			receivePort.close();
			return data as bool;
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
	void listener() {
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
	}
	network.addListener(listener);
	return completer.future.timeout(Duration(minutes: 5)).whenComplete(() {
		network.removeListener(listener);
	});
}

void _handleFlutterError(FlutterErrorDetails details) {
	FlutterError.presentError(details);
	if (kReleaseMode && !(details.exception is Exception)) {
		exit(1);
	}
}
