import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'irc.dart';

class ConnectParams {
	String host;
	int port;
	bool tls;
	String nick;
	String? pass;

	ConnectParams({ required this.host, this.port = 6697, this.tls = true, required this.nick, this.pass });
}

enum ClientState { disconnected, connecting, registering, registered }

class Client {
	final ConnectParams params;
	String nick;
	IRCPrefix? serverPrefix;
	ClientState state = ClientState.disconnected;

	Socket? _socket;
	StreamController<IRCMessage> _messagesController = StreamController.broadcast();
	Map<String, String?> _availableCaps = Map();

	Stream<IRCMessage> get messages => _messagesController.stream;

	Client({ required this.params }) : nick = params.nick {}

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
				_setState(ClientState.disconnected);
				_socket = null;
				_availableCaps.clear();
				// TODO: try to reconnect
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
		this.state = state;
	}

	Future<void> _register() {
		nick = params.nick;
		_setState(ClientState.registering);

		send(IRCMessage('CAP', params: ['LS', '302']));
		if (params.pass != null) {
			send(IRCMessage('PASS', params: [params.pass!]));
		}
		send(IRCMessage('NICK', params: [params.nick]));
		send(IRCMessage('USER', params: [params.nick, '0', '*', params.nick]));

		return messages.firstWhere((msg) {
			switch (msg.cmd) {
			case RPL_WELCOME:
				return true;
			case ERR_NICKLOCKED:
			case ERR_PASSWDMISMATCH:
			case ERR_ERRONEUSNICKNAME:
			case ERR_NICKNAMEINUSE:
			case ERR_NICKCOLLISION:
			case ERR_UNAVAILRESOURCE:
			case ERR_NOPERMFORHOST:
			case ERR_YOUREBANNEDCREEP:
				disconnect();
				throw IRCException(msg);
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
			_handleCap(msg);
			break;
		case RPL_WELCOME:
			print('Registration complete');
			_setState(ClientState.registered);
			serverPrefix = msg.prefix;
			nick = msg.params[0];
			break;
		case 'NICK':
			if (msg.prefix?.name == nick) {
				nick = msg.params[0];
			}
			break;
		case 'PING':
			send(IRCMessage('PONG', params: msg.params));
			break;
		}

		_messagesController.add(msg);
	}

	_handleCap(IRCMessage msg) {
		var subcommand = msg.params[1].toUpperCase();
		var params = msg.params.sublist(2);
		switch (subcommand) {
		case 'LS':
			_addAvailableCaps(params[params.length - 1]);
			if (params[0] != '*') {
				send(IRCMessage('CAP', params: ['END']));
			}
			break;
		case 'NEW':
			_addAvailableCaps(params[0]);
			break;
		case 'DEL':
			for (var cap in params[0].split(' ')) {
				_availableCaps.remove(cap.toLowerCase());
			}
			break;
		default:
			throw FormatException('Unknown CAP subcommand: ' + subcommand);
		}
	}

	_addAvailableCaps(String caps) {
		for (var s in caps.split(' ')) {
			var i = s.indexOf('=');
			String k = s;
			String? v = null;
			if (i >= 0) {
				k = s.substring(0, i);
				v = s.substring(i + 1);
			}
			_availableCaps[k.toLowerCase()] = v;
		}
	}

	disconnect() {
		_socket?.close();
		_messagesController.close();
	}

	send(IRCMessage msg) {
		if (_socket == null) {
			return Future.error(SocketException.closed());
		}
		print('Sent: ' + msg.toString());
		return _socket!.write(msg.toString() + '\r\n');
	}
}
