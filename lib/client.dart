import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'irc.dart';

class SaslPlainCredentials {
	final String username;
	final String password;

	SaslPlainCredentials(this.username, this.password);
}

class ConnectParams {
	final String host;
	final int port;
	final bool tls;
	final String nick;
	final String? pass;
	final SaslPlainCredentials? saslPlain;
	final String? bouncerNetId;

	ConnectParams({ required this.host, this.port = 6697, this.tls = true, required this.nick, this.pass, this.saslPlain, this.bouncerNetId });

	ConnectParams replaceBouncerNetId(String? bouncerNetId) {
		return ConnectParams(host: host, port: port, tls: tls, nick: nick, pass: pass, saslPlain: saslPlain, bouncerNetId: bouncerNetId);
	}
}

enum ClientState { disconnected, connecting, connected }

const _autoReconnectDelay = const Duration(seconds: 10);

const _permanentCaps = [
	'batch',
	'echo-message',
	'message-tags',
	'multi-prefix',
	'sasl',
	'server-time',

	'draft/chathistory',

	'soju.im/bouncer-networks',
	'soju.im/read',
];

var _nextClientId = 0;
var _nextPingSerial = 0;

class Client {
	final ConnectParams params;
	final IrcCapRegistry caps = IrcCapRegistry();
	final IrcIsupportRegistry isupport = IrcIsupportRegistry();

	final int _id;
	Socket? _socket;
	String _nick;
	IrcSource? _serverSource;
	ClientState _state = ClientState.disconnected;
	StreamController<ClientMessage> _messagesController = StreamController.broadcast();
	StreamController<ClientState> _statesController = StreamController.broadcast();
	Timer? _reconnectTimer;
	bool _autoReconnect;
	DateTime? _lastConnectTime;
	Map<String, ClientBatch> _batches = Map();
	Map<String, List<ClientMessage>> _pendingNames = Map();
	Future<void> _lastWhoFuture = Future.value(null);
	IrcNameMap<void> _monitored = IrcNameMap(defaultCaseMapping);

	String get nick => _nick;
	IrcSource? get serverSource => _serverSource;
	ClientState get state => _state;
	Stream<ClientMessage> get messages => _messagesController.stream;
	Stream<ClientState> get states => _statesController.stream;

	Client(this.params, { bool autoReconnect = true }) :
		_id = _nextClientId++,
		_nick = params.nick,
		_autoReconnect = autoReconnect;

	Future<void> connect() {
		_reconnectTimer?.cancel();
		_setState(ClientState.connecting);
		_lastConnectTime = DateTime.now();

		_log('Connecting to ${params.host}...');

		final connectTimeout = Duration(seconds: 15);
		Future<Socket> socketFuture;
		if (params.tls) {
			socketFuture = SecureSocket.connect(
				params.host,
				params.port,
				supportedProtocols: ['irc'],
				timeout: connectTimeout,
			);
		} else {
			socketFuture = Socket.connect(
				params.host,
				params.port,
				timeout: connectTimeout,
			);
		}

		return socketFuture.catchError((Object err) {
			_log('Connection failed: ' + err.toString());
			_setState(ClientState.disconnected);
			throw err;
		}).then((socket) {
			_log('Connection opened');
			_socket = socket;

			socket.done.catchError((Object err) {
				_log('Connection error: ' + err.toString());
				_messagesController.addError(err);
				_statesController.addError(err);
			}).whenComplete(() {
				_socket = null;
				caps.clear();
				isupport.clear();
				_batches.clear();
				_pendingNames.clear();
				_monitored.clear();

				_setState(ClientState.disconnected);
			});

			var text = utf8.decoder.bind(socket);
			var lines = text.transform(const LineSplitter());

			lines.listen((l) {
				var msg = IrcMessage.parse(l);
				_handleMessage(msg);
			}, onDone: () {
				_log('Connection closed');
				_socket?.close();
			});

			_setState(ClientState.connected);
			return _register();
		});
	}

	void _log(String s) {
		print('[${_id}] ${s}');
	}

	void _setState(ClientState state) {
		if (_state == state) {
			return;
		}

		_state = state;

		if (!_statesController.isClosed) {
			_statesController.add(state);
		}

		if (state == ClientState.disconnected) {
			_tryAutoReconnect();
		}
	}

	void _tryAutoReconnect() {
		_reconnectTimer?.cancel();

		if (!_autoReconnect) {
			return;
		}

		if (DateTime.now().difference(_lastConnectTime!) > _autoReconnectDelay) {
			_log('Reconnecting immediately');
			connect().ignore();
			return;
		}

		_log('Reconnecting in ${_autoReconnectDelay}');
		_reconnectTimer = Timer(_autoReconnectDelay, () {
			connect().ignore();
		});
	}

	Future<ClientMessage> _waitMessage(bool test(ClientMessage msg)) {
		if (state == ClientState.disconnected) {
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
			} catch (err) {
				completer.completeError(err);
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

	Future<ClientMessage> _roundtripMessage(IrcMessage msg, bool test(ClientMessage msg)) {
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

	Future<ClientBatch> _roundtripBatch(IrcMessage msg, bool test(ClientBatch batch)) {
		return _roundtripMessage(msg, (msg) {
			if (!(msg is ClientEndOfBatch)) {
				return false;
			}
			var endOfBatch = msg as ClientEndOfBatch;
			return test(endOfBatch.child);
		}).then((msg) {
			var endOfBatch = msg as ClientEndOfBatch;
			return endOfBatch.child;
		});
	}

	Future<void> _register() {
		_nick = params.nick;

		var caps = [..._permanentCaps];
		if (params.bouncerNetId == null) {
			caps.add('soju.im/bouncer-networks-notify');
		}

		// Here we're trying to minimize the number of roundtrips as much as
		// possible, because (1) we'll reconnect very regularly and (2) mobile
		// networks can be pretty spotty. So we send in bulk all of the
		// messages required to register the connection. We blindly request all
		// caps we support to avoid waiting for the CAP LS reply.

		send(IrcMessage('CAP', ['LS', '302']));
		if (params.pass != null) {
			send(IrcMessage('PASS', [params.pass!]));
		}
		send(IrcMessage('NICK', [params.nick]));
		send(IrcMessage('USER', [params.nick, '0', '*', params.nick]));
		for (var cap in caps) {
			send(IrcMessage('CAP', ['REQ', cap]));
		}
		_authenticate();
		if (params.bouncerNetId != null) {
			send(IrcMessage('BOUNCER', ['BIND', params.bouncerNetId!]));
		}
		send(IrcMessage('CAP', ['END']));

		var saslSuccess = false;
		return _waitMessage((msg) {
			switch (msg.cmd) {
			case RPL_WELCOME:
				if (params.saslPlain != null && !saslSuccess) {
					_socket?.close();
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
				_socket?.close();
				throw IrcException(msg);
			case RPL_SASLSUCCESS:
				saslSuccess = true;
				break;
			}
			return false;
		}).timeout(Duration(seconds: 15), onTimeout: () {
			throw TimeoutException('Connection registration timed out');
		});
	}

	void _handleMessage(IrcMessage msg) {
		if (kDebugMode) {
			_log('<- ' + msg.toString());
		}

		ClientBatch? msgBatch = null;
		if (msg.tags.containsKey('batch')) {
			msgBatch = _batches[msg.tags['batch']];
		}

		ClientMessage clientMsg;
		switch (msg.cmd) {
		case RPL_ENDOFNAMES:
			var channel = msg.params[1];
			var names = _pendingNames.remove(channel)!;
			clientMsg = ClientEndOfNames(msg, names, batch: msgBatch);
			break;
		case 'BATCH':
			if (msg.params[0].startsWith('-')) {
				var ref = msg.params[0].substring(1);
				var child = _batches[ref];
				if (child == null) {
					throw FormatException('Unknown BATCH reference: ${ref}');
				}
				clientMsg = ClientEndOfBatch(msg, child, batch: msgBatch);
			} else {
				clientMsg = ClientMessage(msg, batch: msgBatch);
			}
			break;
		default:
			clientMsg = ClientMessage(msg, batch: msgBatch);
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
					throw FormatException('Duplicate BATCH reference: ${ref}');
				}
				var batch = ClientBatch(type, params, msgBatch);
				_batches[ref] = batch;
				break;
			case '-':
				_batches.remove(ref);
				break;
			default:
				throw FormatException('Invalid BATCH message: ${msg}');
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

	void disconnect() {
		_autoReconnect = false;
		_reconnectTimer?.cancel();
		_socket?.close();
		_messagesController.close();
		_statesController.close();
	}

	void send(IrcMessage msg) {
		if (_socket == null) {
			return;
		}
		if (kDebugMode) {
			_log('-> ' + msg.toString());
		}
		return _socket!.write(msg.toString() + '\r\n');
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
		// Dots usually indicate server names
		return !name.contains('.') && !isChannel(name);
	}

	void _authenticate() {
		if (params.saslPlain == null) {
			return;
		}

		_log('Starting SASL PLAIN authentication');
		send(IrcMessage('AUTHENTICATE', ['PLAIN']));

		var creds = params.saslPlain!;
		var payload = [0, ...utf8.encode(creds.username), 0, ...utf8.encode(creds.password)];
		send(IrcMessage('AUTHENTICATE', [base64.encode(payload)]));
	}

	Future<List<ChatHistoryTarget>> fetchChatHistoryTargets(String t1, String t2) {
		// TODO: paging
		var msg = IrcMessage(
			'CHATHISTORY',
			['TARGETS', 'timestamp=' + t1, 'timestamp=' + t2, '100'],
		);

		return _roundtripBatch(msg, (batch) {
			return batch.type == 'draft/chathistory-targets';
		}).then((batch) {
			return batch.messages.map((msg) {
				if (msg.cmd != 'CHATHISTORY' || msg.params[0] != 'TARGETS') {
					throw FormatException('Expected CHATHISTORY TARGET message, got: ${msg}');
				}
				return ChatHistoryTarget(msg.params[1], msg.params[2]);
			}).toList();
		});
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

	Future<void> ping() {
		var token = 'goguma-${_nextPingSerial}';
		var msg = IrcMessage('PING', [token]);
		_nextPingSerial++;

		return _roundtripMessage(msg, (msg) {
			return msg.cmd == 'PONG' && msg.params[1] == token;
		}).timeout(Duration(seconds: 15), onTimeout: () {
			_socket?.close();
			throw TimeoutException('Ping timed out');
		});
	}

	Future<void> fetchRead(String target) {
		var msg = IrcMessage('READ', [target]);

		var cm = isupport.caseMapping;
		return _roundtripMessage(msg, (msg) {
			return msg.cmd == 'READ' && isMyNick(msg.source!.name) && cm(msg.params[0]) == cm(target);
		}).timeout(Duration(seconds: 15));
	}

	void setRead(String target, String t) {
		if (!caps.enabled.containsAll(['server-time', 'soju.im/read'])) {
			return;
		}
		send(IrcMessage('READ', [target, 'timestamp=' + t]));
	}

	Future<List<WhoReply>> who(String mask) {
		var cm = isupport.caseMapping;
		List<WhoReply> replies = [];
		var future = _lastWhoFuture.catchError((_) => null).then((_) {
			var msg = IrcMessage('WHO', [mask]);
			return _roundtripMessage(msg, (msg) {
				switch (msg.cmd) {
				case RPL_WHOREPLY:
					replies.add(WhoReply.parse(msg));
					break;
				case RPL_ENDOFWHO:
					return cm(msg.params[1]) == cm(mask);
				}
				return false;
			}).timeout(Duration(seconds: 30));
		}).then((_) => replies);
		_lastWhoFuture = future;
		return future;
	}

	Future<Whois> whois(String nick) {
		var cm = isupport.caseMapping;
		var msg = IrcMessage('WHOIS', [nick]);
		List<ClientMessage> replies = [];
		return _roundtripMessage(msg, (msg) {
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
				if (cm(msg.params[1]) == cm(nick)) {
					replies.add(msg);
				}
				break;
			case RPL_ENDOFWHOIS:
				return cm(msg.params[1]) == cm(nick);
			}
			return false;
		}).then((ClientMessage msg) {
			var prefixes = isupport.memberships.map((m) => m.prefix).join('');
			return Whois.parse(msg.params[1], replies, prefixes);
		});
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
}

class ClientMessage extends IrcMessage {
	final ClientBatch? batch;

	ClientMessage(IrcMessage msg, { this.batch }) :
		super(msg.cmd, msg.params, tags: msg.tags, source: msg.source);

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
	final UnmodifiableListView<ClientMessage> names;

	ClientEndOfNames(IrcMessage msg, List<ClientMessage> names, { ClientBatch? batch }) :
		this.names = UnmodifiableListView(names),
		super(msg, batch: batch);
}

class ClientEndOfBatch extends ClientMessage {
	final ClientBatch child;

	ClientEndOfBatch(IrcMessage msg, ClientBatch child, { ClientBatch? batch }) :
		this.child = child,
		super(msg, batch: batch);
}

class ClientBatch {
	final String type;
	final UnmodifiableListView<String> params;
	final ClientBatch? parent;

	final List<ClientMessage> _messages = [];

	UnmodifiableListView<ClientMessage> get messages => UnmodifiableListView(_messages);

	ClientBatch(this.type, List<String> params, this.parent) : this.params = UnmodifiableListView(params);
}

class ChatHistoryTarget {
	final String name;
	final String time;

	ChatHistoryTarget(this.name, this.time);
}
