import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'irc.dart';

class SaslPlainCredentials {
	final String username;
	final String password;

	const SaslPlainCredentials(this.username, this.password);
}

class ConnectParams {
	final String host;
	final int port;
	final bool tls;
	final String nick;
	final String realname;
	final String? pass;
	final SaslPlainCredentials? saslPlain;
	final String? bouncerNetId;

	const ConnectParams({
		required this.host,
		this.port = 6697,
		this.tls = true,
		required this.nick,
		String? realname,
		this.pass,
		this.saslPlain,
		this.bouncerNetId,
	}) : realname = realname ?? nick;

	ConnectParams apply({
		String? bouncerNetId,
		String? nick,
		String? realname,
	}) {
		return ConnectParams(
			host: host,
			port: port,
			tls: tls,
			nick: nick ?? this.nick,
			realname: realname ?? this.realname,
			pass: pass,
			saslPlain: saslPlain,
			bouncerNetId: bouncerNetId ?? this.bouncerNetId,
		);
	}
}

enum ClientState { disconnected, connecting, connected }

const _autoReconnectDelay = Duration(seconds: 10);

const _permanentCaps = [
	'away-notify',
	'batch',
	'echo-message',
	'message-tags',
	'multi-prefix',
	'sasl',
	'server-time',
	'setname',

	'draft/chathistory',
	'draft/extended-monitor',

	'soju.im/bouncer-networks',
	'soju.im/no-implicit-names',
	'soju.im/read',
	'soju.im/webpush',
];

var _nextClientId = 0;
var _nextPingSerial = 0;

class Client {
	final IrcCapRegistry caps = IrcCapRegistry();
	final IrcIsupportRegistry isupport = IrcIsupportRegistry();

	final int _id;
	ConnectParams _params;
	Socket? _socket;
	String _nick;
	String _realname;
	IrcSource? _serverSource;
	ClientState _state = ClientState.disconnected;
	final StreamController<ClientMessage> _messagesController = StreamController.broadcast(sync: true);
	final StreamController<ClientState> _statesController = StreamController.broadcast(sync: true);
	Timer? _reconnectTimer;
	bool _autoReconnect;
	DateTime? _lastConnectTime;
	final Map<String, ClientBatch> _batches = {};
	final Map<String, List<ClientMessage>> _pendingNames = {};
	Future<void> _lastWhoFuture = Future.value(null);
	Future<void> _lastListFuture = Future.value(null);
	final IrcNameMap<void> _monitored = IrcNameMap(defaultCaseMapping);

	ConnectParams get params => _params;
	String get nick => _nick;
	String get realname => _realname;
	IrcSource? get serverSource => _serverSource;
	ClientState get state => _state;
	Stream<ClientMessage> get messages => _messagesController.stream;
	Stream<ClientState> get states => _statesController.stream;
	bool get autoReconnect => _autoReconnect;

	Client(ConnectParams params, { bool autoReconnect = true }) :
		_id = _nextClientId++,
		_params = params,
		_nick = params.nick,
		_realname = params.realname,
		_autoReconnect = autoReconnect;

	Future<void> connect() async {
		if (_messagesController.isClosed) {
			throw StateError('connect() called after dispose()');
		}

		// Always switch to the disconnected state, because users reset their
		// state when handling that transition.
		_reconnectTimer?.cancel();
		_setState(ClientState.disconnected);
		_setState(ClientState.connecting);
		_lastConnectTime = DateTime.now();

		await _socket?.close();

		_log('Connecting to ${_params.host}...');

		final connectTimeout = Duration(seconds: 15);
		Future<Socket> socketFuture;
		if (_params.tls) {
			socketFuture = SecureSocket.connect(
				_params.host,
				_params.port,
				supportedProtocols: ['irc'],
				timeout: connectTimeout,
			);
		} else {
			socketFuture = Socket.connect(
				_params.host,
				_params.port,
				timeout: connectTimeout,
			);
		}

		Socket socket;
		try {
			socket = await socketFuture;
		} on Exception catch (err) {
			_log('Connection failed: ' + err.toString());
			_setState(ClientState.disconnected);
			_tryAutoReconnect();
			rethrow;
		}

		_log('Connection opened');
		_socket = socket;
		_setState(ClientState.connected);

		// socket.done is resolved when socket.close() is called. It's not
		// called when only the incoming side of the bi-directional connection
		// is closed. See the onDone callback below.
		socket.done.catchError((Object err) {
			_log('Connection error: $err');
			_messagesController.addError(err);
			_statesController.addError(err);
		}).whenComplete(() {
			_log('Connection closed');

			_socket = null;
			caps.clear();
			isupport.clear();
			_batches.clear();
			_pendingNames.clear();
			_monitored.clear();

			// Don't mutate our state or try to auto-reconnect if we're already
			// connecting.
			if (_state != ClientState.connecting) {
				_setState(ClientState.disconnected);
				_tryAutoReconnect();
			}
		});

		var decoder = Utf8Decoder(allowMalformed: true);
		var text = decoder.bind(socket);
		var lines = text.transform(const LineSplitter());

		lines.listen((l) {
			var msg = IrcMessage.parse(l);
			_handleMessage(msg);
		}, onDone: () {
			// This callback is invoked when the incoming side of the
			// bi-directional connection is closed. We close the outgoing side
			// here.
			_socket?.close();
		});

		try {
			await _register();
		} on Exception {
			_socket?.close();
			rethrow;
		}
	}

	void _log(String s) {
		print('[$_id] $s');
	}

	void _setState(ClientState state) {
		if (_state == state) {
			return;
		}

		_state = state;

		if (!_statesController.isClosed) {
			_statesController.add(state);
		}
	}

	set autoReconnect(bool autoReconnect) {
		if (_autoReconnect == autoReconnect) {
			return;
		}

		_autoReconnect = autoReconnect;
		_tryAutoReconnect();
	}

	void _tryAutoReconnect() {
		_reconnectTimer?.cancel();
		_reconnectTimer = null;

		if (!_autoReconnect || state != ClientState.disconnected) {
			return;
		}

		Duration d;
		if (DateTime.now().difference(_lastConnectTime!) > _autoReconnectDelay) {
			_log('Reconnecting immediately');
			d = Duration.zero;
		} else {
			_log('Reconnecting in $_autoReconnectDelay');
			d = _autoReconnectDelay;
		}

		_reconnectTimer = Timer(d, () async {
			try {
				await connect();
			} on Exception catch (err) {
				_log('Failed to reconnect: $err');
			}
		});
	}

	Future<ClientMessage> _waitMessage(bool Function(ClientMessage msg) test) {
		if (state != ClientState.connected) {
			return Future.error(Exception('Disconnected from server'));
		}

		Completer<ClientMessage> completer = Completer();

		var statesSub = states.listen((state) {
			if (state == ClientState.disconnected) {
				completer.completeError(Exception('Disconnected from server'));
			}
		});

		var messagesSub = messages.listen((msg) {
			bool done;
			try {
				done = test(msg);
			} on Object catch (err, stackTrace) {
				completer.completeError(err, stackTrace);
				return;
			}
			if (done) {
				completer.complete(msg);
			}
		});

		return completer.future.whenComplete(() {
			statesSub.cancel();
			messagesSub.cancel();
		});
	}

	Future<ClientMessage> _roundtripMessage(IrcMessage msg, bool Function(ClientMessage msg) test) {
		var cmd = msg.cmd;
		send(msg);

		return _waitMessage((msg) {
			bool isError = false;
			switch (msg.cmd) {
			case 'FAIL':
				isError = msg.params[0] == cmd;
				break;
			case ERR_UNKNOWNERROR:
			case ERR_UNKNOWNCOMMAND:
			case ERR_NEEDMOREPARAMS:
			case RPL_TRYAGAIN:
				isError = msg.params[1] == cmd;
			}
			if (isError) {
				throw IrcException(msg);
			}

			return test(msg);
		});
	}

	Future<ClientBatch> _roundtripBatch(IrcMessage msg, bool Function(ClientBatch batch) test) async {
		var endMsg = await _roundtripMessage(msg, (msg) {
			if (!(msg is ClientEndOfBatch)) {
				return false;
			}
			return test(msg.child);
		});
		var endOfBatch = endMsg as ClientEndOfBatch;
		return endOfBatch.child;
	}

	Future<void> _register() {
		_nick = _params.nick;
		_realname = _params.nick;

		var caps = [..._permanentCaps];
		if (_params.bouncerNetId == null) {
			caps.add('soju.im/bouncer-networks-notify');
		}

		// Here we're trying to minimize the number of roundtrips as much as
		// possible, because (1) we'll reconnect very regularly and (2) mobile
		// networks can be pretty spotty. So we send in bulk all of the
		// messages required to register the connection. We blindly request all
		// caps we support to avoid waiting for the CAP LS reply.

		send(IrcMessage('CAP', ['LS', '302']));
		if (_params.pass != null) {
			send(IrcMessage('PASS', [_params.pass!]));
		}
		send(IrcMessage('NICK', [_params.nick]));
		send(IrcMessage('USER', [_params.nick, '0', '*', _params.realname]));
		for (var cap in caps) {
			send(IrcMessage('CAP', ['REQ', cap]));
		}
		_authenticate();
		if (_params.bouncerNetId != null) {
			send(IrcMessage('BOUNCER', ['BIND', _params.bouncerNetId!]));
		}
		send(IrcMessage('CAP', ['END']));

		var saslSuccess = false;
		return _waitMessage((msg) {
			switch (msg.cmd) {
			case RPL_WELCOME:
				if (_params.saslPlain != null && !saslSuccess) {
					throw Exception('Server doesn\'t support SASL authentication');
				}
				return true;
			case 'ERROR':
			case 'FAIL':
			case ERR_NICKLOCKED:
			case ERR_PASSWDMISMATCH:
			case ERR_ERRONEUSNICKNAME:
			case ERR_NICKNAMEINUSE:
			case ERR_NICKCOLLISION:
			case ERR_UNAVAILRESOURCE:
			case ERR_NOPERMFORHOST:
			case ERR_YOUREBANNEDCREEP:
			case ERR_SASLFAIL:
			case ERR_SASLTOOLONG:
			case ERR_SASLABORTED:
				throw IrcException(msg);
			case RPL_SASLSUCCESS:
				saslSuccess = true;
				break;
			}
			return false;
		}).timeout(Duration(seconds: 30), onTimeout: () {
			throw TimeoutException('Connection registration timed out');
		});
	}

	void _handleMessage(IrcMessage msg) {
		if (kDebugMode) {
			_log('<- ' + msg.toString());
		}

		if (msg.source == null) {
			var source = _serverSource ?? IrcSource('*');
			msg = IrcMessage(msg.cmd, msg.params, tags: msg.tags, source: source);
		}

		ClientBatch? msgBatch;
		if (msg.tags.containsKey('batch')) {
			msgBatch = _batches[msg.tags['batch']];
		}

		ClientMessage clientMsg;
		switch (msg.cmd) {
		case RPL_ENDOFNAMES:
			var channel = msg.params[1];
			var names = _pendingNames.remove(channel)!;
			clientMsg = ClientEndOfNames._(msg, names, isupport, batch: msgBatch);
			break;
		case 'BATCH':
			if (msg.params[0].startsWith('-')) {
				var ref = msg.params[0].substring(1);
				var child = _batches[ref];
				if (child == null) {
					throw FormatException('Unknown BATCH reference: $ref');
				}
				clientMsg = ClientEndOfBatch._(msg, child, batch: msgBatch);
			} else {
				clientMsg = ClientMessage._(msg, batch: msgBatch);
			}
			break;
		default:
			clientMsg = ClientMessage._(msg, batch: msgBatch);
		}

		msgBatch?._messages.add(clientMsg);

		switch (msg.cmd) {
		case 'CAP':
			caps.parse(msg);

			if (msg.params[1].toUpperCase() != 'NEW') {
				break;
			}

			for (var cap in _permanentCaps) {
				if (caps.available.containsKey(cap) && !caps.enabled.contains(cap)) {
					send(IrcMessage('CAP', ['REQ', cap]));
				}
			}
			break;
		case RPL_WELCOME:
			_log('Registration complete');
			_serverSource = msg.source;
			_nick = msg.params[0];
			break;
		case RPL_ISUPPORT:
			isupport.parse(msg.params.sublist(1, msg.params.length - 1));
			_monitored.setCaseMapping(isupport.caseMapping);
			break;
		case 'NICK':
			if (isMyNick(msg.source!.name)) {
				_nick = msg.params[0];
			}
			break;
		case 'SETNAME':
			if (isMyNick(msg.source!.name)) {
				_realname = msg.params[0];
			}
			break;
		case 'PING':
			send(IrcMessage('PONG', msg.params));
			break;
		case 'BATCH':
			var kind = msg.params[0][0];
			var ref = msg.params[0].substring(1);

			switch (kind) {
			case '+':
				var type = msg.params[1];
				var params = msg.params.sublist(2);
				if (_batches.containsKey(ref)) {
					throw FormatException('Duplicate BATCH reference: $ref');
				}
				var batch = ClientBatch._(type, params, msgBatch);
				_batches[ref] = batch;
				break;
			case '-':
				_batches.remove(ref);
				break;
			default:
				throw FormatException('Invalid BATCH message: $msg');
			}
			break;
		case RPL_NAMREPLY:
			var channel = msg.params[2];
			_pendingNames.putIfAbsent(channel, () => []).add(clientMsg);
			break;
		case ERR_MONLISTFULL:
			var targets = msg.params[2].split(',');
			for (var name in targets) {
				_monitored.remove(name);
			}
			break;
		}

		if (!_messagesController.isClosed) {
			_messagesController.add(clientMsg);
		}
	}

	void dispose() {
		if (_messagesController.isClosed) {
			throw StateError('dispose() called twice');
		}
		_log('Destroying client');
		_autoReconnect = false;
		_reconnectTimer?.cancel();
		_socket?.close();
		_messagesController.close();
		_statesController.close();
	}

	void send(IrcMessage msg) {
		if (_socket == null) {
			// TODO: throw SocketException.closed()
			_log('Warning: tried to send message while connection is closed: $msg');
			return;
		}
		if (kDebugMode) {
			_log('-> ' + msg.toString());
		}
		_socket!.write(msg.toString() + '\r\n');
	}

	bool isChannel(String name) {
		return name.length > 0 && isupport.chanTypes.contains(name[0]);
	}

	bool isMyNick(String name) {
		var cm = isupport.caseMapping;
		return cm(name) == cm(nick);
	}

	bool isNick(String name) {
		var cm = isupport.caseMapping;
		if (_serverSource != null && cm(name) == cm(_serverSource!.name)) {
			return false;
		}
		// A dollar is used for server-wide broadcasts. Dots usually indicate
		// server names.
		return !name.startsWith('\$') && !name.contains('.') && !isChannel(name) && name != '*';
	}

	void _authenticate() {
		var creds = _params.saslPlain;
		if (creds == null) {
			return;
		}

		_log('Starting SASL PLAIN authentication');
		send(IrcMessage('AUTHENTICATE', ['PLAIN']));

		var payload = [0, ...utf8.encode(creds.username), 0, ...utf8.encode(creds.password)];
		send(IrcMessage('AUTHENTICATE', [base64.encode(payload)]));
	}

	Future<List<ChatHistoryTarget>> fetchChatHistoryTargets(String t1, String t2) async {
		// TODO: paging
		var msg = IrcMessage(
			'CHATHISTORY',
			['TARGETS', 'timestamp=' + t1, 'timestamp=' + t2, '100'],
		);

		var batch = await _roundtripBatch(msg, (batch) {
			return batch.type == 'draft/chathistory-targets';
		});
		return batch.messages.map((msg) {
			if (msg.cmd != 'CHATHISTORY' || msg.params[0] != 'TARGETS') {
				throw FormatException('Expected CHATHISTORY TARGET message, got: $msg');
			}
			return ChatHistoryTarget._(msg.params[1], msg.params[2]);
		}).toList();
	}

	Future<ClientBatch> _fetchChatHistory(String subcmd, String target, List<String> params) {
		var msg = IrcMessage('CHATHISTORY', [subcmd, target, ...params]);

		var cm = isupport.caseMapping;
		return _roundtripBatch(msg, (batch) {
			return batch.type == 'chathistory' && cm(batch.params[0]) == cm(target);
		});
	}

	Future<ClientBatch> fetchChatHistoryBetween(String target, String t1, String t2, int limit) {
		var params = ['timestamp=' + t1, 'timestamp=' + t2, '$limit'];
		return _fetchChatHistory('BETWEEN', target, params);
	}

	Future<ClientBatch> fetchChatHistoryBefore(String target, String t, int limit) {
		var params = ['timestamp=' + t, '$limit'];
		return _fetchChatHistory('BEFORE', target, params);
	}

	Future<ClientBatch> fetchChatHistoryLatest(String target, String? t, int limit) {
		var bound = t == null ? '*' : 'timestamp=' + t;
		var params = [bound, '$limit'];
		return _fetchChatHistory('LATEST', target, params);
	}

	Future<void> ping() async {
		var token = 'goguma-$_nextPingSerial';
		var msg = IrcMessage('PING', [token]);
		_nextPingSerial++;

		try {
			await _roundtripMessage(msg, (msg) {
				return msg.cmd == 'PONG' && msg.params[1] == token;
			}).timeout(Duration(seconds: 15));
		} on Exception {
			_socket?.close();
			rethrow;
		}
	}

	Future<void> fetchRead(String target) {
		var msg = IrcMessage('READ', [target]);

		var cm = isupport.caseMapping;
		return _roundtripMessage(msg, (msg) {
			return msg.cmd == 'READ' && isMyNick(msg.source.name) && cm(msg.params[0]) == cm(target);
		}).timeout(Duration(seconds: 15));
	}

	void setRead(String target, String t) {
		if (!caps.enabled.containsAll(['server-time', 'soju.im/read'])) {
			return;
		}
		send(IrcMessage('READ', [target, 'timestamp=' + t]));
	}

	Future<NamesReply> names(String channel) async {
		var cm = isupport.caseMapping;
		var msg = IrcMessage('NAMES', [channel]);
		var endMsg = await _roundtripMessage(msg, (msg) {
			return msg.cmd == RPL_ENDOFNAMES && cm(msg.params[1]) == cm(channel);
		});
		var endOfNames = endMsg as ClientEndOfNames;
		return endOfNames.names;
	}

	Future<List<WhoReply>> _who(String mask, Set<WhoxField> whoxFields) async {
		whoxFields = { ...whoxFields };
		whoxFields.addAll([WhoxField.nickname, WhoxField.realname, WhoxField.flags]);

		List<String> params = [mask];
		if (isupport.whox) {
			// Only request the fields we're interested in
			params.add(formatWhoxParam(whoxFields));
		}
		var msg = IrcMessage('WHO', params);

		List<WhoReply> replies = [];
		var cm = isupport.caseMapping;
		await _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case RPL_WHOREPLY:
				replies.add(WhoReply.parse(msg, isupport));
				break;
			case RPL_WHOSPCRPL:
				replies.add(WhoReply.parseWhox(msg, whoxFields, isupport));
				break;
			case RPL_ENDOFWHO:
				return cm(msg.params[1]) == cm(mask);
			}
			return false;
		}).timeout(Duration(seconds: 30));

		return replies;
	}

	Future<List<WhoReply>> who(String mask, { Set<WhoxField> whoxFields = const {} }) {
		var future = _lastWhoFuture.then((_) => _who(mask, whoxFields));

		// Create a new Future which never errors out, always succeeds when the
		// previous WHO command completes
		var completer = Completer<void>();
		_lastWhoFuture = completer.future;
		return future.whenComplete(() {
			completer.complete(null);
		});
	}

	Future<Whois> whois(String nick) async {
		var cm = isupport.caseMapping;
		var msg = IrcMessage('WHOIS', [nick]);
		List<ClientMessage> replies = [];
		var endMsg = await _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case ERR_NOSUCHNICK:
				throw IrcException(msg);
			case RPL_WHOISCERTFP:
			case RPL_WHOISREGNICK:
			case RPL_WHOISUSER:
			case RPL_WHOISSERVER:
			case RPL_WHOISOPERATOR:
			case RPL_WHOISIDLE:
			case RPL_WHOISCHANNELS:
			case RPL_WHOISSPECIAL:
			case RPL_WHOISACCOUNT:
			case RPL_WHOISACTUALLY:
			case RPL_WHOISHOST:
			case RPL_WHOISMODES:
			case RPL_WHOISSECURE:
			case RPL_WHOISBOT:
				if (cm(msg.params[1]) == cm(nick)) {
					replies.add(msg);
				}
				break;
			case RPL_ENDOFWHOIS:
				return cm(msg.params[1]) == cm(nick);
			}
			return false;
		});
		var prefixes = isupport.memberships.map((m) => m.prefix).join('');
		return Whois.parse(endMsg.params[1], replies, prefixes);
	}

	Future<List<ListReply>> _list(String mask) async {
		var msg = IrcMessage('LIST', [mask]);
		List<ListReply> replies = [];
		await _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case RPL_LIST:
				replies.add(ListReply.parse(msg));
				break;
			case RPL_LISTEND:
				return true;
			}
			return false;
		}).timeout(Duration(seconds: 30));
		return replies;
	}

	Future<List<ListReply>> list(String mask) {
		var future = _lastListFuture.then((_) => _list(mask));

		// Create a new Future which never errors out, always succeeds when the
		// previous LIST command completes
		var completer = Completer<void>();
		_lastListFuture = completer.future;
		return future.whenComplete(() {
			completer.complete(null);
		});
	}

	Future<String?> motd() async {
		var msg = IrcMessage('MOTD', []);
		String? motd;
		await _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case RPL_MOTD:
				var line = msg.params[1];
				if (line.startsWith('- ')) {
					line = line.substring(2);
				}
				if (motd == null) {
					motd = line;
				} else {
					motd = motd! + '\n' + line;
				}
				break;
			case RPL_ENDOFMOTD:
			case ERR_NOMOTD:
				return true;
			}
			return false;
		});
		return motd;
	}

	void monitor(Iterable<String> targets) {
		var l = targets.where((name) => !_monitored.containsKey(name)).toList();
		var limit = isupport.monitor;
		if (limit == null) {
			return;
		} else if (_monitored.length + l.length > limit) {
			l = l.sublist(0, limit - _monitored.length);
		}

		if (l.isEmpty) {
			return;
		}

		send(IrcMessage('MONITOR', ['+', l.join(',')]));
		for (var name in l) {
			_monitored[name] = null;
		}
	}

	void unmonitor(Iterable<String> targets) {
		var l = targets.where((name) => _monitored.containsKey(name)).toList();
		if (l.isEmpty) {
			return;
		}

		send(IrcMessage('MONITOR', ['-', l.join(',')]));
		for (var name in l) {
			_monitored.remove(name);
		}
	}

	Future<void> join(String name) {
		// TODO: support for multiple channels
		var cm = isupport.caseMapping;
		var msg = IrcMessage('JOIN', [name]);
		return _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case ERR_NOSUCHCHANNEL:
			case ERR_TOOMANYCHANNELS:
			case ERR_BADCHANNELKEY:
			case ERR_BANNEDFROMCHAN:
			case ERR_CHANNELISFULL:
			case ERR_INVITEONLYCHAN:
				throw IrcException(msg);
			case 'JOIN':
				return isMyNick(msg.source.name) && cm(msg.params[0]) == cm(name);
			}
			return false;
		});
	}

	Future<void> setTopic(String channel, String? topic) {
		var cm = isupport.caseMapping;
		var msg = IrcMessage('TOPIC', [channel, topic ?? '']);
		return _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case ERR_NOSUCHCHANNEL:
			case ERR_NOTONCHANNEL:
			case ERR_CHANOPRIVSNEEDED:
				if (cm(msg.params[1]) == cm(channel)) {
					throw IrcException(msg);
				}
				break;
			case 'TOPIC':
				return cm(msg.params[0]) == cm(channel);
			}
			return false;
		});
	}

	Future<IrcMessage> fetchMode(String target) {
		assert(isChannel(target)); // TODO: support for fetching user modes
		var cm = isupport.caseMapping;
		var msg = IrcMessage('MODE', [target]);
		return _roundtripMessage(msg, (msg) {
			switch (msg.cmd) {
			case ERR_NOSUCHCHANNEL:
				if (cm(msg.params[1]) == cm(target)) {
					throw IrcException(msg);
				}
				break;
			case RPL_CHANNELMODEIS:
				return cm(msg.params[1]) == cm(target);
			}
			return false;
		});
	}

	Future<void> setNickname(String nick) async {
		var msg = IrcMessage('NICK', [nick]);
		var cm = isupport.caseMapping;
		var oldNick = nick;
		await _roundtripMessage(msg, (msg) {
			return msg.cmd == 'NICK' && cm(msg.source.name) == cm(oldNick);
		});
		_params = _params.apply(nick: nick);
	}

	Future<void> setRealname(String realname) async {
		var msg = IrcMessage('SETNAME', [realname]);
		await _roundtripMessage(msg, (msg) {
			return msg.cmd == 'SETNAME' && isMyNick(msg.source.name);
		});
		_params = _params.apply(realname: realname);
	}

	Future<void> webPushRegister(String endpoint, Map<String, List<int>> keys) {
		Map<String, String> encodedKeys = Map.fromEntries(keys.entries.map((kv) {
			return MapEntry(kv.key, base64Url.encode(kv.value));
		}));
		var msg = IrcMessage('WEBPUSH', ['REGISTER', endpoint, formatIrcTags(encodedKeys)]);
		return _roundtripMessage(msg, (msg) {
			return msg.cmd == 'WEBPUSH' && msg.params[0] == 'REGISTER' && msg.params[1] == endpoint;
		});
	}

	Future<void> webPushUnregister(String endpoint) {
		var msg = IrcMessage('WEBPUSH', ['UNREGISTER', endpoint]);
		return _roundtripMessage(msg, (msg) {
			return msg.cmd == 'WEBPUSH' && msg.params[0] == 'UNREGISTER' && msg.params[1] == endpoint;
		});
	}
}

class ClientMessage extends IrcMessage {
	final ClientBatch? batch;

	ClientMessage._(IrcMessage msg, { this.batch }) :
		super(msg.cmd, msg.params, tags: msg.tags, source: msg.source);

	@override
	IrcSource get source => super.source!;

	ClientBatch? batchByType(String type) {
		ClientBatch? batch = this.batch;
		while (batch != null) {
			if (batch.type == type) {
				return batch;
			}
		}
		return null;
	}
}

class ClientEndOfNames extends ClientMessage {
	final NamesReply names;

	ClientEndOfNames._(IrcMessage msg, List<ClientMessage> names, IrcIsupportRegistry isupport, { ClientBatch? batch }) :
		names = NamesReply.parse(names, isupport),
		super._(msg, batch: batch);
}

class ClientEndOfBatch extends ClientMessage {
	final ClientBatch child;

	ClientEndOfBatch._(IrcMessage msg, this.child, { ClientBatch? batch }) :
		super._(msg, batch: batch);
}

class ClientBatch {
	final String type;
	final UnmodifiableListView<String> params;
	final ClientBatch? parent;

	final List<ClientMessage> _messages = [];

	UnmodifiableListView<ClientMessage> get messages => UnmodifiableListView(_messages);

	ClientBatch._(this.type, List<String> params, this.parent) :
		params = UnmodifiableListView(params);
}

class ChatHistoryTarget {
	final String name;
	final String time;

	const ChatHistoryTarget._(this.name, this.time);
}
