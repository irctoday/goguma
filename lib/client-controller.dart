import 'dart:async';
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

class ClientProvider {
	Map<ServerModel, ClientController> _controllers = Map();

	final DB _db;
	final ServerListModel _serverList;
	final BufferListModel _bufferList;
	final BouncerNetworkListModel _bouncerNetworkList;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_controllers.values.map((cc) => cc.client));

	ClientProvider(DB db, ServerListModel serverList, BufferListModel bufferList, BouncerNetworkListModel bouncerNetworkList) :
		_db = db,
		_serverList = serverList,
		_bufferList = bufferList,
		_bouncerNetworkList = bouncerNetworkList;

	void add(Client client, ServerModel server) {
		_controllers[server] = ClientController(this, client, server);
	}

	Client get(ServerModel server) {
		return _controllers[server]!.client;
	}

	void disconnectAll() {
		for (var cc in _controllers.values) {
			cc.client.disconnect();
		}
		_controllers.clear();
		_bufferList.clear();
	}
}

class ClientController {
	final ClientProvider _provider;

	final Client _client;
	final ServerModel _server;

	String? _prevLastDeliveredTime;

	Client get client => _client;
	ServerModel get server => _server;

	DB get _db => _provider._db;
	ServerListModel get _serverList => _provider._serverList;
	BufferListModel get _bufferList => _provider._bufferList;
	BouncerNetworkListModel get _bouncerNetworkList => _provider._bouncerNetworkList;

	ClientController(ClientProvider provider, Client client, ServerModel server) :
			_provider = provider,
			_client = client,
			_server = server {
		server.state = client.state;

		client.states.listen((state) {
			server.state = state;

			if (state == ClientState.connecting) {
				_prevLastDeliveredTime = _getLastDeliveredTime();
			}
		});

		var messagesSub;
		messagesSub = client.messages.listen((msg) {
			var future = _handleMessage(msg);
			if (future != null) {
				messagesSub.pause();
				future.whenComplete(() => messagesSub.resume());
			}
		});
	}

	String? _getLastDeliveredTime() {
		var last = null;
		for (var buffer in _bufferList.buffers) {
			if (buffer.server != server || buffer.lastDeliveredTime == null) {
				continue;
			}
			if (last == null || last!.compareTo(buffer.lastDeliveredTime!) < 0) {
				last = buffer.lastDeliveredTime;
			}
		}
		return last;
	}

	Future<void>? _handleMessage(IRCMessage msg) {
		switch (msg.cmd) {
		case RPL_ISUPPORT:
			server.network = client.isupport.network;
			if (client.isupport.bouncerNetId != null) {
				server.bouncerNetwork = _bouncerNetworkList.networks[client.isupport.bouncerNetId!];
			} else {
				server.bouncerNetwork = null;
			}
			_bufferList.setCaseMapping(client.isupport.caseMapping);
			break;
		case RPL_ENDOFMOTD:
		case ERR_NOMOTD:
			// These messages are used to indicate the end of the ISUPPORT list

			if (_prevLastDeliveredTime != null) {
				_fetchBacklog(_prevLastDeliveredTime!, msg.tags['time'] ?? formatIRCTime(DateTime.now()));
			}
			break;
		case 'JOIN':
			var channel = msg.params[0];
			if (!client.isMyNick(msg.prefix!.name)) {
				break;
			}
			return _createBuffer(channel);
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
				bufFuture = _createBuffer(msg.prefix!.name);
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
						buf.addMessage(MessageModel(entry: entry));
					}
					if (!client.isMyNick(msg.prefix!.name)) {
						buf.unreadCount++;
					}
					_bufferList.bumpLastDeliveredTime(buf, entry.time);
				});
			});
		case 'BOUNCER':
			if (msg.params[0] != 'NETWORK') {
				break;
			}
			if (client.isupport.bouncerNetId != null) {
				break;
			}

			var bouncerNetId = msg.params[1];
			var attrs = msg.params[2] == '*' ? null : parseIRCTags(msg.params[2]);

			var bouncerNetwork = _bouncerNetworkList.networks[bouncerNetId];
			var serverMatches = _serverList.servers.where((server) {
				return server.networkEntry.bouncerId == bouncerNetId;
			});
			ServerModel? childServer = serverMatches.isEmpty ? null : serverMatches.first;

			if (attrs == null) {
				// The bouncer network has been removed

				_bouncerNetworkList.remove(bouncerNetId);

				if (childServer == null) {
					break;
				}

				var childClient = _provider.get(childServer);
				childClient.disconnect();

				_serverList.remove(childServer);
				return _db.deleteNetwork(childServer.networkId);
			}

			if (bouncerNetwork != null) {
				// The bouncer network has been updated
				bouncerNetwork.setAttrs(attrs);
				break;
			}

			// The bouncer network has been added

			bouncerNetwork = BouncerNetwork(bouncerNetId, attrs);
			_bouncerNetworkList.add(bouncerNetwork);

			if (childServer != null) {
				break;
			}

			var networkEntry = NetworkEntry(server: server.id, bouncerId: bouncerNetId);
			return _db.storeNetwork(networkEntry).then((networkEntry) {
				var childClient = Client(client.params.replaceBouncerNetId(bouncerNetId));
				var childServer = ServerModel(server.entry, networkEntry);
				_serverList.add(childServer);
				_provider.add(childClient, childServer);
				childClient.connect();
			});
		}
		return null;
	}

	Future<BufferModel> _createBuffer(String name) {
		var buffer = _bufferList.get(name, server);
		if (buffer != null) {
			return Future.value(buffer);
		}

		var entry = BufferEntry(name: name, network: server.networkId);
		return _db.storeBuffer(entry).then((_) {
			var buffer = BufferModel(entry: entry, server: server);
			_bufferList.add(buffer);
			return buffer;
		});
	}

	void _fetchBacklog(String from, String to) {
		if (!client.caps.enabled.contains('draft/chathistory')) {
			return;
		}

		var max = client.caps.chatHistory!;
		if (max == 0) {
			max = 1000;
		}

		client.fetchChatHistoryTargets(from, to).then((targets) {
			for (var target in targets) {
				client.send(IRCMessage(
					'CHATHISTORY',
					params: ['BETWEEN', target.name, 'timestamp=' + from, 'timestamp=' + to, max.toString()],
				));
			}
		});
	}
}
