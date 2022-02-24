import 'dart:collection';
import 'package:flutter/material.dart';

import 'database.dart';
import 'irc.dart';

class NetworkListModel extends ChangeNotifier {
	List<NetworkModel> _networks = [];

	UnmodifiableListView<NetworkModel> get networks => UnmodifiableListView(_networks);

	void add(NetworkModel network) {
		_networks.add(network);
		notifyListeners();
	}

	void remove(NetworkModel network) {
		_networks.remove(network);
		notifyListeners();
	}

	void clear() {
		_networks.clear();
		notifyListeners();
	}
}

enum NetworkState { offline, connecting, registering, synchronizing, online }

class NetworkModel extends ChangeNotifier {
	final ServerEntry serverEntry;
	final NetworkEntry networkEntry;

	NetworkState _state = NetworkState.offline;
	String? _network;
	BouncerNetwork? _bouncerNetwork;

	NetworkModel(this.serverEntry, this.networkEntry) {
		assert(serverEntry.id != null);
		assert(networkEntry.id != null);
	}

	int get serverId => serverEntry.id!;
	int get networkId => networkEntry.id!;

	NetworkState get state => _state;
	String? get network => _network;
	BouncerNetwork? get bouncerNetwork => _bouncerNetwork;

	set state(NetworkState state) {
		if (state == _state) {
			return;
		}
		_state = state;
		notifyListeners();
	}

	set network(String? network) {
		if (network == _network) {
			return;
		}
		_network = network;
		notifyListeners();
	}

	set bouncerNetwork(BouncerNetwork? network) {
		_bouncerNetwork = network;
		notifyListeners();
	}
}

class BouncerNetworkListModel extends ChangeNotifier {
	Map<String, BouncerNetwork> _networks = Map();

	UnmodifiableMapView get networks => UnmodifiableMapView(_networks);

	void add(BouncerNetwork network) {
		_networks[network.id] = network;
		notifyListeners();
	}

	void remove(String netId) {
		_networks.remove(netId);
		notifyListeners();
	}

	void clear() {
		_networks.clear();
		notifyListeners();
	}
}

enum BouncerNetworkState { connected, connecting, disconnected }

BouncerNetworkState _parseBouncerNetworkState(String s) {
	switch (s) {
	case 'connected':
		return BouncerNetworkState.connected;
	case 'connecting':
		return BouncerNetworkState.connecting;
	case 'disconnected':
		return BouncerNetworkState.disconnected;
	default:
		throw FormatException('Unknown bouncer network state: ' + s);
	}
}

class BouncerNetwork extends ChangeNotifier {
	final String id;
	String? _name;
	BouncerNetworkState _state = BouncerNetworkState.disconnected;

	BouncerNetwork(this.id, Map<String, String?> attrs) {
		setAttrs(attrs);
	}

	String? get name => _name;
	BouncerNetworkState get state => _state;

	void setAttrs(Map<String, String?> attrs) {
		for (var kv in attrs.entries) {
			switch (kv.key) {
			case 'name':
				_name = kv.value;
				break;
			case 'state':
				_state = _parseBouncerNetworkState(kv.value!);
				break;
			}
		}
		notifyListeners();
	}
}

class BufferKey {
	final String name;
	final NetworkModel network;

	BufferKey(String name, this.network, CaseMapping cm) :
		this.name = cm(name);

	BufferKey.fromBuffer(BufferModel buffer, CaseMapping cm) :
		this.name = cm(buffer.name),
		this.network = buffer.network;

	@override
	bool operator ==(Object other) {
		if (identical(this, other)) {
			return true;
		}
		return other is BufferKey && name == other.name && network == other.network;
	}

	@override
	int get hashCode {
		return hashValues(name, network);
	}
}

class BufferListModel extends ChangeNotifier {
	Map<BufferKey, BufferModel> _buffers = Map();
	List<BufferModel> _sorted = [];
	CaseMapping _cm = defaultCaseMapping;

	UnmodifiableListView<BufferModel> get buffers => UnmodifiableListView(_sorted);

	@override
	void dispose() {
		_buffers.values.forEach((buf) => buf.dispose());
		super.dispose();
	}

	void add(BufferModel buf) {
		_buffers[BufferKey.fromBuffer(buf, _cm)] = buf;
		_rebuildSorted();
		notifyListeners();
	}

	void remove(BufferModel buf) {
		_buffers.remove(BufferKey.fromBuffer(buf, _cm));
		_rebuildSorted();
		notifyListeners();
	}

	void clear() {
		_buffers.clear();
		_sorted.clear();
		notifyListeners();
	}

	BufferModel? get(String name, NetworkModel network) {
		return _buffers[BufferKey(name, network, _cm)];
	}

	void bumpLastDeliveredTime(BufferModel buf, String t) {
		if (buf._bumpLastDeliveredTime(t)) {
			_rebuildSorted();
			notifyListeners();
		}
	}

	void _rebuildSorted() {
		var l = [..._buffers.values];
		l.sort((a, b) {
			if (a.lastDeliveredTime != b.lastDeliveredTime) {
				if (a.lastDeliveredTime == null) {
					return 1;
				}
				if (b.lastDeliveredTime == null) {
					return -1;
				}
				return b.lastDeliveredTime!.compareTo(a.lastDeliveredTime!);
			}
			return a.name.compareTo(b.name);
		});
		_sorted = l;
	}

	void setCaseMapping(CaseMapping cm) {
		if (cm == _cm) {
			return;
		}
		_cm = cm;
		_buffers = Map.fromIterables(
			_buffers.values.map((buffer) => BufferKey.fromBuffer(buffer, cm)),
			_buffers.values,
		);
	}
}

class BufferModel extends ChangeNotifier {
	final BufferEntry entry;
	final NetworkModel network;
	String? _subtitle;
	int _unreadCount = 0;
	String? _lastDeliveredTime;
	bool _messageHistoryLoaded = false;
	List<MessageModel> _messages = [];

	// Kept in sync by BufferPageState
	bool focused = false;

	UnmodifiableListView<MessageModel> get messages => UnmodifiableListView(_messages);

	BufferModel({ required this.entry, required this.network, String? subtitle }) : _subtitle = subtitle {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	String get name => entry.name;
	String? get subtitle => _subtitle;
	int get unreadCount => _unreadCount;
	String? get lastDeliveredTime => _lastDeliveredTime;
	bool get messageHistoryLoaded => _messageHistoryLoaded;

	set subtitle(String? subtitle) {
		_subtitle = subtitle;
		notifyListeners();
	}

	set unreadCount(int n) {
		_unreadCount = n;
		notifyListeners();
	}

	void addMessage(MessageModel msg) {
		// TODO: insert at correct position
		_messages.add(msg);
		notifyListeners();
	}

	void populateMessageHistory(List<MessageModel> l) {
		_messages = l + _messages;
		_messageHistoryLoaded = true;
		notifyListeners();
	}

	bool _bumpLastDeliveredTime(String t) {
		if (_lastDeliveredTime != null && _lastDeliveredTime!.compareTo(t) >= 0) {
			return false;
		}
		_lastDeliveredTime = t;
		notifyListeners();
		return true;
	}
}

class MessageModel {
	final MessageEntry entry;

	MessageModel({ required this.entry }) {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	IRCMessage get msg => entry.msg;
}
