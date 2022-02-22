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
	Map<NetworkModel, ClientController> _controllers = Map();

	final DB _db;
	final NetworkListModel _networkList;
	final BufferListModel _bufferList;
	final BouncerNetworkListModel _bouncerNetworkList;

	UnmodifiableListView<Client> get clients => UnmodifiableListView(_controllers.values.map((cc) => cc.client));

	ClientProvider(DB db, NetworkListModel networkList, BufferListModel bufferList, BouncerNetworkListModel bouncerNetworkList) :
		_db = db,
		_networkList = networkList,
		_bufferList = bufferList,
		_bouncerNetworkList = bouncerNetworkList;

	void add(Client client, NetworkModel network) {
		_controllers[network] = ClientController(this, client, network);
	}

	Client get(NetworkModel network) {
		return _controllers[network]!.client;
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
	final NetworkModel _network;

	String? _prevLastDeliveredTime;

	Client get client => _client;
	NetworkModel get network => _network;

	DB get _db => _provider._db;
	NetworkListModel get _networkList => _provider._networkList;
	BufferListModel get _bufferList => _provider._bufferList;
	BouncerNetworkListModel get _bouncerNetworkList => _provider._bouncerNetworkList;

	ClientController(ClientProvider provider, Client client, NetworkModel network) :
			_provider = provider,
			_client = client,
			_network = network {
		network.state = client.state;

		client.states.listen((state) {
			network.state = state;

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
			if (buffer.network != network || buffer.lastDeliveredTime == null) {
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
			network.network = client.isupport.network;
			if (client.isupport.bouncerNetId != null) {
				network.bouncerNetwork = _bouncerNetworkList.networks[client.isupport.bouncerNetId!];
			} else {
				network.bouncerNetwork = null;
			}
			_bufferList.setCaseMapping(client.isupport.caseMapping);
			break;
		case RPL_ENDOFMOTD:
		case ERR_NOMOTD:
			// These messages are used to indicate the end of the ISUPPORT list

			// Query latest READ status for user targets
			if (client.caps.enabled.contains('soju.im/read')) {
				for (var buffer in _bufferList.buffers) {
					if (buffer.network == network && !client.isChannel(buffer.name)) {
						client.send(IRCMessage('READ', params: [buffer.name]));
					}
				}
			}

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
			_bufferList.get(channel, network)?.subtitle = topic;
			break;
		case RPL_NOTOPIC:
			var channel = msg.params[1];
			_bufferList.get(channel, network)?.subtitle = null;
			break;
		case 'TOPIC':
			var channel = msg.params[0];
			String? topic = null;
			if (msg.params.length > 1) {
				topic = msg.params[1];
			}
			_bufferList.get(channel, network)?.subtitle = topic;
			break;
		case 'PRIVMSG':
		case 'NOTICE':
			var target = msg.params[0];
			Future<BufferModel> bufFuture;
			if (client.isMyNick(target)) {
				bufFuture = _createBuffer(msg.prefix!.name);
			} else {
				var buf = _bufferList.get(target, network);
				if (buf == null) {
					break;
				}
				bufFuture = Future.value(buf);
			}
			return bufFuture.then((buf) {
				var entry = MessageEntry(msg, buf.id);
				return _db.storeMessages([entry]).then((_) {
					if (buf.messageHistoryLoaded) {
						buf.addMessage(MessageModel(entry: entry));
					}
					if (buf.focused) {
						if (buf.entry.lastReadTime == null || buf.entry.lastReadTime!.compareTo(entry.time) < 0) {
							buf.entry.lastReadTime = entry.time;
							_db.storeBuffer(buf.entry);

							client.setRead(buf.name, buf.entry.lastReadTime!);
						}
					} else if (!client.isMyNick(msg.prefix!.name)) {
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
			var networkMatches = _networkList.networks.where((network) {
				return network.networkEntry.bouncerId == bouncerNetId;
			});
			NetworkModel? childNetwork = networkMatches.isEmpty ? null : networkMatches.first;

			if (attrs == null) {
				// The bouncer network has been removed

				_bouncerNetworkList.remove(bouncerNetId);

				if (childNetwork == null) {
					break;
				}

				var childClient = _provider.get(childNetwork);
				childClient.disconnect();

				_networkList.remove(childNetwork);
				return _db.deleteNetwork(childNetwork.networkId);
			}

			if (bouncerNetwork != null) {
				// The bouncer network has been updated
				bouncerNetwork.setAttrs(attrs);
				break;
			}

			// The bouncer network has been added

			bouncerNetwork = BouncerNetwork(bouncerNetId, attrs);
			_bouncerNetworkList.add(bouncerNetwork);

			if (childNetwork != null) {
				break;
			}

			var networkEntry = NetworkEntry(server: network.serverId, bouncerId: bouncerNetId);
			return _db.storeNetwork(networkEntry).then((networkEntry) {
				var childClient = Client(client.params.replaceBouncerNetId(bouncerNetId));
				var childNetwork = NetworkModel(network.serverEntry, networkEntry);
				_networkList.add(childNetwork);
				_provider.add(childClient, childNetwork);
				childClient.connect();
			});
		case 'READ':
			var target = msg.params[0];
			var bound = msg.params[1];

			if (bound == '*') {
				break;
			}
			if (!bound.startsWith('timestamp=')) {
				throw FormatException('Invalid READ bound: ${msg}');
			}
			var time = bound.replaceFirst('timestamp=', '');

			var buffer = _bufferList.get(target, network);
			if (buffer == null) {
				break;
			}

			if (buffer.entry.lastReadTime != null && time.compareTo(buffer.entry.lastReadTime!) <= 0) {
				break;
			}

			buffer.entry.lastReadTime = time;
			// TODO: recompute unread count from messages
			buffer.unreadCount = 0;
			return _db.storeBuffer(buffer.entry);
		}
		return null;
	}

	Future<BufferModel> _createBuffer(String name) {
		var buffer = _bufferList.get(name, network);
		if (buffer != null) {
			return Future.value(buffer);
		}

		var entry = BufferEntry(name: name, network: network.networkId);
		return _db.storeBuffer(entry).then((_) {
			var buffer = BufferModel(entry: entry, network: network);
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
