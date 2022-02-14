import 'dart:collection';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

ConnectParams connectParamsFromServerEntry(ServerEntry entry) {
	return ConnectParams(
		host: entry.host,
		port: entry.port ?? (entry.tls ? 6697 : 6667),
		tls: entry.tls,
		nick: entry.nick!, // TODO: add a fallback
		pass: entry.pass,
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

		client.messages.listen((msg) {
			switch (msg.cmd) {
			case RPL_ISUPPORT:
				server.network = client.isupport.network;
				break;
			case 'JOIN':
				var channel = msg.params[0];
				if (msg.prefix?.name != client.nick) {
					break;
				}
				_createBuffer(channel, server);
				break;
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
				var bufFuture;
				if (target == client.nick) {
					bufFuture = _createBuffer(target, server);
				} else {
					bufFuture = _bufferList.get(target, server);
				}
				bufFuture.then((buf) => buf?.addMessage(msg));
				break;
			}
		});
	}

	Future<BufferModel> _createBuffer(String name, ServerModel server) {
		var buffer = _bufferList.get(name, server);
		if (buffer != null) {
			return Future.value(buffer);
		}

		var entry = BufferEntry(name: name, server: server.entry.id!);
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
