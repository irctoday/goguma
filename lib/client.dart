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

enum ClientState { disconnected, connecting, registering, registered }

const _permanentCaps = [
	'batch',
	'echo-message',
	'message-tags',
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
	String nick;
	IRCPrefix? serverPrefix;
	ClientState state = ClientState.disconnected;
	final IRCCapRegistry caps = IRCCapRegistry();
	final IRCIsupportRegistry isupport = IRCIsupportRegistry();

	final int _id;
	Socket? _socket;
	StreamController<IRCMessage> _messagesController = StreamController.broadcast();
	StreamController<ClientState> _statesController = StreamController.broadcast();
	StreamController<ClientBatch> _batchesController = StreamController.broadcast();
	Timer? _reconnectTimer;
	bool _autoReconnect = true;
	Map<String, ClientBatch> _batches = Map();

	Stream<IRCMessage> get messages => _messagesController.stream;
	Stream<ClientState> get states => _statesController.stream;
	Stream<ClientBatch> get batches => _batchesController.stream;

	Client(this.params) : _id = _nextClientId++, nick = params.nick;

	Future<void> connect() {
		_reconnectTimer?.cancel();
		_setState(ClientState.connecting);

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

			socket.done.then((_) {
				_log('Connection closed');
			}).catchError((err) {
				_log('Connection error: ' + err.toString());
				_messagesController.addError(err);
				_statesController.addError(err);
				_batchesController.addError(err);
			}).whenComplete(() {
				_socket = null;
				caps.clear();
				isupport.clear();
				_batches.clear();

				_setState(ClientState.disconnected);
			});

			var text = utf8.decoder.bind(socket);
			var lines = text.transform(const LineSplitter());

			lines.listen((l) {
				var msg = IRCMessage.parse(l);
				_handleMessage(msg);
			});

			return _register();
		});
	}

	_log(String s) {
		print('[${_id}] ${s}');
	}

	_setState(ClientState state) {
		if (this.state == state) {
			return;
		}

		this.state = state;

		if (!_statesController.isClosed) {
			_statesController.add(state);
		}

		if (state == ClientState.disconnected && _autoReconnect) {
			_reconnectTimer?.cancel();

			_log('Reconnecting in 10s');
			_reconnectTimer = Timer(Duration(seconds: 10), () {
				connect();
			});
		}
	}

	Future<void> _register() {
		nick = params.nick;
		_setState(ClientState.registering);

		var caps = [..._permanentCaps];
		if (params.bouncerNetId == null) {
			caps.add('soju.im/bouncer-networks-notify');
		}

		send(IRCMessage('CAP', params: ['LS', '302']));
		if (params.pass != null) {
			send(IRCMessage('PASS', params: [params.pass!]));
		}
		send(IRCMessage('NICK', params: [params.nick]));
		send(IRCMessage('USER', params: [params.nick, '0', '*', params.nick]));
		for (var cap in caps) {
			send(IRCMessage('CAP', params: ['REQ', cap]));
		}
		_authenticate();
		if (params.bouncerNetId != null) {
			send(IRCMessage('BOUNCER', params: ['BIND', params.bouncerNetId!]));
		}
		send(IRCMessage('CAP', params: ['END']));

		var saslSuccess = false;
		return messages.firstWhere((msg) {
			switch (msg.cmd) {
			case RPL_WELCOME:
				if (params.saslPlain != null && !saslSuccess) {
					_socket?.close();
					throw Exception('Server doesn\'t support SASL authentication');
				}
				return true;
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
				throw IRCException(msg);
			case RPL_SASLSUCCESS:
				saslSuccess = true;
				break;
			}
			return false;
		}).timeout(Duration(seconds: 15), onTimeout: () {
			throw TimeoutException('Connection registration timed out');
		});
	}

	_handleMessage(IRCMessage msg) {
		_log('<- ' + msg.toString());

		ClientBatch? msgBatch = null;
		if (msg.tags.containsKey('batch')) {
			msgBatch = _batches[msg.tags['batch']];
		}
		msgBatch?._messages.add(msg);

		switch (msg.cmd) {
		case 'CAP':
			caps.parse(msg);

			if (msg.params[1].toUpperCase() != 'NEW') {
				break;
			}

			for (var cap in _permanentCaps) {
				if (caps.available.containsKey(cap) && !caps.enabled.contains(cap)) {
					send(IRCMessage('CAP', params: ['REQ', cap]));
				}
			}
			break;
		case RPL_WELCOME:
			_log('Registration complete');
			_setState(ClientState.registered);
			serverPrefix = msg.prefix;
			nick = msg.params[0];
			break;
		case RPL_ISUPPORT:
			isupport.parse(msg.params.sublist(1, msg.params.length - 1));
			break;
		case 'NICK':
			if (isMyNick(msg.prefix!.name)) {
				nick = msg.params[0];
			}
			break;
		case 'PING':
			send(IRCMessage('PONG', params: msg.params));
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
		}

		if (!_messagesController.isClosed) {
			_messagesController.add(msg);
		}
	}

	disconnect() {
		_autoReconnect = false;
		_reconnectTimer?.cancel();
		_socket!.close();
		_messagesController.close();
		_statesController.close();
		_batchesController.close();
	}

	send(IRCMessage msg) {
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
		send(IRCMessage('AUTHENTICATE', params: ['PLAIN']));

		var creds = params.saslPlain!;
		var payload = [0, ...utf8.encode(creds.username), 0, ...utf8.encode(creds.password)];
		send(IRCMessage('AUTHENTICATE', params: [base64.encode(payload)]));
	}

	Future<List<ChatHistoryTarget>> fetchChatHistoryTargets(String t1, String t2) {
		// TODO: paging
		send(IRCMessage(
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

	Future<void> ping() {
		var token = 'goguma-${_nextPingSerial}';
		send(IRCMessage('PING', params: [token]));
		_nextPingSerial++;

		return messages.firstWhere((msg) {
			return msg.cmd == 'PONG' && msg.params[1] == token;
		}).timeout(Duration(seconds: 15), onTimeout: () {
			_socket?.close();
			throw TimeoutException('Ping timed out');
		});
	}
}

class ClientBatch {
	final String type;
	final UnmodifiableListView<String> params;
	final ClientBatch? parent;

	final List<IRCMessage> _messages = [];

	UnmodifiableListView<IRCMessage> get messages => UnmodifiableListView(_messages);

	ClientBatch(this.type, List<String> params, this.parent) : this.params = UnmodifiableListView(params);
}

class ChatHistoryTarget {
	final String name;
	final String time;

	ChatHistoryTarget(this.name, this.time);
}
