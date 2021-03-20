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

enum ClientState { disconnected, connecting, connected }

class Client {
	final ConnectParams params;
	String nick = '';

	Socket? _socket;
	StreamController<IRCMessage> _messagesController = StreamController.broadcast();

	Stream<IRCMessage> get messages => _messagesController.stream;

	Client({ required this.params }) {
		_connect();
	}

	_connect() {
		Future<Socket> socketFuture;
		if (params.tls) {
			socketFuture = SecureSocket.connect(
				params.host,
				params.port,
				supportedProtocols: ['irc'],
			);
		} else {
			socketFuture = Socket.connect(params.host, params.port);
		}

		socketFuture.then((socket) {
			print('Connection opened');
			_socket = socket;

			socket.done.then((_) {
				print('Connection closed');
			});

			var text = utf8.decoder.bind(socket);
			var lines = text.transform(const LineSplitter());

			lines.listen((l) {
				var msg = IRCMessage.parse(l);
				_handleMessage(msg);
			});

			_register();
		});
	}

	_register() {
		nick = params.nick;

		if (params.pass != null) {
			send(IRCMessage('PASS', params: [params.pass!]));
		}
		send(IRCMessage('NICK', params: [params.nick]));
		send(IRCMessage('USER', params: [params.nick, '0', '*', params.nick]));
	}

	_handleMessage(IRCMessage msg) {
		print('Received: ' + msg.toString());

		switch (msg.cmd) {
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
	}

	send(IRCMessage msg) {
		if (_socket == null) {
			return Future.error(SocketException.closed());
		}
		print('Sent: ' + msg.toString());
		return _socket!.write(msg.toString() + '\r\n');
	}
}
