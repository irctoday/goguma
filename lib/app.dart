import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'client_controller.dart';
import 'models.dart';
import 'network_state_aggregator.dart';
import 'notification_controller.dart';
import 'page/buffer.dart';
import 'page/buffer_details.dart';
import 'page/buffer_list.dart';
import 'page/connect.dart';

const _themeMode = ThemeMode.system;

class App extends StatefulWidget {
	const App({ Key? key }) : super(key: key);

	@override
	AppState createState() => AppState();
}

class AppState extends State<App> with WidgetsBindingObserver {
	Timer? _pingTimer;
	final GlobalKey<NavigatorState> _navigatorKey = GlobalKey(debugLabel: 'main-navigator');
	final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey(debugLabel: 'main-scaffold-messenger');
	late StreamSubscription<void> _clientErrorSub;
	late StreamSubscription<void> _connectivitySub;
	late StreamSubscription<void> _notifSelectionSub;
	late NetworkStateAggregator _networkStateAggregator;

	@override
	void initState() {
		super.initState();
		WidgetsBinding.instance!.addObserver(this);

		var state = WidgetsBinding.instance!.lifecycleState;
		if (state == AppLifecycleState.resumed || state == null) {
			_enablePingTimer();
		}

		var notifController = context.read<NotificationController>();
		notifController.initialize().then(_handleSelectNotification);
		_notifSelectionSub = notifController.selections.listen(_handleSelectNotification);

		var clientProvider = context.read<ClientProvider>();
		_clientErrorSub = clientProvider.errors.listen((err) {
			var snackBar = SnackBar(content: Text(err.toString()));
			_scaffoldMessengerKey.currentState?.showSnackBar(snackBar);
		});

		_connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
			if (result != ConnectivityResult.none) {
				_pingAll();
			}
		});

		var networkList = context.read<NetworkListModel>();
		_networkStateAggregator = NetworkStateAggregator(networkList);
		_networkStateAggregator.addListener(_handleNetworkStateChange);
	}

	@override
	void dispose() {
		WidgetsBinding.instance!.removeObserver(this);
		_pingTimer?.cancel();
		_clientErrorSub.cancel();
		_connectivitySub.cancel();
		_notifSelectionSub.cancel();
		_networkStateAggregator.removeListener(_handleNetworkStateChange);
		_networkStateAggregator.dispose();
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
			switch (client.state) {
			case ClientState.connected:
				client.ping().catchError((Object err) {
					print('PING failed: $err');
					return null;
				});
				break;
			case ClientState.disconnected:
				client.connect().ignore();
				break;
			default:
				break;
			}
		});
	}

	void _handleSelectNotification(String? payload) {
		if (payload == null) {
			return;
		}
		if (!payload.startsWith('buffer:')) {
			throw FormatException('Invalid payload: $payload');
		}
		var bufferId = int.parse(payload.replaceFirst('buffer:', ''));
		var bufferList = context.read<BufferListModel>();
		var buffer = bufferList.byId(bufferId);
		if (buffer == null) {
			return; // maybe closed by the user in-between
		}
		var until = ModalRoute.withName(BufferListPage.routeName);
		_navigatorKey.currentState!.pushNamedAndRemoveUntil(BufferPage.routeName, until, arguments: buffer);
	}

	void _handleNetworkStateChange() {
		var state = _networkStateAggregator.state;
		var faultyNetwork = _networkStateAggregator.faultyNetwork;
		var faultyNetworkName = faultyNetwork?.displayName ?? 'server';

		_scaffoldMessengerKey.currentState?.clearSnackBars();

		if (state != NetworkState.offline) {
			_scaffoldMessengerKey.currentState?.hideCurrentMaterialBanner();
			return;
		}

		_scaffoldMessengerKey.currentState?.showMaterialBanner(MaterialBanner(
			content: Text('Disconnected from $faultyNetworkName'),
			actions: [
				TextButton(
					child: Text('RECONNECT'),
					onPressed: () {
						var clientProvider = context.read<ClientProvider>();
						for (var client in clientProvider.clients) {
							if (client.state == ClientState.disconnected) {
								client.connect().ignore();
							}
						}
					},
				),
			],
		));
	}

	Route<dynamic>? _handleGenerateRoute(RouteSettings settings) {
		WidgetBuilder builder;
		switch (settings.name) {
		case ConnectPage.routeName:
			builder = (context) => ConnectPage();
			break;
		case BufferListPage.routeName:
			builder = (context) => BufferListPage();
			break;
		case BufferPage.routeName:
			var buffer = settings.arguments as BufferModel;
			builder = (context) {
				var client = context.read<ClientProvider>().get(buffer.network);
				return MultiProvider(
					providers: [
						ChangeNotifierProvider<BufferModel>.value(value: buffer),
						ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
						Provider<Client>.value(value: client),
					],
					child: BufferPage(unreadMarkerTime: buffer.entry.lastReadTime),
				);
			};
			break;
		case BufferDetailsPage.routeName:
			var buffer = settings.arguments as BufferModel;
			builder = (context) {
				var client = context.read<ClientProvider>().get(buffer.network);
				return MultiProvider(
					providers: [
						ChangeNotifierProvider<BufferModel>.value(value: buffer),
						ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
						Provider<Client>.value(value: client),
					],
					child: BufferDetailsPage(),
				);
			};
			break;
		default:
			throw Exception('Unknown route ${settings.name}');
		}
		return MaterialPageRoute(builder: builder, settings: settings);
	}

	@override
	Widget build(BuildContext context) {
		var networkList = context.read<NetworkListModel>();

		String initialRoute;
		if (networkList.networks.isEmpty) {
			initialRoute = ConnectPage.routeName;
		} else {
			initialRoute = BufferListPage.routeName;
		}

		return MaterialApp(
			title: 'Goguma',
			theme: ThemeData(primarySwatch: Colors.indigo),
			darkTheme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: Colors.indigo),
			themeMode: _themeMode,
			initialRoute: initialRoute,
			onGenerateRoute: _handleGenerateRoute,
			navigatorKey: _navigatorKey,
			scaffoldMessengerKey: _scaffoldMessengerKey,
			debugShowCheckedModeBanner: false,
		);
	}
}
