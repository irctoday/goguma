import 'dart:collection';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

ConnectParams connectParamsFromServerEntry(ServerEntry entry) {
	SaslPlainCredentials? saslPlain = null;
	if (entry.saslPlainPassword != null) {
		saslPlain = SaslPlainCredentials(entry.nick!, entry.saslPlainPassword!);
	}

	return ConnectParams(
		host: entry.host,
		port: entry.port ?? (entry.tls ? 6697 : 6667),
		tls: entry.tls,
		nick: entry.nick!, // TODO: add a fallback
		pass: entry.pass,
		saslPlain: saslPlain,
	);
}

class ClientController {
	Map<ServerModel, Client> _clients = Map();

	final DB _db;
	final BufferListModel _bufferList;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_clients.values);

	ClientController(DB db, BufferListModel bufferList) :
		_db = db,
		_bufferList = bufferList;

	void add(Client client, ServerModel server) {
		_clients[server] = client;

		server.state = client.state;
		server.network = client.isupport.network;

		client.states.listen((state) {
			server.state = state;
		});

		var messagesSubscription;
		messagesSubscription = client.messages.listen((msg) {
			var future = _handleMessage(client, server, msg);
			if (future != null) {
				messagesSubscription.pause();
				future.whenComplete(() => messagesSubscription.resume());
			}
		});
	}

	Future<void>? _handleMessage(Client client, ServerModel server, IRCMessage msg) {
		switch (msg.cmd) {
		case RPL_ISUPPORT:
			server.network = client.isupport.network;
			_bufferList.setCaseMapping(client.isupport.caseMapping);
			break;
		case 'JOIN':
			var channel = msg.params[0];
			if (!client.isMyNick(msg.prefix!.name)) {
				break;
			}
			return _createBuffer(channel, server);
		case RPL_TOPIC:
			var channel = msg.params[1];
			var topic = msg.params[2];
			_bufferList.get(channel, server)?.subtitle = topic;
			break;
		case RPL_NOTOPIC:
			var channel = msg.params[1];
			_bufferList.get(channel, server)?.subtitle = null;
			break;
		case 'TOPIC':
			var channel = msg.params[0];
			String? topic = null;
			if (msg.params.length > 1) {
				topic = msg.params[1];
			}
			_bufferList.get(channel, server)?.subtitle = topic;
			break;
		case 'PRIVMSG':
		case 'NOTICE':
			var target = msg.params[0];
			Future<BufferModel> bufFuture;
			if (client.isMyNick(target)) {
				bufFuture = _createBuffer(msg.prefix!.name, server);
			} else {
				var buf = _bufferList.get(target, server);
				if (buf == null) {
					break;
				}
				bufFuture = Future.value(buf);
			}
			return bufFuture.then((buf) {
				return _db.storeMessage(MessageEntry(msg, buf.id)).then((entry) {
					if (buf.messageHistoryLoaded) {
						buf.addMessage(MessageModel(entry: entry, buffer: buf));
					}
					if (!client.isMyNick(msg.prefix!.name)) {
						buf.unreadCount++;
					}
					_bufferList.bumpLastDeliveredTime(buf, entry.time);
				});
			});
		}
		return null;
	}

	Future<BufferModel> _createBuffer(String name, ServerModel server) {
		var buffer = _bufferList.get(name, server);
		if (buffer != null) {
			return Future.value(buffer);
		}

		var entry = BufferEntry(name: name, server: server.id);
		return _db.storeBuffer(entry).then((_) {
			var buffer = BufferModel(entry: entry, server: server);
			_bufferList.add(buffer);
			return buffer;
		});
	}

	Client get(ServerModel server) {
		return _clients[server]!;
	}

	void disconnectAll() {
		_clients.values.forEach((client) => client.disconnect());
		_bufferList.clear();
	}
}
