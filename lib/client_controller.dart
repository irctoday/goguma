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
import 'prefs.dart';
import 'push.dart';
import 'webpush.dart';

ConnectParams connectParamsFromServerEntry(ServerEntry entry, Prefs prefs) {
	var nick = entry.nick ?? prefs.nickname;

	SaslPlainCredentials? saslPlain;
	if (entry.saslPlainPassword != null) {
		saslPlain = SaslPlainCredentials(entry.saslPlainUsername ?? nick, entry.saslPlainPassword!);
	}

	return ConnectParams(
		host: entry.host,
		port: entry.port ?? (entry.tls ? 6697 : 6667),
		tls: entry.tls,
		nick: nick,
		realname: prefs.realname,
		pass: entry.pass,
		saslPlain: saslPlain,
	);
}

class ClientException extends IrcException {
	final Client client;
	final NetworkModel network;

	ClientException(IrcException base, this.client, this.network) : super(base.msg);
}

/// A data structure which keeps track of IRC clients.
class ClientProvider {
	final Map<NetworkModel, ClientController> _controllers = {};
	final StreamController<ClientException> _errorsController = StreamController.broadcast(sync: true);
	final StreamController<NetworkModel> _networkStatesController = StreamController.broadcast(sync: true);
	final Set<ClientAutoReconnectLock> _autoReconnectLocks = {};

	final DB _db;
	final NetworkListModel _networkList;
	final BufferListModel _bufferList;
	final BouncerNetworkListModel _bouncerNetworkList;
	final NotificationController _notifController;
	final bool _enableSync;
	final PushController? _pushController;

	final ValueNotifier<bool> needBackgroundServicePermissions = ValueNotifier(false);

	bool _workManagerSyncEnabled = false;
	ClientAutoReconnectLock? _backgroundServiceAutoReconnectLock;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_controllers.values.map((cc) => cc.client));
	Stream<ClientException> get errors => _errorsController.stream;
	Stream<NetworkModel> get networkStates => _networkStatesController.stream;

	ClientProvider({
		required DB db,
		required NetworkListModel networkList,
		required BufferListModel bufferList,
		required BouncerNetworkListModel bouncerNetworkList,
		required NotificationController notifController,
		bool enableSync = true,
		PushController? pushController,
	}) :
		_db = db,
		_networkList = networkList,
		_bufferList = bufferList,
		_bouncerNetworkList = bouncerNetworkList,
		_notifController = notifController,
		_enableSync = enableSync,
		_pushController = pushController;

	void add(Client client, NetworkModel network) {
		_controllers[network] = ClientController._(this, client, network);
	}

	Client get(NetworkModel network) {
		return _controllers[network]!.client;
	}

	void disconnect(NetworkModel network) {
		var client = get(network);
		_controllers.remove(network);
		_bufferList.removeByNetwork(network);
		_networkList.remove(network);
		client.dispose();
	}

	void disconnectAll() {
		for (var cc in _controllers.values) {
			cc.client.dispose();
		}
		_controllers.clear();
		_bufferList.clear();
		_networkList.clear();
	}

	void _setupSync() {
		if (!Platform.isAndroid || !_enableSync) {
			return;
		}

		var registeredClients = clients.where((client) => client.registered).toList();
		if (registeredClients.isEmpty) {
			return;
		}

		var useWorkManager = registeredClients.every((client) {
			return client.caps.enabled.contains('draft/chathistory');
		});
		var usePush = _pushController != null && registeredClients.every((client) {
			return client.caps.enabled.contains('soju.im/webpush');
		});
		_setupWorkManagerSync(useWorkManager, usePush);
		_setupBackgroundServiceSync(!useWorkManager);
	}

	void _setupWorkManagerSync(bool enable, bool lowFreq) {
		if (enable == _workManagerSyncEnabled) {
			return;
		}
		_workManagerSyncEnabled = enable;

		if (!enable) {
			print('Disabling sync work manager');
			Workmanager().cancelByUniqueName('sync');
			return;
		}

		var freq = Duration(minutes: 15);
		if (lowFreq) {
			freq = Duration(hours: 4);
		}

		print('Enabling sync work manager (frequency: $freq)');
		Workmanager().registerPeriodicTask('sync', 'sync',
			frequency: freq,
			tag: 'sync',
			existingWorkPolicy: ExistingWorkPolicy.replace,
			initialDelay: freq,
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

	void fetchBufferUser(BufferModel buffer) async {
		var client = get(buffer.network);
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
		_db.storeBuffer(buffer.entry);
	}

	Future<void> fetchChatHistory(BufferModel buffer) async {
		var controller = _controllers[buffer.network]!;
		var client = controller.client;

		String? before;
		if (!buffer.messages.isEmpty) {
			before = buffer.messages.first.entry.time;
		}

		var limit = 100;
		ClientBatch batch;
		if (before != null) {
			batch = await client.fetchChatHistoryBefore(buffer.name, before, limit);
		} else {
			batch = await client.fetchChatHistoryLatest(buffer.name, null, limit);
		}

		await controller._handleChatMessages(buffer.name, batch.messages);
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
	bool _gotInitialBouncerNetworksBatch = false;

	Client get client => _client;
	NetworkModel get network => _network;

	DB get _db => _provider._db;
	NetworkListModel get _networkList => _provider._networkList;
	BufferListModel get _bufferList => _provider._bufferList;
	BouncerNetworkListModel get _bouncerNetworkList => _provider._bouncerNetworkList;
	NotificationController get _notifController => _provider._notifController;

	ClientController._(this._provider, this._client, this._network) {
		assert(client.state == ClientState.disconnected);

		client.autoReconnect = !_provider._autoReconnectLocks.isEmpty;

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
				_gotInitialBouncerNetworksBatch = false;
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
			_provider._errorsController.add(ClientException(IrcException(msg), client, network));
		}

		switch (msg.cmd) {
		case RPL_WELCOME:
			network.nickname = client.nick;
			break;
		case RPL_ISUPPORT:
			network.upstreamName = client.isupport.network;
			if (client.isupport.bouncerNetId != null) {
				network.bouncerNetwork = _bouncerNetworkList.networks[client.isupport.bouncerNetId!];
			} else {
				network.bouncerNetwork = null;
			}
			_bufferList.setCaseMapping(client.isupport.caseMapping);

			network.networkEntry.isupport = client.isupport;
			_db.storeNetwork(network.networkEntry);
			break;
		case 'CAP':
			switch (msg.params[1].toUpperCase()) {
			case 'LS':
			case 'NEW':
			case 'DEL':
				network.networkEntry.caps = client.caps.available;
				_db.storeNetwork(network.networkEntry);
				break;
			}
			break;
		case RPL_ENDOFMOTD:
		case ERR_NOMOTD:
			// These messages are used to indicate the end of the ISUPPORT list
			if (network.state != NetworkState.registering) {
				break;
			}

			_provider._setupSync();

			// Send WHO commands for each recent user buffer
			var now = DateTime.now();
			var limit = const Duration(days: 5);
			List<String> nicks = [];
			for (var buffer in _bufferList.buffers) {
				if (buffer.network != network || !client.isNick(buffer.name)) {
					continue;
				}
				var t = buffer.lastDeliveredTime;
				if (t != null && now.difference(DateTime.parse(t)) > limit) {
					continue;
				}
				_provider.fetchBufferUser(buffer);
				nicks.add(buffer.name);
			}
			if (client.isupport.monitor != null) {
				client.monitor(nicks);
			}

			if (client.caps.enabled.contains('soju.im/webpush')) {
				_setupPushSync();
			}

			List<Future<void>> syncFutures = [];

			// TODO: use a different cap, see:
			// https://github.com/ircv3/ircv3-ideas/issues/91
			if (!client.caps.enabled.contains('soju.im/bouncer-networks')) {
				List<String> channels = [];
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network && client.isChannel(buffer.name)) {
						channels.add(buffer.name);
					}
				}
				syncFutures.add(client.join(channels));
			}

			// Query latest read marker for user targets which have unread
			// messages (another client might have marked these as read).
			if (client.supportsReadMarker()) {
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network && !client.isChannel(buffer.name) && buffer.unreadCount > 0) {
						syncFutures.add(client.fetchReadMarker(buffer.name));
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

			var buffer = _bufferList.get(msg.source.name, network);
			if (buffer != null) {
				buffer.realname = realname;
				_db.storeBuffer(buffer.entry);
			}
			break;
		case RPL_LOGGEDIN:
			var account = msg.params[2];
			network.account = account;
			break;
		case RPL_LOGGEDOUT:
			network.account = null;
			break;
		case RPL_TOPIC:
			var channel = msg.params[1];
			var topic = msg.params[2];
			var buffer = _bufferList.get(channel, network);
			if (buffer != null) {
				buffer.topic = topic;
				_db.storeBuffer(buffer.entry);
			}
			break;
		case RPL_NOTOPIC:
			var channel = msg.params[1];
			var buffer = _bufferList.get(channel, network);
			if (buffer != null) {
				buffer.topic = null;
				_db.storeBuffer(buffer.entry);
			}
			break;
		case 'TOPIC':
			var channel = msg.params[0];
			String? topic;
			if (msg.params.length > 1) {
				topic = msg.params[1];
			}
			var buffer = _bufferList.get(channel, network);
			if (buffer != null) {
				buffer.topic = topic;
				_db.storeBuffer(buffer.entry);
			}
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
		case 'TAGMSG':
			var target = msg.params[0];
			if (msg.batchByType('chathistory') != null) {
				break;
			}
			// target can be my own nick for direct messages, "*" for server
			// messages, "$xxx" for server-wide broadcasts
			if (!client.isChannel(target) && !client.isMyNick(msg.source.name)) {
				var channelCtx = msg.tags['+draft/channel-context'];
				if (channelCtx != null && client.isChannel(channelCtx) && _bufferList.get(channelCtx, network) != null) {
					target = channelCtx;
				} else {
					target = msg.source.name;
				}
			}
			if (msg.cmd == 'TAGMSG') {
				var typing = msg.tags['+typing'];
				if (typing != null && !client.isMyNick(msg.source.name)) {
					_bufferList.get(target, network)?.setTyping(msg.source.name, typing == 'active');
				}
				break;
			}
			return _handleChatMessages(target, [msg]);
		case 'INVITE':
			var nickname = msg.params[0];
			if (client.isMyNick(nickname)) {
				_notifController.showInvite(msg, network);
			}
			break;
		case 'BATCH':
			if (msg is ClientEndOfBatch) {
				var batch = msg.child;
				if (batch.type == 'soju.im/bouncer-networks' && client.isupport.bouncerNetId == null) {
					return _handleBouncerNetworksBatch(batch);
				}
			}
			break;
		case 'BOUNCER':
			if (msg.params[0] != 'NETWORK') {
				break;
			}
			if (client.isupport.bouncerNetId != null) {
				break;
			}
			// If the message is part of a batch, we'll process it when we
			// reach the end of the batch
			if (msg.batchByType('soju.im/bouncer-networks') != null) {
				break;
			}
			return _handleBouncerNetwork(msg);
		case 'MARKREAD':
			var target = msg.params[0];
			var bound = msg.params[1];

			if (bound == '*') {
				break;
			}
			if (!bound.startsWith('timestamp=')) {
				throw FormatException('Invalid MARKREAD bound: $msg');
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
		if (buf == null && !client.isChannel(target)) {
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
			client.setReadMarker(buf.name, buf.entry.lastReadTime!);
		}

		_bufferList.bumpLastDeliveredTime(buf, t);

		if (isNewBuffer && client.isNick(buf.name)) {
			_provider.fetchBufferUser(buf);
		}
	}

	Future<void> _handleBouncerNetworksBatch(ClientBatch batch) async {
		for (var msg in batch.messages) {
			await _handleBouncerNetwork(msg);
		}

		if (_gotInitialBouncerNetworksBatch) {
			return;
		}
		_gotInitialBouncerNetworksBatch = true;

		// Delete stale child networks

		List<NetworkModel> stale = [];
		for (var childNetwork in _networkList.networks) {
			if (childNetwork.networkEntry.bouncerId == null) {
				continue;
			}
			if (childNetwork.serverEntry.id != network.serverEntry.id) {
				continue;
			}

			var bouncerNetwork = _bouncerNetworkList.networks[childNetwork.networkEntry.bouncerId];
			if (bouncerNetwork != null) {
				continue;
			}

			stale.add(childNetwork);
		}

		for (var childNetwork in stale) {
			_provider.disconnect(childNetwork);
			await _db.deleteNetwork(childNetwork.networkId);
		}
	}

	Future<void> _handleBouncerNetwork(ClientMessage msg) async {
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
				return;
			}

			_provider.disconnect(childNetwork);

			await _db.deleteNetwork(childNetwork.networkId);
			return;
		}

		if (bouncerNetwork != null) {
			// The bouncer network has been updated
			bouncerNetwork.setAttrs(attrs);
			if (childNetwork != null) {
				childNetwork.networkEntry.bouncerName = attrs['name'];
				childNetwork.networkEntry.bouncerUri = _uriFromBouncerNetworkModel(bouncerNetwork);
				await _db.storeNetwork(childNetwork.networkEntry);
			}
			return;
		}

		// The bouncer network has been added

		bouncerNetwork = BouncerNetworkModel(bouncerNetId, attrs);
		_bouncerNetworkList.add(bouncerNetwork);

		if (childNetwork != null) {
			// This is the first time we see this bouncer network for this
			// session, but we've saved it in the DB
			childNetwork.bouncerNetwork = bouncerNetwork;
			childNetwork.networkEntry.bouncerUri = _uriFromBouncerNetworkModel(bouncerNetwork);
			await _db.storeNetwork(childNetwork.networkEntry);
			return;
		}

		var networkEntry = NetworkEntry(
			server: network.serverId,
			bouncerId: bouncerNetId,
			bouncerUri: _uriFromBouncerNetworkModel(bouncerNetwork),
		);
		await _db.storeNetwork(networkEntry).then((networkEntry) {
			var childClient = Client(client.params.apply(bouncerNetId: bouncerNetId));
			var childNetwork = NetworkModel(network.serverEntry, networkEntry, childClient.nick, childClient.realname);
			_networkList.add(childNetwork);
			_provider.add(childClient, childNetwork);
			childClient.connect();
		});
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
		if (_isPushSupported()) {
			// TODO: handle the case where push is supported but the
			// subscription failed
			return;
		}
		if (buffer.muted) {
			return;
		}

		var isChannel = client.isChannel(buffer.name);

		entries = entries.where((entry) {
			if (buffer.lastDeliveredTime != null && buffer.lastDeliveredTime!.compareTo(entry.time) >= 0) {
				return false;
			}
			return _shouldNotifyMessage(entry, isChannel);
		}).toList();
		if (entries.isEmpty) {
			return;
		}

		if (isChannel) {
			await _notifController.showHighlight(entries, buffer);
		} else {
			await _notifController.showDirectMessage(entries, buffer);
		}
	}

	bool _shouldNotifyMessage(MessageEntry entry, bool isChannel) {
		if (entry.msg.cmd != 'PRIVMSG' && entry.msg.cmd != 'NOTICE') {
			return false;
		}
		if (client.isMyNick(entry.msg.source!.name)) {
			return false;
		}
		if (isChannel && !findTextHighlight(entry.msg.params[1], client.nick)) {
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

		var max = client.caps.available.chatHistory!;
		if (max == 0) {
			max = 1000;
		}

		var targets = await client.fetchChatHistoryTargets(from, to);
		await Future.wait(targets.map((target) async {
			// Query read marker if this is a user (ie, we haven't received the
			// read marker as part of an auto-JOIN) and we haven't queried it
			// already (we don't have an opened buffer or the buffer has no
			// unread messages).
			Future<void>? readMarkerFuture;
			var buffer = _bufferList.get(target.name, network);
			if (client.supportsReadMarker() && !client.isChannel(target.name) && (buffer == null || buffer.unreadCount == 0)) {
				readMarkerFuture = client.fetchReadMarker(target.name);
			}

			var batch = await client.fetchChatHistoryBetween(target.name, from, to, max);
			await readMarkerFuture;
			await _handleChatMessages(target.name, batch.messages);
		}));
	}

	void _setupPushSync() async {
		if (!_isPushSupported()) {
			return;
		}

		print('Enabling push synchronization');

		var subs = await _db.listWebPushSubscriptions();
		var vapidKey = client.isupport.vapid;
		var pushController = _provider._pushController!;

		WebPushSubscriptionEntry? oldSub;
		for (var sub in subs) {
			if (sub.network == network.networkId) {
				oldSub = sub;
				break;
			}
		}

		if (oldSub != null) {
			// TODO: also unregister on Firebase token change

			if (oldSub.vapidKey == vapidKey) {
				// Refresh our subscription
				try {
					await client.webPushRegister(oldSub.endpoint, oldSub.getPublicKeys());
					return;
				} on Exception catch (err) {
					// Maybe the subscription expired
					print('Failed to refresh old push subscription: $err');
					print('Trying to register with a fresh subscription...');
				}
			}

			try {
				await pushController.deleteSubscription(network.networkEntry, PushSubscription(
					endpoint: oldSub.endpoint,
					tag: oldSub.tag,
				));
			} on Exception catch (err) {
				print('Failed to delete old push subscription: $err');
			}
			await client.webPushUnregister(oldSub.endpoint);
			await _db.deleteWebPushSubscription(oldSub.id!);
		}

		var details = await pushController.createSubscription(network.networkEntry, vapidKey);

		try {
			var webPush = await WebPush.generate();
			var config = await webPush.exportPrivateKeys();
			var newSub = WebPushSubscriptionEntry(
				network: network.networkId,
				endpoint: details.endpoint,
				tag: details.tag,
				vapidKey: vapidKey,
				p256dhPrivateKey: config.p256dhPrivateKey,
				p256dhPublicKey: config.p256dhPublicKey,
				authKey: config.authKey,
			);
			await _db.storeWebPushSubscription(newSub);

			try {
				// This may result in a Web Push notification being delivered, so
				// we need to do this last
				await client.webPushRegister(details.endpoint, config.getPublicKeys());
			} on Object {
				try {
					await _db.deleteWebPushSubscription(newSub.id!);
				} on Exception catch (err) {
					print('Failed to delete Web Push subscription from DB after error: $err');
				}
				rethrow;
			}
		} on Object {
			try {
				await pushController.deleteSubscription(network.networkEntry, details);
			} on Exception catch (err) {
				print('Failed to delete push subscription after error: $err');
			}
			rethrow;
		}
	}

	bool _isPushSupported() {
		return client.caps.enabled.contains('soju.im/webpush') && _provider._pushController != null;
	}
}

IrcUri? _uriFromBouncerNetworkModel(BouncerNetworkModel bouncerNetwork) {
	if (bouncerNetwork.host == null) {
		return null;
	}

	// TODO: also include bouncerNetwork.tls
	return IrcUri(
		host: bouncerNetwork.host!,
		port: bouncerNetwork.port,
	);
}
