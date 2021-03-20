import 'dart:async';
import 'dart:convert';
import 'dart:io';

const RPL_WELCOME = '001';
const RPL_NOTOPIC = '331';
const RPL_TOPIC = '332';

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

class IRCMessage {
	IRCPrefix? prefix;
	String cmd;
	List<String> params;

	IRCMessage(this.cmd, { this.params = const [], this.prefix });

	static IRCMessage parse(String s) {
		s = s.trim();

		IRCPrefix? prefix = null;
		if (s.startsWith(':')) {
			var i = s.indexOf(' ');
			if (i < 0) {
				throw FormatException('Expected a space after prefix');
			}
			prefix = IRCPrefix.parse(s.substring(1, i));
			s = s.substring(i + 1);
		}

		String cmd;
		List<String> params = [];
		var i = s.indexOf(' ');
		if (i < 0) {
			cmd = s;
		} else {
			cmd = s.substring(0, i);
			s = s.substring(i + 1);

			while (true) {
				if (s.startsWith(':')) {
					params.add(s.substring(1));
					break;
				}

				var i = s.indexOf(' ');
				if (i < 0) {
					params.add(s);
					break;
				}

				params.add(s.substring(0, i));
				s = s.substring(i + 1);
			}
		}

		return IRCMessage(cmd.toUpperCase(), params: params, prefix: prefix);
	}

	String toString() {
		var s = '';
		if (prefix != null) {
			s += ':' + prefix!.toString() + ' ';
		}
		s += cmd;
		if (params.length > 0) {
			var last = params[params.length - 1];
			if (params.length > 1) {
				s += ' ' + params.getRange(0, params.length - 1).join(' ');
			}
			s += ' :' + last;
		}
		return s;
	}
}

class IRCPrefix {
	String name;
	String? user;
	String? host;

	IRCPrefix(this.name, { this.user, this.host });

	static IRCPrefix parse(String s) {
		var i = s.indexOf('@');
		if (i < 0) {
			return IRCPrefix(s);
		}

		var host = s.substring(i + 1);
		s = s.substring(0, i);

		i = s.indexOf('!');
		if (i < 0) {
			return IRCPrefix(s, host: host);
		}

		var name = s.substring(0, i);
		var user = s.substring(i + 1);
		return IRCPrefix(name, user: user, host: host);
	}

	String toString() {
		if (host == null) {
			return name;
		}
		if (user == null) {
			return name + '@' + host!;
		}
		return name + '!' + user! + '@' + host!;
	}
}
