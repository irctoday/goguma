import 'client.dart';
import 'irc.dart';
import 'models.dart';

class ClientController {
	Client? client;
	ServerModel? server;

	final BufferListModel _bufferList;

	ClientController(BufferListModel bufferList) : _bufferList = bufferList;

	void connect(ConnectParams params) {
		server = ServerModel();
		client = Client(params: params);

		client!.messages.listen((msg) {
			switch (msg.cmd) {
			case 'JOIN':
				if (msg.prefix?.name != client!.nick) {
					break;
				}
				_bufferList.add(BufferModel(name: msg.params[0], server: server!));
				break;
			case RPL_TOPIC:
				var channel = msg.params[1];
				var topic = msg.params[2];
				_bufferList.get(channel, server!)?.subtitle = topic;
				break;
			case RPL_NOTOPIC:
				var channel = msg.params[1];
				_bufferList.get(channel, server!)?.subtitle = null;
				break;
			case 'TOPIC':
				var channel = msg.params[0];
				String? topic = null;
				if (msg.params.length > 1) {
					topic = msg.params[1];
				}
				_bufferList.get(channel, server!)?.subtitle = topic;
				break;
			case 'PRIVMSG':
			case 'NOTICE':
				var target = msg.params[0];
				_bufferList.get(target, server!)?.addMessage(msg);
				break;
			}
		});
	}

	Client get(ServerModel server) {
		return client!;
	}

	void disconnectAll() {
		client?.disconnect();
		_bufferList.clear();
	}
}
