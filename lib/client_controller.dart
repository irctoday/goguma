import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:workmanager/workmanager.dart';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';
import 'notification_controller.dart';

ConnectParams connectParamsFromServerEntry(ServerEntry entry, String defaultNickname) {
	SaslPlainCredentials? saslPlain;
	if (entry.saslPlainPassword != null) {
		saslPlain = SaslPlainCredentials(entry.nick!, entry.saslPlainPassword!);
	}

	return ConnectParams(
		host: entry.host,
		port: entry.port ?? (entry.tls ? 6697 : 6667),
		tls: entry.tls,
		nick: entry.nick ?? defaultNickname,
		pass: entry.pass,
		saslPlain: saslPlain,
	);
}

/// A data structure which keeps track of IRC clients.
class ClientProvider {
	final Map<NetworkModel, ClientController> _controllers = {};
	final StreamController<IrcException> _errorsController = StreamController.broadcast(sync: true);
	final StreamController<NetworkModel> _networkStatesController = StreamController.broadcast(sync: true);
	final Set<ClientAutoReconnectLock> _autoReconnectLocks = {};

	final DB _db;
	final NetworkListModel _networkList;
	final BufferListModel _bufferList;
	final BouncerNetworkListModel _bouncerNetworkList;
	final NotificationController _notifController;

	final ValueNotifier<bool> needBackgroundServicePermissions = ValueNotifier(false);

	bool _workManagerSyncEnabled = false;
	ClientAutoReconnectLock? _backgroundServiceAutoReconnectLock;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_controllers.values.map((cc) => cc.client));
	Stream<IrcException> get errors => _errorsController.stream;
	Stream<NetworkModel> get networkStates => _networkStatesController.stream;

	ClientProvider({ required DB db, required NetworkListModel networkList, required BufferListModel bufferList, required BouncerNetworkListModel bouncerNetworkList, required NotificationController notifController }) :
		_db = db,
		_networkList = networkList,
		_bufferList = bufferList,
		_bouncerNetworkList = bouncerNetworkList,
		_notifController = notifController;

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

	void _setupSync() {
		if (!Platform.isAndroid) {
			return;
		}

		if (clients.where((client) => client.state == ClientState.connected).isEmpty) {
			return;
		}

		var useWorkManager = clients.every((client) {
			return client.caps.enabled.contains('draft/chathistory') || client.state != ClientState.connected;
		});
		_setupWorkManagerSync(useWorkManager);
		_setupBackgroundServiceSync(!useWorkManager);
	}

	void _setupWorkManagerSync(bool enable) {
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
			constraints: Constraints(networkType: NetworkType.connected),
		);
	}

	void _setupBackgroundServiceSync(bool enable) async {
		if (!enable) {
			needBackgroundServicePermissions.value = false;
			_backgroundServiceAutoReconnectLock?.release();
			_backgroundServiceAutoReconnectLock = null;
			if (FlutterBackground.isBackgroundExecutionEnabled) {
				print('Disabling sync background service');
				FlutterBackground.disableBackgroundExecution();
			}
			return;
		}

		if (FlutterBackground.isBackgroundExecutionEnabled) {
			_backgroundServiceAutoReconnectLock?.release();
			_backgroundServiceAutoReconnectLock = ClientAutoReconnectLock.acquire(this);
			return;
		}

		var hasPermissions = await FlutterBackground.hasPermissions;
		needBackgroundServicePermissions.value = !hasPermissions;
		if (hasPermissions) {
			askBackgroundServicePermissions();
		}
	}

	void askBackgroundServicePermissions() async {
		print('Enabling sync background service');

		var success = await FlutterBackground.initialize(androidConfig: FlutterBackgroundAndroidConfig(
			notificationTitle: 'Goguma connection',
			notificationText: 'Goguma is running in the background',
			notificationIcon: AndroidResource(name: 'ic_stat_name'),
			enableWifiLock: true,
		));
		needBackgroundServicePermissions.value = !success;
		if (!success) {
			print('Failed to obtain permissions for background service');
			return;
		}

		success = await FlutterBackground.enableBackgroundExecution();
		if (success) {
			print('Enabled sync background service');
			_backgroundServiceAutoReconnectLock?.release();
			_backgroundServiceAutoReconnectLock = ClientAutoReconnectLock.acquire(this);
		} else {
			print('Failed to enable sync background service');
		}
	}
}

/// A lock which enables automatic reconnection when enabled.
class ClientAutoReconnectLock {
	final ClientProvider _provider;

	ClientAutoReconnectLock.acquire(this._provider) {
		_provider._autoReconnectLocks.add(this);
		_updateAutoReconnect();
	}

	void release() {
		_provider._autoReconnectLocks.remove(this);
		_updateAutoReconnect();
	}

	void _updateAutoReconnect() {
		for (var client in _provider.clients) {
			client.autoReconnect = !_provider._autoReconnectLocks.isEmpty;
		}
	}
}

/// A helper which integrates a [Client] with app models.
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
	NotificationController get _notifController => _provider._notifController;

	ClientController(ClientProvider provider, Client client, NetworkModel network) :
			_provider = provider,
			_client = client,
			_network = network {
		assert(client.state == ClientState.disconnected);

		client.autoReconnect = !provider._autoReconnectLocks.isEmpty;

		client.states.listen((state) {
			switch (state) {
			case ClientState.disconnected:
				network.state = NetworkState.offline;
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network) {
						buffer.joined = false;
						buffer.online = null;
						buffer.away = null;
					}
				}
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

		late StreamSubscription<void> messagesSub;
		messagesSub = client.messages.listen((msg) {
			var future = _handleMessage(msg);
			if (future != null) {
				messagesSub.pause();
				future.whenComplete(() => messagesSub.resume());
			}
		});
	}

	String? _getLastDeliveredTime() {
		String? last;
		for (var buffer in _bufferList.buffers) {
			if (buffer.network != network || buffer.lastDeliveredTime == null) {
				continue;
			}
			if (last == null || last.compareTo(buffer.lastDeliveredTime!) < 0) {
				last = buffer.lastDeliveredTime;
			}
		}
		return last;
	}

	Future<void>? _handleMessage(ClientMessage msg) {
		if (msg.isError()) {
			_provider._errorsController.add(IrcException(msg));
		}

		switch (msg.cmd) {
		case RPL_WELCOME:
			_provider._setupSync();
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

			// Send WHO commands for each user buffer we don't know the real
			// name of
			List<String> l = [];
			for (var buffer in _bufferList.buffers) {
				if (buffer.network != network || !client.isNick(buffer.name)) {
					continue;
				}
				if (buffer.realname == null) {
					fetchBufferUser(client, buffer);
				}
				l.add(buffer.name);
			}
			if (client.isupport.monitor != null) {
				client.monitor(l);
			}

			List<Future<void>> syncFutures = [];

			// Query latest READ status for user targets
			if (client.caps.enabled.contains('soju.im/read')) {
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network && !client.isChannel(buffer.name)) {
						syncFutures.add(client.fetchRead(buffer.name));
					}
				}
			}

			if (_prevLastDeliveredTime != null) {
				var to = msg.tags['time'] ?? formatIrcTime(DateTime.now());
				syncFutures.add(_fetchBacklog(_prevLastDeliveredTime!, to));
			}

			network.state = NetworkState.synchronizing;
			Future.wait(syncFutures).whenComplete(() {
				network.state = NetworkState.online;
			}).ignore();
			break;
		case 'JOIN':
			var channel = msg.params[0];
			if (client.isMyNick(msg.source.name)) {
				return _createBuffer(channel).then((buffer) {
					buffer.joined = true;
				});
			} else {
				_bufferList.get(channel, network)?.members?.set(msg.source.name, '');
				break;
			}
		case 'PART':
			var channel = msg.params[0];
			var buffer = _bufferList.get(channel, network);
			if (client.isMyNick(msg.source.name)) {
				buffer?.joined = false;
				buffer?.members = null;
			} else {
				buffer?.members?.remove(msg.source.name);
			}
			break;
		case 'QUIT':
			for (var buffer in _bufferList.buffers) {
				if (buffer.network == network) {
					buffer.members?.remove(msg.source.name);
				}
			}
			break;
		case 'KICK':
			var channel = msg.params[0];
			var nick = msg.params[1];
			var buffer = _bufferList.get(channel, network);
			if (client.isMyNick(nick)) {
				buffer?.joined = false;
				buffer?.members = null;
			} else {
				buffer?.members?.remove(nick);
			}
			break;
		case 'MODE':
			var target = msg.params[0];

			if (!client.isChannel(target)) {
				break; // TODO: handle user mode changes too
			}

			var buffer = _bufferList.get(target, network);
			if (buffer == null) {
				break;
			}

			var updates = ChanModeUpdate.parse(msg, client.isupport);
			for (var update in updates) {
				_handleChanModeUpdate(buffer, update);
			}
			break;
		case 'AWAY':
			var away = msg.params.length > 0;
			_bufferList.get(msg.source.name, network)?.away = away;
			break;
		case 'NICK':
			var cm = client.isupport.caseMapping;
			if (cm(network.nickname) == cm(msg.source.name)) {
				network.nickname = msg.params[0];
			}

			for (var buffer in _bufferList.buffers) {
				if (buffer.network == network && buffer.members?.members.containsKey(msg.source.name) == true) {
					buffer.members!.set(msg.params[0], buffer.members!.members[msg.source.name]!);
					buffer.members!.remove(msg.source.name);
				}
			}
			break;
		case 'SETNAME':
			var realname = msg.params[0];

			if (client.isMyNick(msg.source.name)) {
				network.realname = realname;
			}

			_bufferList.get(msg.source.name, network)?.realname = realname;
			break;
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
			String? topic;
			if (msg.params.length > 1) {
				topic = msg.params[1];
			}
			_bufferList.get(channel, network)?.topic = topic;
			break;
		case RPL_ENDOFNAMES:
			var channel = msg.params[1];
			var endOfNames = msg as ClientEndOfNames;
			var names = endOfNames.names;
			var members = MemberListModel(client.isupport.caseMapping);
			for (var member in names.members) {
				members.set(member.nickname, member.prefix);
			}
			_bufferList.get(channel, network)?.members = members;
			break;
		case 'PRIVMSG':
		case 'NOTICE':
			var target = msg.params[0];
			if (msg.batchByType('chathistory') != null) {
				break;
			}
			// target can be my own nick for direct messages, "*" for server
			// messages, "$xxx" for server-wide broadcasts
			if (!client.isChannel(target) && !client.isMyNick(msg.source.name)) {
				target = msg.source.name;
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
			var attrs = msg.params[2] == '*' ? null : parseIrcTags(msg.params[2]);

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

			bouncerNetwork = BouncerNetworkModel(bouncerNetId, attrs);
			_bouncerNetworkList.add(bouncerNetwork);

			if (childNetwork != null) {
				childNetwork.bouncerNetwork = bouncerNetwork;
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
				throw FormatException('Invalid READ bound: $msg');
			}
			var time = bound.replaceFirst('timestamp=', '');

			var buffer = _bufferList.get(target, network);
			if (buffer == null) {
				break;
			}

			if (buffer.entry.lastReadTime != null && time.compareTo(buffer.entry.lastReadTime!) <= 0) {
				break;
			}

			_notifController.cancelAllWithBuffer(buffer);

			buffer.entry.lastReadTime = time;
			// TODO: recompute unread count from messages
			buffer.unreadCount = 0;
			return _db.storeBuffer(buffer.entry);
		case RPL_MONONLINE:
		case RPL_MONOFFLINE:
			var online = msg.cmd == RPL_MONONLINE;
			var targets = msg.params[1].split(',');
			for (var raw in targets) {
				var source = IrcSource.parse(raw);
				_bufferList.get(source.name, network)?.online = online;
			}
			break;
		default:
			if (msg is ClientEndOfBatch) {
				return _handleBatch(msg.child);
			}
		}
		return null;
	}

	Future<void>? _handleBatch(ClientBatch batch) {
		switch (batch.type) {
		case 'chathistory':
			var target = batch.params[0];
			return _handleChatMessages(target, batch.messages);
		}
		return null;
	}

	Future<void> _handleChatMessages(String target, List<ClientMessage> messages) async {
		if (messages.length == 0) {
			return;
		}

		var isHistory = messages.first.batchByType('chathistory') != null;

		var buf = _bufferList.get(target, network);
		var isNewBuffer = false;
		if (!client.isChannel(target)) {
			isNewBuffer = true;
			buf = await _createBuffer(target);
		}
		if (buf == null) {
			return;
		}

		var entries = messages.map((msg) => MessageEntry(msg, buf!.id)).toList();
		await _db.storeMessages(entries);
		if (buf.messageHistoryLoaded) {
			buf.addMessages(entries.map((entry) => MessageModel(entry: entry)), append: !isHistory);
		}

		String t = entries.first.time;
		List<MessageEntry> unread = [];
		for (var entry in entries) {
			if (entry.time.compareTo(t) > 0) {
				t = entry.time;
			}

			if (!client.isMyNick(entry.msg.source!.name) && (buf.entry.lastReadTime == null || buf.entry.lastReadTime!.compareTo(entry.time) < 0)) {
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

		if (isNewBuffer && client.isNick(buf.name)) {
			fetchBufferUser(client, buf);
		}
	}

	void _handleChanModeUpdate(BufferModel buffer, ChanModeUpdate update) {
		if (buffer.members == null) {
			return;
		}

		var nick = update.arg;
		if (nick == null) {
			return;
		}
		var prefix = buffer.members!.members[nick];
		if (prefix == null) {
			return;
		}
		prefix = updateIrcMembership(prefix, update, client.isupport);
		buffer.members!.set(nick, prefix);
	}

	void _openNotifications(BufferModel buffer, List<MessageEntry> entries) async {
		if (buffer.muted) {
			return;
		}
		var needsNotification = entries.any((entry) {
			if (buffer.lastDeliveredTime != null && buffer.lastDeliveredTime!.compareTo(entry.time) >= 0) {
				return false;
			}
			return _shouldNotifyMessage(entry);
		});
		if (!needsNotification) {
			return;
		}

		var unread = await _db.listUnreadMessages(buffer.id);
		var notifyEntries = unread.where(_shouldNotifyMessage).toList();

		if (notifyEntries.isEmpty) {
			return;
		}

		if (client.isChannel(buffer.name)) {
			_notifController.showHighlight(notifyEntries, buffer);
		} else {
			_notifController.showDirectMessage(notifyEntries, buffer);
		}
	}

	bool _shouldNotifyMessage(MessageEntry entry) {
		if (entry.msg.cmd != 'PRIVMSG' && entry.msg.cmd != 'NOTICE') {
			return false;
		}
		if (client.isMyNick(entry.msg.source!.name)) {
			return false;
		}
		if (client.isChannel(entry.msg.params[0]) && !findTextHighlight(entry.msg.params[1], client.nick)) {
			return false;
		}
		return true;
	}

	Future<BufferModel> _createBuffer(String name) async {
		var buffer = _bufferList.get(name, network);
		if (buffer != null) {
			return buffer;
		}

		var entry = BufferEntry(name: name, network: network.networkId);
		await _db.storeBuffer(entry);
		buffer = BufferModel(entry: entry, network: network);
		_bufferList.add(buffer);
		return buffer;
	}

	Future<void> _fetchBacklog(String from, String to) async {
		if (!client.caps.enabled.contains('draft/chathistory')) {
			return;
		}

		var max = client.caps.chatHistory!;
		if (max == 0) {
			max = 1000;
		}

		var targets = await client.fetchChatHistoryTargets(from, to);
		await Future.wait(targets.map((target) async {
			await client.fetchChatHistoryBetween(target.name, from, to, max);
		}));
	}
}

void fetchBufferUser(Client client, BufferModel buffer) async {
	List<WhoReply> replies;
	try {
		replies = await client.who(buffer.name);
	} on Exception catch (err) {
		print('Failed to fetch WHO ${buffer.name}: $err');
		return;
	}

	if (replies.length == 0) {
		return; // User is offline
	} else if (replies.length != 1) {
		throw FormatException('Expected a single WHO reply, got ${replies.length}');
	}

	var reply = replies[0];
	buffer.realname = reply.realname;
	buffer.away = reply.away;
}
