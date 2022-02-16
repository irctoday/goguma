import 'dart:async';
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
	'echo-message',
	'message-tags',
	'sasl',
	'server-time',

	'draft/chathistory',

	'soju.im/bouncer-networks',
];

class Client {
	final ConnectParams params;
	String nick;
	IRCPrefix? serverPrefix;
	ClientState state = ClientState.disconnected;
	final IRCCapRegistry caps = IRCCapRegistry();
	final IRCIsupportRegistry isupport = IRCIsupportRegistry();

	Socket? _socket;
	StreamController<IRCMessage> _messagesController = StreamController.broadcast();
	StreamController<ClientState> _statesController = StreamController.broadcast();
	Timer? _reconnectTimer;
	bool _autoReconnect = true;

	Stream<IRCMessage> get messages => _messagesController.stream;
	Stream<ClientState> get states => _statesController.stream;

	Client(this.params) : nick = params.nick;

	Future<void> connect() {
		_setState(ClientState.connecting);

		print('Connecting to ' + params.host + '...');

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
			print('Connection failed: ' + err.toString());
			_setState(ClientState.disconnected);
			throw err;
		}).then((socket) {
			print('Connection opened');
			_socket = socket;

			socket.done.then((_) {
				print('Connection closed');
			}).catchError((err) {
				print('Connection error: ' + err.toString());
			}).whenComplete(() {
				_socket = null;
				caps.clear();
				isupport.clear();

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

			print('Reconnecting in 10s');
			_reconnectTimer = Timer(Duration(seconds: 10), () {
				_reconnectTimer = null;
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
		for (var cap in caps) {
			send(IRCMessage('CAP', params: ['REQ', cap]));
		}
		if (params.pass != null) {
			send(IRCMessage('PASS', params: [params.pass!]));
		}
		send(IRCMessage('NICK', params: [params.nick]));
		send(IRCMessage('USER', params: [params.nick, '0', '*', params.nick]));
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
		print('Received: ' + msg.toString());

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
			print('Registration complete');
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
		}

		if (!_messagesController.isClosed) {
			_messagesController.add(msg);
		}
	}

	disconnect() {
		_autoReconnect = false;
		_socket!.close();
		_messagesController.close();
		_statesController.close();
	}

	send(IRCMessage msg) {
		if (_socket == null) {
			return Future.error(SocketException.closed());
		}
		print('Sent: ' + msg.toString());
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

		print('Starting SASL PLAIN authentication');
		send(IRCMessage('AUTHENTICATE', params: ['PLAIN']));

		var creds = params.saslPlain!;
		var payload = [0, ...utf8.encode(creds.username), 0, ...utf8.encode(creds.password)];
		send(IRCMessage('AUTHENTICATE', params: [base64.encode(payload)]));
	}
}
