import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';

import 'android_le.dart';
import 'app.dart';
import 'client.dart';
import 'client_controller.dart';
import 'database.dart';
import 'irc.dart';
import 'link_preview.dart';
import 'logging.dart';
import 'models.dart';
import 'notification_controller.dart';
import 'prefs.dart';
import 'push.dart';
import 'unifiedpush.dart';

// Debugging knobs for work manager.
const _debugWorkManager = bool.fromEnvironment('debugWorkManager', defaultValue: false);

Future<PushController> Function() initPush = UnifiedPushController.init;

void main() async {
	FlutterError.onError = _handleFlutterError;
	PlatformDispatcher.instance.onError = (error, stack) {
		FlutterError.reportError(FlutterErrorDetails(
			exception: error,
			stack: stack,
			library: 'goguma',
		));
		return true;
	};

	var syncReceivePort = ReceivePort('main:sync');
	IsolateNameServer.registerPortWithName(syncReceivePort.sendPort, 'main:sync');

	WidgetsFlutterBinding.ensureInitialized();
	await _initWorkManager();

	PushController? pushController;
	try {
		pushController = await initPush();
	} on Exception catch (err) {
		log.print('Warning: failed to initialize push controller', error: err);
	}

	if (Platform.isAndroid) {
		trustIsrgRootX1();
	}

	var appLinks = AppLinks();
	IrcUri? initialUri;
	if (Platform.isAndroid) {
		var initialUriStr = await appLinks.getInitialAppLinkString();
		if (initialUriStr != null) {
			initialUri = IrcUri.parse(initialUriStr);
		}
	}

	var notifController = await NotificationController.init();
	var prefs = await Prefs.load();
	var db = await DB.open();

	// If the push provider has changed, wipe our Web Push subscriptions table.
	// Ideally we'd unregister old subscriptions, but it's too late at this
	// point.
	String? pushProviderName = pushController?.providerName;
	if (pushProviderName != prefs.pushProvider) {
		var subs = await db.listWebPushSubscriptions();
		List<Future<void>> futures = [];
		for (var sub in subs) {
			futures.add(db.deleteWebPushSubscription(sub.id!));
		}
		await Future.wait(futures);
		prefs.pushProvider = pushProviderName;
	}

	var networkList = NetworkListModel();
	var bufferList = BufferListModel();
	var bouncerNetworkList = BouncerNetworkListModel();
	var clientProvider = ClientProvider(
		db: db,
		networkList: networkList,
		bufferList: bufferList,
		bouncerNetworkList: bouncerNetworkList,
		notifController: notifController,
		pushController: pushController,
	);

	await _initModels(
		db: db,
		prefs: prefs,
		clientProvider: clientProvider,
		networkList: networkList,
		bufferList: bufferList,
	);

	for (var client in clientProvider.clients) {
		client.connect().ignore();
	}

	// Listen for sync requests coming from the work manager Isolate
	syncReceivePort.listen((data) async {
		var sendPort = data as SendPort;
		try {
			await _syncChatHistory(clientProvider, networkList);
			sendPort.send(true);
		} on Object {
			sendPort.send(false);
			rethrow;
		}
	});

	runApp(MultiProvider(
		providers: [
			Provider<DB>.value(value: db),
			Provider<ClientProvider>.value(value: clientProvider),
			Provider<NotificationController>.value(value: notifController),
			Provider<Prefs>.value(value: prefs),
			Provider<AppLinks>.value(value: appLinks),
			ChangeNotifierProvider<NetworkListModel>.value(value: networkList),
			ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
			ChangeNotifierProvider<BouncerNetworkListModel>.value(value: bouncerNetworkList),
			Provider<LinkPreviewer>(
				create: (context) => LinkPreviewer(db),
				dispose: (context, linkPreviewer) => linkPreviewer.dispose(),
			),
		],
		child: App(initialUri: initialUri),
	));
}

Future<void> _initModels({
	required DB db,
	required Prefs prefs,
	required ClientProvider clientProvider,
	required NetworkListModel networkList,
	required BufferListModel bufferList,
}) async {
	// Load all the data we need concurrently
	var serverEntriesFuture = db.listServers();
	var networkEntriesFuture = db.listNetworks();
	var bufferEntriesFuture = db.listBuffers();
	var unreadCountsFuture = db.listBuffersUnreadCount();
	var lastDeliveredTimesFuture = db.listBuffersLastDeliveredTime();

	var serverEntries = await serverEntriesFuture;
	var networkEntries = await networkEntriesFuture;
	var bufferEntries = await bufferEntriesFuture;
	var unreadCounts = await unreadCountsFuture;
	var lastDeliveredTimes = await lastDeliveredTimesFuture;

	Map<int, ServerEntry> serverMap = Map.fromEntries(serverEntries.map((entry) {
		return MapEntry(entry.id!, entry);
	}));

	for (var networkEntry in networkEntries) {
		var serverEntry = serverMap[networkEntry.server]!;

		var clientParams = connectParamsFromServerEntry(serverEntry, prefs);
		if (networkEntry.bouncerId != null) {
			clientParams = clientParams.apply(bouncerNetId: networkEntry.bouncerId);
		}

		var network = NetworkModel(serverEntry, networkEntry, clientParams.nick, clientParams.realname);
		networkList.add(network);

		var client = Client(clientParams, isupport: networkEntry.isupport);
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
}

Future<void> _initWorkManager() async {
	if (!Platform.isAndroid) {
		return;
	}

	await Workmanager().initialize(_dispatchWorkManager, isInDebugMode: _debugWorkManager);

	// Terminate any currently running sync job
	await Workmanager().cancelAll();
}

Future<void> _syncChatHistory(ClientProvider clientProvider, NetworkListModel networkList) async {
	log.print('Starting chat history synchronization');

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

		log.print('Finished chat history synchronization');
	} on Object catch (err) {
		log.print('Failed chat history synchronization', error: err);
		rethrow;
	} finally {
		autoReconnectLock.release();
	}
}

// This function is called from a separate Isolate.
@pragma('vm:entry-point')
void _dispatchWorkManager() {
	Workmanager().executeTask((taskName, data) async {
		try {
			WidgetsFlutterBinding.ensureInitialized();

			log.print('Executing work manager task: $taskName');

			switch (taskName) {
			case 'sync':
				await _handleWorkManagerSync();
				return true;
			default:
				throw Exception('Unknown work manager task name: $taskName');
			}
		} on Object catch (error, stack) {
			FlutterError.reportError(FlutterErrorDetails(
				exception: error,
				stack: stack,
				library: 'workmanager',
			));
			return false;
		}
	});
}

Future<void> _handleWorkManagerSync() async {
	// If the main Isolate is running, delegate synchronization
	var sendPort = IsolateNameServer.lookupPortByName('main:sync');
	if (sendPort != null) {
		var receivePort = ReceivePort('work-manager:sync');
		sendPort.send(receivePort.sendPort);

		var data = await receivePort.first;
		receivePort.close();
		var ok = data as bool;
		if (!ok) {
			throw Exception('Chat history sync failed');
		}
		return;
	}

	// Otherwise we do the synchronization ourselves

	if (Platform.isAndroid) {
		trustIsrgRootX1();
	}

	var notifController = await NotificationController.init();
	var prefs = await Prefs.load();
	var db = await DB.open();

	var networkList = NetworkListModel();
	var bufferList = BufferListModel();
	var bouncerNetworkList = BouncerNetworkListModel();
	var clientProvider = ClientProvider(
		db: db,
		networkList: networkList,
		bufferList: bufferList,
		bouncerNetworkList: bouncerNetworkList,
		notifController: notifController,
		enableSync: false,
	);

	await _initModels(
		db: db,
		prefs: prefs,
		clientProvider: clientProvider,
		networkList: networkList,
		bufferList: bufferList,
	);

	for (var client in clientProvider.clients) {
		client.connect().ignore();
	}

	try {
		await _syncChatHistory(clientProvider, networkList);
	} finally {
		for (var client in clientProvider.clients) {
			client.dispose();
		}
	}
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
	FlutterError.dumpErrorToConsole(details, forceReport: true);
	if (kReleaseMode && details.exception is Error) {
		exit(1);
	}
}
