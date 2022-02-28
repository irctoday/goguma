import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:workmanager/workmanager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

ConnectParams connectParamsFromServerEntry(ServerEntry entry) {
	SaslPlainCredentials? saslPlain = null;
	if (entry.saslPlainPassword != null) {
		saslPlain = SaslPlainCredentials(entry.nick!, entry.saslPlainPassword!);
	}

	return ConnectParams(
		host: entry.host,
		port: entry.port ?? (entry.tls ? 6697 : 6667),
		tls: entry.tls,
		nick: entry.nick!, // TODO: add a fallback
		pass: entry.pass,
		saslPlain: saslPlain,
	);
}

class ClientProvider {
	Map<NetworkModel, ClientController> _controllers = Map();
	StreamController<IRCException> _errorsController = StreamController.broadcast();
	StreamController<NetworkModel> _networkStatesController = StreamController.broadcast();

	final DB _db;
	final NetworkListModel _networkList;
	final BufferListModel _bufferList;
	final BouncerNetworkListModel _bouncerNetworkList;
	final FlutterLocalNotificationsPlugin _notifsPlugin;

	bool _workManagerSyncEnabled = false;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_controllers.values.map((cc) => cc.client));
	Stream<IRCException> get errors => _errorsController.stream;
	Stream<NetworkModel> get networkStates => _networkStatesController.stream;

	ClientProvider({ required DB db, required NetworkListModel networkList, required BufferListModel bufferList, required BouncerNetworkListModel bouncerNetworkList, required FlutterLocalNotificationsPlugin notifsPlugin }) :
		_db = db,
		_networkList = networkList,
		_bufferList = bufferList,
		_bouncerNetworkList = bouncerNetworkList,
		_notifsPlugin = notifsPlugin;

	void add(Client client, NetworkModel network) {
		_controllers[network] = ClientController(this, client, network);
	}

	Client get(NetworkModel network) {
		return _controllers[network]!.client;
	}

	void disconnectAll() {
		for (var cc in _controllers.values) {
			cc.client.disconnect();
		}
		_controllers.clear();
		_bufferList.clear();
	}

	void _setupWorkManagerSync() {
		if (!Platform.isAndroid) {
			return;
		}

		var enable = clients.every((client) => client.caps.enabled.contains('draft/chathistory'));
		if (enable == _workManagerSyncEnabled) {
			return;
		}
		_workManagerSyncEnabled = enable;

		if (!enable) {
			print('Disabling sync work manager');
			Workmanager().cancelByUniqueName('sync');
			return;
		}

		print('Enabling sync work manager');
		Workmanager().registerPeriodicTask('sync', 'sync',
			frequency: Duration(minutes: 15),
			tag: 'sync',
			existingWorkPolicy: ExistingWorkPolicy.keep,
			initialDelay: Duration(minutes: 15),
			constraints: Constraints(
				networkType: NetworkType.connected,
				// TODO: maybe requiresDeviceIdle?
			),
		);
	}
}

class ClientController {
	final ClientProvider _provider;

	final Client _client;
	final NetworkModel _network;

	String? _prevLastDeliveredTime;

	Client get client => _client;
	NetworkModel get network => _network;

	DB get _db => _provider._db;
	NetworkListModel get _networkList => _provider._networkList;
	BufferListModel get _bufferList => _provider._bufferList;
	BouncerNetworkListModel get _bouncerNetworkList => _provider._bouncerNetworkList;
	FlutterLocalNotificationsPlugin get _notifsPlugin => _provider._notifsPlugin;

	ClientController(ClientProvider provider, Client client, NetworkModel network) :
			_provider = provider,
			_client = client,
			_network = network {
		assert(client.state == ClientState.disconnected);

		client.states.listen((state) {
			switch (state) {
			case ClientState.disconnected:
				network.state = NetworkState.offline;
				break;
			case ClientState.connecting:
				_prevLastDeliveredTime = _getLastDeliveredTime();
				network.state = NetworkState.connecting;
				break;
			case ClientState.connected:
				network.state = NetworkState.registering;
				break;
			}
		});

		var messagesSub;
		messagesSub = client.messages.listen((msg) {
			var future = _handleMessage(msg);
			if (future != null) {
				messagesSub.pause();
				future.whenComplete(() => messagesSub.resume());
			}
		});

		var batchesSub;
		batchesSub = client.batches.listen((batch) {
			var future = _handleBatch(batch);
			if (future != null) {
				batchesSub.pause();
				future.whenComplete(() => batchesSub.resume());
			}
		});
	}

	String? _getLastDeliveredTime() {
		var last = null;
		for (var buffer in _bufferList.buffers) {
			if (buffer.network != network || buffer.lastDeliveredTime == null) {
				continue;
			}
			if (last == null || last!.compareTo(buffer.lastDeliveredTime!) < 0) {
				last = buffer.lastDeliveredTime;
			}
		}
		return last;
	}

	Future<void>? _handleMessage(ClientMessage msg) {
		if (msg.isError()) {
			_provider._errorsController.add(IRCException(msg));
		}

		switch (msg.cmd) {
		case RPL_WELCOME:
			_provider._setupWorkManagerSync();
			break;
		case RPL_ISUPPORT:
			network.upstreamName = client.isupport.network;
			if (client.isupport.bouncerNetId != null) {
				network.bouncerNetwork = _bouncerNetworkList.networks[client.isupport.bouncerNetId!];
			} else {
				network.bouncerNetwork = null;
			}
			_bufferList.setCaseMapping(client.isupport.caseMapping);
			break;
		case RPL_ENDOFMOTD:
		case ERR_NOMOTD:
			// These messages are used to indicate the end of the ISUPPORT list

			List<Future> syncFutures = [];

			// Query latest READ status for user targets
			if (client.caps.enabled.contains('soju.im/read')) {
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network && !client.isChannel(buffer.name)) {
						syncFutures.add(client.fetchRead(buffer.name));
					}
				}
			}

			if (_prevLastDeliveredTime != null) {
				var to = msg.tags['time'] ?? formatIRCTime(DateTime.now());
				syncFutures.add(_fetchBacklog(_prevLastDeliveredTime!, to));
			}

			network.state = NetworkState.synchronizing;
			Future.wait(syncFutures).whenComplete(() {
				network.state = NetworkState.online;
			}).ignore();
			break;
		case 'JOIN':
			var channel = msg.params[0];
			if (!client.isMyNick(msg.prefix!.name)) {
				break;
			}
			return _createBuffer(channel);
		case RPL_TOPIC:
			var channel = msg.params[1];
			var topic = msg.params[2];
			_bufferList.get(channel, network)?.topic = topic;
			break;
		case RPL_NOTOPIC:
			var channel = msg.params[1];
			_bufferList.get(channel, network)?.topic = null;
			break;
		case 'TOPIC':
			var channel = msg.params[0];
			String? topic = null;
			if (msg.params.length > 1) {
				topic = msg.params[1];
			}
			_bufferList.get(channel, network)?.topic = topic;
			break;
		case 'PRIVMSG':
		case 'NOTICE':
			var target = msg.params[0];
			if (msg.batchByType('chathistory') != null) {
				break;
			}
			// target can be my own nick for direct messages, "*" for server
			// messages, "$xxx" for server-wide broadcasts
			if (!client.isChannel(target) && !client.isMyNick(msg.prefix!.name)) {
				target = msg.prefix!.name;
			}
			return _handleChatMessages(target, [msg]);
		case 'BOUNCER':
			if (msg.params[0] != 'NETWORK') {
				break;
			}
			if (client.isupport.bouncerNetId != null) {
				break;
			}

			var bouncerNetId = msg.params[1];
			var attrs = msg.params[2] == '*' ? null : parseIRCTags(msg.params[2]);

			var bouncerNetwork = _bouncerNetworkList.networks[bouncerNetId];
			var networkMatches = _networkList.networks.where((network) {
				return network.networkEntry.bouncerId == bouncerNetId;
			});
			NetworkModel? childNetwork = networkMatches.isEmpty ? null : networkMatches.first;

			if (attrs == null) {
				// The bouncer network has been removed

				_bouncerNetworkList.remove(bouncerNetId);

				if (childNetwork == null) {
					break;
				}

				var childClient = _provider.get(childNetwork);
				childClient.disconnect();

				_networkList.remove(childNetwork);
				return _db.deleteNetwork(childNetwork.networkId);
			}

			if (bouncerNetwork != null) {
				// The bouncer network has been updated
				bouncerNetwork.setAttrs(attrs);
				break;
			}

			// The bouncer network has been added

			bouncerNetwork = BouncerNetwork(bouncerNetId, attrs);
			_bouncerNetworkList.add(bouncerNetwork);

			if (childNetwork != null) {
				break;
			}

			var networkEntry = NetworkEntry(server: network.serverId, bouncerId: bouncerNetId);
			return _db.storeNetwork(networkEntry).then((networkEntry) {
				var childClient = Client(client.params.replaceBouncerNetId(bouncerNetId));
				var childNetwork = NetworkModel(network.serverEntry, networkEntry);
				_networkList.add(childNetwork);
				_provider.add(childClient, childNetwork);
				childClient.connect();
			});
		case 'READ':
			var target = msg.params[0];
			var bound = msg.params[1];

			if (bound == '*') {
				break;
			}
			if (!bound.startsWith('timestamp=')) {
				throw FormatException('Invalid READ bound: ${msg}');
			}
			var time = bound.replaceFirst('timestamp=', '');

			var buffer = _bufferList.get(target, network);
			if (buffer == null) {
				break;
			}

			if (buffer.entry.lastReadTime != null && time.compareTo(buffer.entry.lastReadTime!) <= 0) {
				break;
			}

			buffer.entry.lastReadTime = time;
			// TODO: recompute unread count from messages
			buffer.unreadCount = 0;
			return _db.storeBuffer(buffer.entry);
		}
		return null;
	}

	Future<void>? _handleBatch(ClientBatch batch) {
		switch (batch.type) {
		case 'chathistory':
			var target = batch.params[0];
			return _handleChatMessages(target, batch.messages);
		}
	}

	Future<void>? _handleChatMessages(String target, List<IRCMessage> messages) {
		if (messages.length == 0) {
			return null;
		}

		Future<BufferModel> bufFuture;
		if (!client.isChannel(target)) {
			bufFuture = _createBuffer(target);
		} else {
			var buf = _bufferList.get(target, network);
			if (buf == null) {
				return null;
			}
			bufFuture = Future.value(buf);
		}

		return bufFuture.then((buf) {
			var entries = messages.map((msg) => MessageEntry(msg, buf.id)).toList();
			return _db.storeMessages(entries).then((_) {
				String t = entries.first.time;
				List<MessageEntry> unread = [];
				for (var entry in entries) {
					if (buf.messageHistoryLoaded) {
						buf.addMessage(MessageModel(entry: entry));
					}

					if (entry.time.compareTo(t) > 0) {
						t = entry.time;
					}

					if (!client.isMyNick(entry.msg.prefix!.name) && (buf.entry.lastReadTime == null || buf.entry.lastReadTime!.compareTo(entry.time) < 0)) {
						unread.add(entry);
					}
				}

				if (!buf.focused) {
					buf.unreadCount += unread.length;
					_openNotifications(buf, unread);
				} else if (buf.entry.lastReadTime == null || buf.entry.lastReadTime!.compareTo(t) < 0) {
					buf.entry.lastReadTime = t;
					_db.storeBuffer(buf.entry);
					client.setRead(buf.name, buf.entry.lastReadTime!);
				}

				_bufferList.bumpLastDeliveredTime(buf, t);
			});
		});
	}

	void _openNotifications(BufferModel buffer, List<MessageEntry> entries) {
		for (var entry in entries) {
			if (entry.msg.cmd != 'PRIVMSG' && entry.msg.cmd != 'NOTICE') {
				continue;
			}
			if (client.isMyNick(entry.msg.prefix!.name)) {
				continue;
			}
			if (buffer.lastDeliveredTime != null && buffer.lastDeliveredTime!.compareTo(entry.time) >= 0) {
				continue;
			}
			String title, channelId, channelName, channelDescription;
			if (client.isMyNick(entry.msg.params[0])) {
				title = 'New message from ${entry.msg.prefix!.name}';
				channelId = 'privmsg';
				channelName = 'Private messages';
				channelDescription = 'Private messages sent directly to you';
			} else if (findTextHighlight(entry.msg.params[1], client.nick)) {
				title = '${entry.msg.prefix!.name} mentionned you in ${buffer.name}';
				channelId = 'highlight';
				channelName = 'Mentions';
				channelDescription = 'Messages mentionning your nickname in a channel';
			} else {
				continue;
			}
			var body = stripAnsiFormatting(entry.msg.params[1]);
			_notifsPlugin.show(entry.id!, title, body, NotificationDetails(
				linux: LinuxNotificationDetails(
					category: LinuxNotificationCategory.imReceived(),
				),
				android: AndroidNotificationDetails(channelId, channelName,
					channelDescription: channelDescription,
					importance: Importance.high,
					priority: Priority.high,
					category: "msg",
					groupKey: 'fr.emersion.goguma.buffer.${entry.buffer}',
				),
			), payload: 'buffer:${entry.buffer}');
		}
	}

	Future<BufferModel> _createBuffer(String name) {
		var buffer = _bufferList.get(name, network);
		if (buffer != null) {
			return Future.value(buffer);
		}

		var entry = BufferEntry(name: name, network: network.networkId);
		return _db.storeBuffer(entry).then((_) {
			var buffer = BufferModel(entry: entry, network: network);
			_bufferList.add(buffer);
			return buffer;
		});
	}

	Future<void> _fetchBacklog(String from, String to) {
		if (!client.caps.enabled.contains('draft/chathistory')) {
			return Future.value(null);
		}

		var max = client.caps.chatHistory!;
		if (max == 0) {
			max = 1000;
		}

		return client.fetchChatHistoryTargets(from, to).then((targets) {
			return Future.wait(targets.map((target) {
				return client.fetchChatHistoryBetween(target.name, from, to, max);
			}));
		});
	}
}
