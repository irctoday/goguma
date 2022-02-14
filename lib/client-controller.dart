import 'client.dart';
import 'irc.dart';
import 'models.dart';

class ClientController {
	Map<ServerModel, Client> _clients = Map();

	final ServerListModel _serverList;
	final BufferListModel _bufferList;

	ClientController(ServerListModel serverList, BufferListModel bufferList) : _serverList = serverList, _bufferList = bufferList;

	ServerModel addServer(ConnectParams params) {
		var server = ServerModel(params.host);
		_serverList.add(server);

		var client = Client(params: params);
		_clients[server] = client;

		client.messages.listen((msg) {
			switch (msg.cmd) {
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

		return server;
	}

	Client get(ServerModel server) {
		return _clients[server]!;
	}

	void disconnectAll() {
		_clients.values.forEach((client) => client.disconnect());
		_serverList.clear();
		_bufferList.clear();
	}
}
