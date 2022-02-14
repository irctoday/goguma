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
	final IRCCapRegistry caps = IRCCapRegistry();
	final IRCIsupportRegistry isupport = IRCIsupportRegistry();

	Socket? _socket;
	StreamController<IRCMessage> _messagesController = StreamController.broadcast();
	StreamController<ClientState> _statesController = StreamController.broadcast();

	Stream<IRCMessage> get messages => _messagesController.stream;
	Stream<ClientState> get states => _statesController.stream;

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
				caps.clear();
				isupport.clear();
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
		if (this.state == state) {
			return;
		}
		this.state = state;
		_statesController.add(state);
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
		send(IRCMessage('CAP', params: ['END']));

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
				_socket?.close();
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
			caps.parse(msg);
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

	disconnect() {
		_socket?.close();
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
}
