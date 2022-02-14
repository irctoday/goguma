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

	final BufferListModel _bufferList;

	ClientController(BufferListModel bufferList) : _bufferList = bufferList;

	void add(Client client, ServerModel server) {
		_clients[server] = client;

		client.messages.listen((msg) {
			switch (msg.cmd) {
			case RPL_ISUPPORT:
				server.network = client.isupport.network;
				break;
			case 'JOIN':
				if (msg.prefix?.name != client.nick) {
					break;
				}
				_bufferList.add(BufferModel(name: msg.params[0], server: server));
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
				var buf = _bufferList.get(target, server);
				// TODO: put server messages in a buffer, too
				if (buf == null && target == client.nick) {
					buf = BufferModel(name: msg.prefix!.name, server: server);
					_bufferList.add(buf);
				}
				buf?.addMessage(msg);
				break;
			}
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
