import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ansi.dart';
import 'client.dart';
import 'client_controller.dart';
import 'dialog/authenticate.dart';
import 'irc.dart';
import 'logging.dart';
import 'models.dart';
import 'network_state_aggregator.dart';
import 'notification_controller.dart';
import 'page/buffer.dart';
import 'page/buffer_details.dart';
import 'page/buffer_list.dart';
import 'page/connect.dart';
import 'page/gallery.dart';
import 'page/join.dart';
import 'page/edit_bouncer_network.dart';
import 'page/network_details.dart';
import 'page/settings.dart';

const _themeMode = ThemeMode.system;

class App extends StatefulWidget {
	final IrcUri? initialUri;

	const App({ super.key, this.initialUri });

	@override
	State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
	late final String _initialRoute;
	Timer? _pingTimer;
	ClientAutoReconnectLock? _autoReconnectLock;
	final GlobalKey<NavigatorState> _navigatorKey = GlobalKey(debugLabel: 'main-navigator');
	final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey(debugLabel: 'main-scaffold-messenger');
	late StreamSubscription<void> _clientErrorSub;
	late StreamSubscription<void> _clientNoticeSub;
	late StreamSubscription<void> _connectivitySub;
	late StreamSubscription<void> _notifSelectionSub;
	StreamSubscription<void>? _appLinksSub;
	late NetworkStateAggregator _networkStateAggregator;
	final Map<NetworkModel, List<ScaffoldFeatureController<SnackBar, SnackBarClosedReason>>> _snackBarControllers = {};
	Set<NetworkModel> _faultyNetworks = {};

	@override
	void initState() {
		super.initState();
		WidgetsBinding.instance.addObserver(this);

		var state = WidgetsBinding.instance.lifecycleState;
		if (state == AppLifecycleState.resumed || state == null) {
			_enableAutoReconnect();
			_enablePingTimer();
		}

		var notifController = context.read<NotificationController>();
		notifController.popLaunchSelection().then(_handleSelectNotification);
		_notifSelectionSub = notifController.selections.listen(_handleSelectNotification);

		var clientProvider = context.read<ClientProvider>();
		_clientErrorSub = clientProvider.errors.listen((err) {
			if (err.msg.cmd == ERR_NOTREGISTERED) {
				// We may send commands the server doesn't accept before
				// connection registration (e.g. AWAY), because we don't know
				// the server's available capabilities at that point.
				return;
			}
			if (err.msg.cmd == ERR_UNKNOWNCOMMAND && err.msg.params[1] == 'AWAY') {
				// Some servers may be missing AWAY support
				return;
			}

			SnackBarAction? action;
			if (err.msg.cmd == ERR_SASLFAIL) {
				if (err.client.params.bouncerNetId != null) {
					// We'll get the same error on the bouncer connection
					return;
				}

				if (err.client.params.saslPlain != null) {
					// TODO: also handle FAIL ACCOUNT_REQUIRED
					action = SnackBarAction(
						label: 'UPDATE PASSWORD',
						onPressed: () {
							AuthenticateDialog.show(_navigatorKey.currentState!.context, err.network);
						},
					);
				}
			}

			var snackBar = SnackBar(content: Text(err.toString()), action: action);
			_showNetworkSnackBar(snackBar, err.network);
		});
		_clientNoticeSub = clientProvider.notices.listen((notice) {
			List<String> texts = [];
			for (var msg in notice.msgs) {
				texts.add(stripAnsiFormatting(msg.params[1]));
			}
			var snackBar = SnackBar(content: Text.rich(TextSpan(children: [
				TextSpan(text: notice.target, style: TextStyle(fontWeight: FontWeight.bold)),
				TextSpan(text: ': '),
				TextSpan(text: texts.join('\n')),
			])));
			_showNetworkSnackBar(snackBar, notice.network);
		});

		_connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
			if (result != ConnectivityResult.none) {
				_pingAll();
			}
		});

		var networkList = context.read<NetworkListModel>();
		_networkStateAggregator = NetworkStateAggregator(networkList);
		_networkStateAggregator.addListener(_handleNetworkStateChange);
		_handleNetworkStateChange();

		if (Platform.isAndroid || Platform.isIOS) {
			var appLinks = context.read<AppLinks>();
			_appLinksSub = appLinks.stringLinkStream.listen(_handleAppLink);
		}

		if (networkList.networks.isEmpty) {
			_initialRoute = ConnectPage.routeName;
		} else {
			_initialRoute = BufferListPage.routeName;

			if (widget.initialUri != null) {
				Timer(const Duration(), () {
					_handleAppLink(widget.initialUri.toString());
				});
			}
		}
	}

	@override
	void dispose() {
		WidgetsBinding.instance.removeObserver(this);
		_pingTimer?.cancel();
		_autoReconnectLock?.release();
		_clientErrorSub.cancel();
		_clientNoticeSub.cancel();
		_connectivitySub.cancel();
		_notifSelectionSub.cancel();
		_appLinksSub?.cancel();
		_networkStateAggregator.removeListener(_handleNetworkStateChange);
		_networkStateAggregator.dispose();
		super.dispose();
	}

	@override
	void didChangeAppLifecycleState(AppLifecycleState state) {
		super.didChangeAppLifecycleState(state);

		if (state == AppLifecycleState.resumed) {
			_enableAutoReconnect();
			// Send PINGs to make sure the connections are healthy
			_pingAll();
			_enablePingTimer();
		} else {
			_autoReconnectLock?.release();
			_autoReconnectLock = null;
			_pingTimer?.cancel();
			_pingTimer = null;
		}
	}

	void _showNetworkSnackBar(SnackBar snackBar, NetworkModel network) {
		var scaffoldMessenger = _scaffoldMessengerKey.currentState;
		if (scaffoldMessenger == null) {
			return;
		}

		var controller = scaffoldMessenger.showSnackBar(snackBar);
		_snackBarControllers.putIfAbsent(network, () => []).add(controller);
		controller.closed.whenComplete(() {
			_snackBarControllers[network]!.remove(controller);
		});
	}

	void _closeNetworkSnackBars(NetworkModel network) {
		for (var controller in _snackBarControllers[network] ?? const []) {
			controller.close();
		}
	}

	void _enableAutoReconnect() {
		var clientProvider = context.read<ClientProvider>();
		_autoReconnectLock?.release();
		_autoReconnectLock = ClientAutoReconnectLock.acquire(clientProvider);
	}

	void _enablePingTimer() {
		_pingTimer?.cancel();
		_pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
			_pingAll();
		});
	}

	void _pingAll() {
		context.read<ClientProvider>().clients.forEach((client) async {
			switch (client.state) {
			case ClientState.connected:
				try {
					await client.ping();
				} on Exception catch (err) {
					log.print('PING failed', error: err);
				}
				break;
			case ClientState.disconnected:
				try {
					await client.connect();
				} on Exception catch (err) {
					log.print('Reconnect failed', error: err);
				}
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
		if (payload.startsWith('buffer:')) {
			_handleSelectBufferNotification(payload.replaceFirst('buffer:', ''));
		} else if (payload.startsWith('invite:')) {
			_handleSelectInviteNotification(payload.replaceFirst('invite:', ''));
		} else {
			throw FormatException('Invalid payload: $payload');
		}
	}

	void _handleSelectBufferNotification(String payload) {
		var bufferId = int.parse(payload);
		var bufferList = context.read<BufferListModel>();
		var buffer = bufferList.byId(bufferId);
		if (buffer == null) {
			return; // maybe closed by the user in-between
		}
		var until = ModalRoute.withName(BufferListPage.routeName);
		_navigatorKey.currentState!.pushNamedAndRemoveUntil(BufferPage.routeName, until, arguments: buffer);
	}

	void _handleSelectInviteNotification(String payload) {
		var i = payload.indexOf(':');
		if (i < 0) {
			throw FormatException('Invalid invite payload: $payload');
		}
		var networkId = int.parse(payload.substring(0, i));
		var channel = payload.substring(i + 1);

		var networkList = context.read<NetworkListModel>();
		var network = networkList.byId(networkId)!;

		BufferPage.open(_navigatorKey.currentState!.context, channel, network);
	}

	void _handleNetworkStateChange() {
		var networkList = context.read<NetworkListModel>();
		var state = _networkStateAggregator.state;
		var faultyNetworks = _networkStateAggregator.faultyNetworks;

		String? faultyNetworkName;
		if (faultyNetworks.length == 1) {
			faultyNetworkName = faultyNetworks.first.displayName;
		} else if (faultyNetworks.length == networkList.networks.length) {
			faultyNetworkName = 'all servers';
		} else {
			faultyNetworkName = '${faultyNetworks.length} servers';
		}

		var affectedNetworks = Set.of(faultyNetworks).union(_faultyNetworks);
		for (var network in affectedNetworks) {
			_closeNetworkSnackBars(network);
		}

		_faultyNetworks = Set.of(faultyNetworks);

		if (state != NetworkState.offline) {
			_scaffoldMessengerKey.currentState?.clearMaterialBanners();
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

	void _handleAppLink(String uriStr) {
		var networkList = context.read<NetworkListModel>();
		var bufferList = context.read<BufferListModel>();
		var navigatorState = _navigatorKey.currentState!;

		var uri = IrcUri.parse(uriStr);

		if (networkList.networks.isEmpty) {
			navigatorState.pushReplacementNamed(ConnectPage.routeName, arguments: uri);
			return;
		}

		// TODO: also match port
		NetworkModel? network;
		for (var net in networkList.networks) {
			if (net.serverEntry.host == uri.host) {
				network = net;
				break;
			}

			var bouncerUri = net.networkEntry.bouncerUri;
			if (bouncerUri != null && bouncerUri.host == uri.host) {
				network = net;
				break;
			}
		}
		if (network != null) {
			if (uri.entity != null) {
				var buffer = bufferList.get(uri.entity!.name, network);
				if (buffer != null) {
					navigatorState.pushNamed(BufferPage.routeName, arguments: buffer);
				} else {
					_confirmOpenBuffer(network, uri.entity!.name);
				}
			} else {
				navigatorState.pushNamed(NetworkDetailsPage.routeName, arguments: network);
			}
			return;
		}

		bool hasBouncer = false;
		for (var net in networkList.networks) {
			if (net.networkEntry.caps.containsKey('soju.im/bouncer-networks')) {
				hasBouncer = true;
				break;
			}
		}
		if (!hasBouncer) {
			throw Exception('Adding new networks without a bouncer is not yet supported');
		}

		navigatorState.pushNamed(EditBouncerNetworkPage.routeName, arguments: uri);
	}

	void _confirmOpenBuffer(NetworkModel network, String target) async {
		var client = context.read<ClientProvider>().get(network);

		Widget content;
		if (client.isNick(target)) {
			content = Text.rich(TextSpan(children: [
				TextSpan(text: 'Do you want to start a conversation with the user '),
				TextSpan(text: target, style: TextStyle(fontWeight: FontWeight.bold)),
				TextSpan(text: '?'),
			]));
		} else if (client.isChannel(target)) {
			content = Text.rich(TextSpan(children: [
				TextSpan(text: 'Do you want to join the channel '),
				TextSpan(text: target, style: TextStyle(fontWeight: FontWeight.bold)),
				TextSpan(text: '?'),
			]));
		} else {
			throw Exception('Cannot open buffer "$target": neither a nick nor a channel');
		}

		unawaited(showDialog<void>(context: _navigatorKey.currentState!.overlay!.context, builder: (context) {
			return AlertDialog(
				title: const Text('New conversation'),
				content: content,
				actions: [
					TextButton(
						onPressed: () {
							Navigator.pop(context);
						},
						child: const Text('Cancel'),
					),
					TextButton(
						onPressed: () {
							Navigator.pop(context);
							BufferPage.open(context, target, network);
						},
						child: const Text('Start conversation'),
					),
				],
			);
		}));
	}

	Route<dynamic>? _handleGenerateRoute(RouteSettings settings) {
		WidgetBuilder builder;
		switch (settings.name) {
		case ConnectPage.routeName:
			var uri = settings.arguments as IrcUri?;
			builder = (context) => ConnectPage(initialUri: uri);
			break;
		case BufferListPage.routeName:
			builder = (context) => BufferListPage();
			break;
		case JoinPage.routeName:
			builder = (context) => JoinPage();
			break;
		case SettingsPage.routeName:
			builder = (context) => SettingsPage();
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
		case EditBouncerNetworkPage.routeName:
			BouncerNetworkModel? network;
			IrcUri? initialUri;
			if (settings.arguments is BouncerNetworkModel) {
				network = settings.arguments as BouncerNetworkModel;
			} else if (settings.arguments is IrcUri) {
				initialUri = settings.arguments as IrcUri;
			} else if (settings.arguments != null) {
				throw ArgumentError.value(settings.arguments, null, 'EditBouncerNetworkPage only accepts a BouncerNetworkModel or Uri argument');
			}
			builder = (context) => EditBouncerNetworkPage(network: network, initialUri: initialUri);
			break;
		case NetworkDetailsPage.routeName:
			var network = settings.arguments as NetworkModel;
			builder = (context) {
				var client = context.read<ClientProvider>().get(network);
				return MultiProvider(
					providers: [
						ChangeNotifierProvider<NetworkModel>.value(value: network),
						Provider<Client>.value(value: client),
					],
					child: NetworkDetailsPage(),
				);
			};
			break;
		case GalleryPage.routeName:
			var args = settings.arguments as GalleryPageArguments;
			builder = (context) => GalleryPage(uri: args.uri, heroTag: args.heroTag);
			break;
		default:
			throw Exception('Unknown route ${settings.name}');
		}
		return MaterialPageRoute(builder: builder, settings: settings);
	}

	List<Route<dynamic>> _handleGenerateInitialRoutes(String initialRoute) {
		if (initialRoute == ConnectPage.routeName) {
			// Prevent the default implementation from generating routes for
			// both '/' and '/connect'
			return [_handleGenerateRoute(RouteSettings(
				name: initialRoute,
				arguments: widget.initialUri,
			))!];
		} else {
			return Navigator.defaultGenerateInitialRoutes(_navigatorKey.currentState!, initialRoute);
		}
	}

	@override
	Widget build(BuildContext context) {
		return MaterialApp(
			title: 'Goguma',
			theme: ThemeData(primarySwatch: Colors.indigo),
			darkTheme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: Colors.indigo),
			themeMode: _themeMode,
			initialRoute: _initialRoute,
			onGenerateRoute: _handleGenerateRoute,
			onGenerateInitialRoutes: _handleGenerateInitialRoutes,
			navigatorKey: _navigatorKey,
			scaffoldMessengerKey: _scaffoldMessengerKey,
			debugShowCheckedModeBanner: false,
		);
	}
}
