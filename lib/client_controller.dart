import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
import 'logging.dart';
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
		pinnedCertSHA1: entry.pinnedCertSHA1
	);
}

class ClientException extends IrcException {
	final Client client;
	final NetworkModel network;

	ClientException(IrcException base, this.client, this.network) : super(base.msg);
}

class ClientNotice {
	final List<ClientMessage> msgs;
	final String target;
	final Client client;
	final NetworkModel network;

	const ClientNotice(this.msgs, this.target, this.client, this.network);
}

class BackgroundSyncStatus {
	final bool isUnavailable;
	final bool needServicePermissions;

	const BackgroundSyncStatus({
		this.isUnavailable = false,
		this.needServicePermissions = false,
	});
}

/// A data structure which keeps track of IRC clients.
class ClientProvider {
	final Map<NetworkModel, ClientController> _controllers = {};
	final StreamController<ClientException> _errorsController = StreamController.broadcast(sync: true);
	final StreamController<ClientNotice> _noticesController = StreamController.broadcast(sync: true);
	final StreamController<NetworkModel> _networkStatesController = StreamController.broadcast(sync: true);
	final Set<ClientAutoReconnectLock> _autoReconnectLocks = {};

	final DB _db;
	final NetworkListModel _networkList;
	final BufferListModel _bufferList;
	final BouncerNetworkListModel _bouncerNetworkList;
	final NotificationController _notifController;
	final bool _enableSync;
	final PushController? _pushController;

	final ValueNotifier<BackgroundSyncStatus> backgroundSyncStatus = ValueNotifier(BackgroundSyncStatus());

	bool _workManagerSyncEnabled = false;
	ClientAutoReconnectLock? _backgroundServiceAutoReconnectLock;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_controllers.values.map((cc) => cc.client));
	Stream<ClientException> get errors => _errorsController.stream;
	Stream<ClientNotice> get notices => _noticesController.stream;
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

	// Takes ownership of the Client.
	void add(Client client, NetworkModel network) {
		_controllers[network] = ClientController._(this, client, network);
	}

	Client get(NetworkModel network) {
		return _controllers[network]!.client;
	}

	void remove(NetworkModel network) {
		var client = get(network);
		_controllers.remove(network);
		_bufferList.removeByNetwork(network);
		_networkList.remove(network);
		client.dispose();
	}

	void clear() {
		for (var cc in _controllers.values) {
			cc.client.dispose();
		}
		_controllers.clear();
		_bufferList.clear();
		_networkList.clear();
	}

	void disconnectAll() {
		if (!_autoReconnectLocks.isEmpty) {
			return;
		}
		for (var client in clients) {
			client.disconnect();
		}
	}

	void _setupSync() {
		if (!_enableSync) {
			return;
		}

		var registeredClients = clients.where((client) => client.registered).toList();
		if (registeredClients.isEmpty) {
			return;
		}

		var hasChatHistory = registeredClients.every((client) {
			return client.caps.available.containsKey('draft/chathistory');
		});
		var hasWebPush = registeredClients.every((client) {
			return client.caps.available.containsKey('soju.im/webpush');
		});

		var useWorkManager = Platform.isAndroid && hasChatHistory;
		var usePush = _pushController != null && hasWebPush;
		_setupWorkManagerSync(useWorkManager, usePush);
		_setupBackgroundServiceSync(!useWorkManager);

		_askNotificationPermissions();

		if (Platform.isIOS && !hasChatHistory) {
			// Background service is unavailable on iOS
			backgroundSyncStatus.value = BackgroundSyncStatus(
				isUnavailable: true,
			);
		}
	}

	void _setupWorkManagerSync(bool enable, bool lowFreq) {
		if (enable == _workManagerSyncEnabled) {
			return;
		}
		_workManagerSyncEnabled = enable;

		if (!enable) {
			log.print('Disabling sync work manager');
			Workmanager().cancelByUniqueName('sync');
			return;
		}

		var freq = Duration(minutes: 15);
		if (lowFreq) {
			freq = Duration(hours: 4);
		}

		log.print('Enabling sync work manager (frequency: $freq)');
		Workmanager().registerPeriodicTask('sync', 'sync',
			frequency: freq,
			tag: 'sync',
			existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
			initialDelay: freq,
			constraints: Constraints(networkType: NetworkType.connected),
		);
	}

	void _setupBackgroundServiceSync(bool enable) async {
		if (!Platform.isAndroid) {
			return;
		}

		if (!enable) {
			backgroundSyncStatus.value = BackgroundSyncStatus();
			_backgroundServiceAutoReconnectLock?.release();
			_backgroundServiceAutoReconnectLock = null;
			if (FlutterBackground.isBackgroundExecutionEnabled) {
				log.print('Disabling sync background service');
				unawaited(FlutterBackground.disableBackgroundExecution());
			}
			return;
		}

		if (FlutterBackground.isBackgroundExecutionEnabled) {
			_backgroundServiceAutoReconnectLock?.release();
			_backgroundServiceAutoReconnectLock = ClientAutoReconnectLock.acquire(this);
			return;
		}

		var hasPermissions = await FlutterBackground.hasPermissions;
		backgroundSyncStatus.value = BackgroundSyncStatus(
			needServicePermissions: !hasPermissions,
		);
		if (hasPermissions) {
			askBackgroundServicePermissions();
		}
	}

	void askBackgroundServicePermissions() async {
		log.print('Enabling sync background service');

		var success = await FlutterBackground.initialize(androidConfig: FlutterBackgroundAndroidConfig(
			notificationTitle: 'Goguma connection',
			notificationText: 'Goguma is running in the background',
			notificationIcon: AndroidResource(name: 'ic_stat_name'),
			enableWifiLock: true,
		));
		backgroundSyncStatus.value = BackgroundSyncStatus(
			needServicePermissions: !success,
		);
		if (!success) {
			log.print('Failed to obtain permissions for background service');
			return;
		}

		try {
			success = await FlutterBackground.enableBackgroundExecution();
		} on Exception catch (err) {
			log.print('Failed to enable sync background service', error: err);
			success = false;
		}
		if (success) {
			log.print('Enabled sync background service');
			_backgroundServiceAutoReconnectLock?.release();
			_backgroundServiceAutoReconnectLock = ClientAutoReconnectLock.acquire(this);
		} else {
			log.print('Failed to enable sync background service');
		}
	}

	void _askNotificationPermissions() async {
		var state = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
		if (state == AppLifecycleState.detached) {
			return;
		}

		var plugin = FlutterLocalNotificationsPlugin();
		var androidPlugin = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
		if (androidPlugin == null) {
			return;
		}

		try {
			await androidPlugin.requestNotificationsPermission();
		} on Exception catch (err) {
			log.print('Failed to request notifications permission', error: err);
		}
	}

	void fetchBufferUser(BufferModel buffer) async {
		var client = get(buffer.network);
		List<WhoReply> replies;
		try {
			replies = await client.who(buffer.name);
		} on Exception catch (err) {
			log.print('Failed to fetch WHO ${buffer.name}', error: err);
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
		unawaited(_db.storeBuffer(buffer.entry));

		buffer.network.users.updateUser(UserModel(
			nickname: reply.nickname,
			realname: reply.realname,
		));
	}

	Future<void> fetchChatHistory(BufferModel buffer, {String? around}) async {
		var controller = _controllers[buffer.network]!;
		var client = controller.client;

    var limit = 100;

		String? before;
    MessageEntry? beforeMessage;
    int? beforeLimit;
		if (!buffer.messages.isEmpty) {
      beforeMessage = buffer.messages.first.entry;
      beforeLimit = limit;
      before = beforeMessage.time;
		}

		ClientBatch batch;
    if (around != null) {
      batch = await client.fetchChatHistoryAround(buffer.name, around, limit);
    } else if (before != null) {
			batch = await client.fetchChatHistoryBefore(buffer.name, before, limit);
		} else {
			batch = await client.fetchChatHistoryLatest(buffer.name, null, limit);
		}

		await controller._handleChatMessages(buffer.name, batch.messages, beforeMessage: beforeMessage, beforeLimit: beforeLimit);
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
				// TODO: drop _getLastDeliveredTime() in a future release
				_prevLastDeliveredTime = _network.networkEntry.lastDeliveredTime ?? _getLastDeliveredTime();
				network.state = NetworkState.connecting;
				break;
			case ClientState.connected:
				network.state = NetworkState.registering;
				network.connectError = null;
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

		client.connectErrors.listen((err) {
			network.connectError = err.toString();
		});

		client.isupportStream.listen((isupport) {
			network.upstreamName = isupport.network;
			if (isupport.bouncerNetId != null) {
				network.bouncerNetwork = _bouncerNetworkList.networks[isupport.bouncerNetId!];
			} else {
				network.bouncerNetwork = null;
			}
			setCaseMapping(_bufferList, network, isupport.caseMapping);

			network.networkEntry.isupport = isupport;
			_db.storeNetwork(network.networkEntry);
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

			if (client.caps.available.containsKey('draft/metadata-2')) {
				client.send(IrcMessage('METADATA', ['*', 'SUB', 'soju.im/pinned', 'soju.im/muted']));
			}

			// Send WHO commands for each recent user buffer
			var now = DateTime.now();
			var limit = const Duration(days: 5);
			List<String> nicks = [];
			for (var buffer in _bufferList.buffers) {
				if (buffer.network != network || !client.isNick(buffer.name) || buffer.archived) {
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

			List<Future<void>> syncFutures = [];

			if (client.caps.enabled.contains('soju.im/webpush')) {
				syncFutures.add(_setupPushSync());
			}

			// TODO: use a different cap, see:
			// https://github.com/ircv3/ircv3-ideas/issues/91
			if (!client.caps.enabled.contains('soju.im/bouncer-networks')) {
				List<String> channels = [];
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network && client.isChannel(buffer.name) && !buffer.archived) {
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
        // TODO: what is last delivered time was bumped through a SEARCH?
				var to = msg.tags['time'] ?? formatIrcTime(DateTime.now());
				syncFutures.add(_fetchBacklog(_prevLastDeliveredTime!, to));
			}

			network.state = NetworkState.synchronizing;
			() async {
				try {
					await Future.wait(syncFutures);
				} on Exception catch (err) {
					log.print('Failed to synchronize network', error: err);
				} finally {
					network.state = NetworkState.online;
				}
			}();
			break;
		case 'JOIN':
			var channel = msg.params[0];
			// TODO: drop the length check once this is widely deployed:
			// https://codeberg.org/emersion/soju/commit/a2a4181440824b29bf2b317cbcf77a527f54e10c
			if (client.caps.enabled.contains('extended-join') && msg.params.length >= 3) {
				var realname = msg.params[2];
				network.users.updateUser(UserModel(
					nickname: msg.source.name,
					realname: realname,
				));
			}

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

			network.users.removeUser(msg.source.name);
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
			var newNickname = msg.params[0];

			if (client.isupport.caseMapping.equals(network.nickname, msg.source.name)) {
				network.nickname = newNickname;
			}

			for (var buffer in _bufferList.buffers) {
				if (buffer.network == network && buffer.members?.members.containsKey(msg.source.name) == true) {
					buffer.members!.set(newNickname, buffer.members!.members[msg.source.name]!);
					buffer.members!.remove(msg.source.name);
				}
			}

			network.users.updateNickname(msg.source.name, newNickname);
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

			network.users.updateUser(UserModel(
				nickname: msg.source.name,
				realname: realname,
			));
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
			if (msg.params[1] != '') {
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
		case 'METADATA':
			if (msg.params.length < 4) {
				break;
			}
			var target = msg.params[0];
			var key = msg.params[1];
			var value = msg.params[3];
			var buffer = _bufferList.get(target, network);
			if (buffer != null) {
				switch (key) {
					case 'soju.im/pinned':
						_bufferList.setPinned(buffer, value == '1');
						break;
					case 'soju.im/muted':
						_bufferList.setMuted(buffer, value == '1');
						break;
				}
				_db.storeBuffer(buffer.entry);
			}
			break;
		case 'PRIVMSG':
		case 'NOTICE':
		case 'TAGMSG':
			var target = msg.params[0];
			if (msg.batchByType('chathistory') != null) {
				break;
			}

			var i = parseTargetPrefix(target, client.isupport.statusMsg);
			if (i > 0) {
				var channel = target.substring(i);
				if (client.isChannel(channel)) {
					target = channel;
				}
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

			_notifController.cancelAllWithBuffer(buffer, DateTime.parse(time));

			buffer.entry.lastReadTime = time;
			return _db.storeBuffer(buffer.entry).then((_) {
				return _db.fetchBufferUnreadCount(buffer.id);
			}).then((unreadCount) {
				buffer.unreadCount = unreadCount;
			});
		case 'REDACT':
			var target = msg.params[0];
			var msgid = msg.params[1];

			var buffer = _bufferList.get(target, network);
			if (buffer == null) {
				break;
			}

			// TODO: handle REDACT in a chathistory batch
			return _handleRedact(buffer, msgid);
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

	Future<void> _handleChatMessages(String target, List<ClientMessage> messages, {MessageEntry? beforeMessage, int? beforeLimit}) async {
		if (messages.length == 0) {
			return;
		}

		var isHistory = messages.first.batchByType('chathistory') != null;

		var createNewBuffer = false;
		List<ClientMessage> notices = [];
		if (!client.isChannel(target)) {
			for (var msg in messages) {
				if (msg.cmd == 'NOTICE') {
					notices.add(msg);
					continue;
				} else if (msg.cmd != 'PRIVMSG') {
					continue;
				}

				// Disregard non-/me CTCP messages
				var ctcp = CtcpMessage.parse(msg);
				if (ctcp == null || ctcp.cmd == 'ACTION') {
					createNewBuffer = true;
					break;
				}
			}
		}

		var buf = _bufferList.get(target, network);
		var isNewBuffer = false;
		if (buf == null && createNewBuffer) {
			isNewBuffer = true;
			buf = await _createBuffer(target);
		}
		if (buf != null && buf.archived && !createNewBuffer) {
			buf = null;
		}
		if (buf == null) {
			if (!notices.isEmpty) {
				// We don't have a buffer to display these NOTICEs, open an
				// ephemeral snackbar
				_provider._noticesController.add(ClientNotice(notices, target, client, network));
			}

			// Bump last delivery time so that we don't fetch again the same
			// NOTICEs via chathistory
			bool bumped = false;
			for (var msg in notices) {
				var t = msg.tags['time'];
				if (t != null && _network.networkEntry.bumpLastDeliveredTime(t)) {
					bumped = true;
				}
			}
			if (bumped) {
				await _db.storeNetwork(_network.networkEntry);
			}
			return;
		}

		List<MessageEntry> privmsgs = [];
		List<ReactionEntry> reactions = [];
		for (var msg in messages) {
			var reply = msg.tags['+draft/reply'];
			var react = msg.tags['+draft/react'];
			if (reply != null && react != null) {
				reactions.add(ReactionEntry(msg, buf.id));
			} else if (msg.cmd == 'NOTICE' || msg.cmd == 'PRIVMSG') {
				privmsgs.add(MessageEntry(msg, buf.id));
			}
		}

		if (reactions.isNotEmpty) {
			await _db.storeReactions(reactions);
		}

		if (privmsgs.isNotEmpty) {
      if (isHistory) {
        privmsgs.sort((a, b) => a.dateTime.compareTo(b.dateTime));
        var toStore = <MessageEntry>[];
        var toAdd = <MessageEntry>[];
        // Add some extra messages to the limit in case of multiple messages at same timestamp.
        var local = await _db.listMessagesAfterEqualTime(buf.id, privmsgs.first.time, privmsgs.length + 10);
        var liNext = 0;
        var completeHistory = beforeLimit != null && messages.length < beforeLimit;
        for (var (i, m) in privmsgs.indexed) {
          var gapBefore = i == 0 && !completeHistory;
          var li = liNext;
          MessageEntry? lm;
          while (true) {
            lm = li < local.length ? local[li] : null;
            if (lm == null) {
              // No local messages left: no match
              break;
            }
            if (lm.dateTime.isBefore(m.dateTime)) {
              // Local message too old: try next one
              li++;
              liNext = li;
              continue;
            }
            if (lm.dateTime.isAfter(m.dateTime)) {
              // Local message too recent: no match
              lm = null;
              break;
            }
            if (lm.raw != m.raw) {
              // Local message raw differs: no match, try next
              li++;
              continue;
            }
            // Same message! Keep, and shift for next match.
            li++;
            liNext = li;
            break;
          }
          if (lm != null) {
            // Matching local message
            if (lm.gapBefore && !gapBefore) {
              lm.gapBefore = false;
              toStore.add(lm);
            }
          } else {
            // No matching local message
            m.gapBefore = gapBefore;
            toStore.add(m);
            toAdd.add(m);
          }
        }
        if (beforeMessage != null && beforeMessage.gapBefore) {
          beforeMessage.gapBefore = false;
          toStore.add(beforeMessage);
        }
        await _db.storeMessages(toStore);
        privmsgs = toAdd;
      } else {
        await _db.storeMessages(privmsgs);
      }
		}

		if (buf.messageHistoryLoaded) {
			var models = await buildMessageModelList(_db, privmsgs);
			buf.addMessages(models, append: !isHistory);
			buf.addReactions(reactions);
		}

		// Only privmsgs affects unread count / lastReadTime
		if (privmsgs.isEmpty) {
			return;
		}

		String t = privmsgs.first.time;
		List<MessageEntry> unread = [];
		for (var entry in privmsgs) {
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
			unawaited(_db.storeBuffer(buf.entry));
			client.setReadMarker(buf.name, buf.entry.lastReadTime!);
		}

    // TODO: if history AROUND, is last delivery time right?
		_bufferList.bumpLastDeliveredTime(buf, t);
		if (_network.networkEntry.bumpLastDeliveredTime(t)) {
			await _db.storeNetwork(_network.networkEntry);
		}

		if (isNewBuffer && client.isNick(buf.name)) {
			_provider.fetchBufferUser(buf);
		}
	}

	Future<void> _handleRedact(BufferModel buffer, String msgid) async {
		var msg = await _db.fetchMessageByNetworkMsgid(buffer.id, msgid);
		if (msg == null) {
			log.print('Received REDACT for unknown msgid "$msgid"');
			return;
		}
		msg.redacted = true;
		await _db.storeMessages([msg]);

		buffer.redactMessage(msgid);
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
			_provider.remove(childNetwork);
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

			_provider.remove(childNetwork);

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
		networkEntry = await _db.storeNetwork(networkEntry);
		var childClient = Client(client.params.apply(bouncerNetId: bouncerNetId));
		childNetwork = NetworkModel(network.serverEntry, networkEntry, childClient.nick, childClient.realname);
		_networkList.add(childNetwork);
		_provider.add(childClient, childNetwork);
		childClient.connect().ignore();
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
		if (entry.msg.cmd != 'PRIVMSG') {
			return false;
		}
		if (client.isMyNick(entry.msg.source!.name)) {
			return false;
		}
		if (isChannel && findTextHighlights(entry.msg.params[1], client.nick).isEmpty) {
			return false;
		}
		var ctcp = CtcpMessage.parse(entry.msg);
		if (ctcp != null && ctcp.cmd != 'ACTION') {
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

			var done = false;
			for (var i = 0; i < 20; i++) {
        // TODO: prevent gaps on between too? like beforeMessage
				var batch = await client.fetchChatHistoryBetween(target.name, from, to, max);
				await readMarkerFuture;
				await _handleChatMessages(target.name, batch.messages);
				if (batch.messages.length < max) {
					done = true;
					break;
				}

				var bumpedFrom = false;
				for (var msg in batch.messages) {
					var t = msg.tags['time'];
					if (t != null && t.compareTo(from) > 0) {
						from = t;
						bumpedFrom = true;
					}
				}
				if (!bumpedFrom) {
					throw Exception('Requested backlog between $from and $to for $target, but all returned messages were before $from');
				}
			}
			if (!done) {
				log.print('Failed to fetch all backlog for $target: limit reached');
			}
		}));
	}

	Future<void> _setupPushSync() async {
		if (!_isPushSupported()) {
			return;
		}

		log.print('Enabling push synchronization');

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
					log.print('Refreshed existing push subscription');
					return;
				} on IrcException catch (err) {
					// Maybe the subscription expired
					if (err.msg.cmd == 'FAIL' && err.msg.params[0] == 'WEBPUSH') {
						log.print('Failed to refresh old push subscription', error: err);
						log.print('Trying to register with a fresh subscription...');
					} else {
						rethrow;
					}
				}
			} else {
				log.print('VAPID key changed');
			}

			try {
				await pushController.deleteSubscription(network.networkEntry, PushSubscription.fromEntry(oldSub));
			} on Exception catch (err) {
				log.print('Failed to delete old push subscription', error: err);
			}
			await client.webPushUnregister(oldSub.endpoint);
			await _db.deleteWebPushSubscription(oldSub.id!);
		} else {
			log.print('No existing push subscription found for this network');
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
				log.print('Registered new push subscription successfully');
			} on Object {
				try {
					await _db.deleteWebPushSubscription(newSub.id!);
				} on Exception catch (err) {
					log.print('Failed to delete Web Push subscription from DB after error', error: err);
				}
				rethrow;
			}
		} on Object {
			try {
				await pushController.deleteSubscription(network.networkEntry, details);
			} on Exception catch (err) {
				log.print('Failed to delete push subscription after error', error: err);
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

Future<List<MessageModel>> buildMessageModelList(DB db, List<MessageEntry> entries) async {
	if (entries.isEmpty) {
		return [];
	}

	List<String> parentMsgids = [];
	for (var entry in entries) {
		var parentMsgid = entry.msg.tags['+draft/reply'];
		if (parentMsgid != null) {
			parentMsgids.add(parentMsgid);
		}
	}

	var bufferId = entries.first.buffer;
	var parentMap = await db.fetchMessageSetByNetworkMsgid(bufferId, parentMsgids);
	var reactionMap = await db.fetchReactionSetBetweenMessages(bufferId, entries.first, entries.last);
	return entries.map((entry) {
		MessageEntry? replyTo;
		var parentMsgid = entry.msg.tags['+draft/reply'];
		if (parentMsgid != null) {
			replyTo = parentMap[parentMsgid];
		}
		var reacts = reactionMap[entry.networkMsgid] ?? [];
		return MessageModel(entry: entry, replyTo: replyTo, reactions: reacts);
	}).toList();
}
