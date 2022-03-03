import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
	IrcPrefix? _serverPrefix;
	ClientState _state = ClientState.disconnected;
	StreamController<ClientMessage> _messagesController = StreamController.broadcast();
	StreamController<ClientState> _statesController = StreamController.broadcast();
	StreamController<ClientBatch> _batchesController = StreamController.broadcast();
	Timer? _reconnectTimer;
	bool _autoReconnect;
	DateTime? _lastConnectTime;
	Map<String, ClientBatch> _batches = Map();
	Map<String, List<ClientMessage>> _pendingNames = Map();
	Future<void> _lastWhoFuture = Future.value(null);
	List<ClientMessage> _pendingWhoReplies = [];

	String get nick => _nick;
	IrcPrefix? get serverPrefix => _serverPrefix;
	ClientState get state => _state;
	Stream<ClientMessage> get messages => _messagesController.stream;
	Stream<ClientState> get states => _statesController.stream;
	Stream<ClientBatch> get batches => _batchesController.stream;

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

		return socketFuture.catchError((err) {
			_log('Connection failed: ' + err.toString());
			_setState(ClientState.disconnected);
			throw err;
		}).then((socket) {
			_log('Connection opened');
			_socket = socket;

			socket.done.catchError((err) {
				_log('Connection error: ' + err.toString());
				_messagesController.addError(err);
				_statesController.addError(err);
				_batchesController.addError(err);
			}).whenComplete(() {
				_socket = null;
				caps.clear();
				isupport.clear();
				_batches.clear();
				_pendingNames.clear();

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

	_log(String s) {
		print('[${_id}] ${s}');
	}

	_setState(ClientState state) {
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

	_tryAutoReconnect() {
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

	Future<void> _register() {
		_nick = params.nick;

		var caps = [..._permanentCaps];
		if (params.bouncerNetId == null) {
			caps.add('soju.im/bouncer-networks-notify');
		}

		send(IrcMessage('CAP', params: ['LS', '302']));
		if (params.pass != null) {
			send(IrcMessage('PASS', params: [params.pass!]));
		}
		send(IrcMessage('NICK', params: [params.nick]));
		send(IrcMessage('USER', params: [params.nick, '0', '*', params.nick]));
		for (var cap in caps) {
			send(IrcMessage('CAP', params: ['REQ', cap]));
		}
		_authenticate();
		if (params.bouncerNetId != null) {
			send(IrcMessage('BOUNCER', params: ['BIND', params.bouncerNetId!]));
		}
		send(IrcMessage('CAP', params: ['END']));

		var saslSuccess = false;
		return messages.firstWhere((msg) {
			switch (msg.cmd) {
			case RPL_WELCOME:
				if (params.saslPlain != null && !saslSuccess) {
					_socket?.close();
					throw Exception('Server doesn\'t support SASL authentication');
				}
				return true;
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

	_handleMessage(IrcMessage msg) {
		_log('<- ' + msg.toString());

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
					send(IrcMessage('CAP', params: ['REQ', cap]));
				}
			}
			break;
		case RPL_WELCOME:
			_log('Registration complete');
			_serverPrefix = msg.prefix;
			_nick = msg.params[0];
			break;
		case RPL_ISUPPORT:
			isupport.parse(msg.params.sublist(1, msg.params.length - 1));
			break;
		case 'NICK':
			if (isMyNick(msg.prefix!.name)) {
				_nick = msg.params[0];
			}
			break;
		case 'PING':
			send(IrcMessage('PONG', params: msg.params));
			break;
		case 'BATCH':
			var kind = msg.params[0][0];
			var ref = msg.params[0].substring(1);

			switch (kind) {
			case '+':
				var type = msg.params[1];
				var params = msg.params.sublist(2);
				if (_batches.containsKey(ref)) {
					throw new FormatException('Duplicate BATCH reference: ${ref}');
				}
				var batch = ClientBatch(type, params, msgBatch);
				_batches[ref] = batch;
				break;
			case '-':
				var batch = _batches[ref];
				if (batch == null) {
					throw new FormatException('Unknown BATCH reference: ${ref}');
				}
				_batches.remove(ref);
				if (!_batchesController.isClosed) {
					_batchesController.add(batch);
				}
				break;
			default:
				throw FormatException('Invalid BATCH message: ${msg}');
			}
			break;
		case RPL_NAMREPLY:
			var channel = msg.params[2];
			_pendingNames.putIfAbsent(channel, () => []).add(clientMsg);
			break;
		case RPL_WHOREPLY:
			_pendingWhoReplies.add(clientMsg);
			break;
		}

		if (!_messagesController.isClosed) {
			_messagesController.add(clientMsg);
		}
	}

	disconnect() {
		_autoReconnect = false;
		_reconnectTimer?.cancel();
		_socket?.close();
		_messagesController.close();
		_statesController.close();
		_batchesController.close();
	}

	send(IrcMessage msg) {
		if (_socket == null) {
			return;
		}
		_log('-> ' + msg.toString());
		return _socket!.write(msg.toString() + '\r\n');
	}

	bool isChannel(String name) {
		return name.length > 0 && isupport.chanTypes.contains(name[0]);
	}

	bool isMyNick(String name) {
		var cm = isupport.caseMapping;
		return cm(name) == cm(nick);
	}

	void _authenticate() {
		if (params.saslPlain == null) {
			return;
		}

		_log('Starting SASL PLAIN authentication');
		send(IrcMessage('AUTHENTICATE', params: ['PLAIN']));

		var creds = params.saslPlain!;
		var payload = [0, ...utf8.encode(creds.username), 0, ...utf8.encode(creds.password)];
		send(IrcMessage('AUTHENTICATE', params: [base64.encode(payload)]));
	}

	Future<List<ChatHistoryTarget>> fetchChatHistoryTargets(String t1, String t2) {
		// TODO: paging
		send(IrcMessage(
			'CHATHISTORY',
			params: ['TARGETS', 'timestamp=' + t1, 'timestamp=' + t2, '100'],
		));

		// TODO: error handling
		return batches.firstWhere((batch) {
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

	Future<ClientBatch> fetchChatHistoryBetween(String target, String t1, String t2, int limit) {
		send(IrcMessage(
			'CHATHISTORY',
			params: ['BETWEEN', target, 'timestamp=' + t1, 'timestamp=' + t2, '$limit'],
		));

		var cm = isupport.caseMapping;
		return batches.firstWhere((batch) {
			return batch.type == 'chathistory' && cm(batch.params[0]) == cm(target);
		});
	}

	Future<void> ping() {
		var token = 'goguma-${_nextPingSerial}';
		send(IrcMessage('PING', params: [token]));
		_nextPingSerial++;

		return messages.firstWhere((msg) {
			return msg.cmd == 'PONG' && msg.params[1] == token;
		}).timeout(Duration(seconds: 15), onTimeout: () {
			_socket?.close();
			throw TimeoutException('Ping timed out');
		});
	}

	Future<void> fetchRead(String target) {
		send(IrcMessage('READ', params: [target]));

		var cm = isupport.caseMapping;
		return messages.firstWhere((msg) {
			return msg.cmd == 'READ' && isMyNick(msg.prefix!.name) && cm(msg.params[0]) == cm(target);
		}).timeout(Duration(seconds: 15));
	}

	void setRead(String target, String t) {
		if (!caps.enabled.containsAll(['server-time', 'soju.im/read'])) {
			return;
		}
		send(IrcMessage('READ', params: [target, 'timestamp=' + t]));
	}

	Future<ClientEndOfWho> who(String mask) {
		var cm = isupport.caseMapping;
		var future = _lastWhoFuture.catchError((_) => null).then((_) {
			send(IrcMessage('WHO', params: [mask]));
			return messages.firstWhere((msg) {
				return msg.cmd == RPL_ENDOFWHO && cm(msg.params[1]) == cm(mask);
			}).timeout(Duration(seconds: 30));
		}).then((ClientMessage msg) {
			var replies = _pendingWhoReplies;
			_pendingWhoReplies = [];
			return ClientEndOfWho(msg, replies, batch: msg.batch);
		});
		_lastWhoFuture = future;
		return future;
	}
}

class ClientMessage extends IrcMessage {
	final ClientBatch? batch;

	ClientMessage(IrcMessage msg, { this.batch }) :
		super(msg.cmd, params: msg.params, tags: msg.tags, prefix: msg.prefix);

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

class ClientEndOfWho extends ClientMessage {
	final UnmodifiableListView<ClientMessage> replies;

	ClientEndOfWho(IrcMessage msg, List<ClientMessage> replies, { ClientBatch? batch }) :
		this.replies = UnmodifiableListView(replies),
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
