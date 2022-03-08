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
	String? _upstreamName;
	BouncerNetwork? _bouncerNetwork;

	NetworkModel(this.serverEntry, this.networkEntry) {
		assert(serverEntry.id != null);
		assert(networkEntry.id != null);
	}

	int get serverId => serverEntry.id!;
	int get networkId => networkEntry.id!;

	NetworkState get state => _state;
	String? get upstreamName => _upstreamName;
	BouncerNetwork? get bouncerNetwork => _bouncerNetwork;

	String get displayName {
		// If the user has set a custom bouncer network name, use that
		var bouncerNetworkName = bouncerNetwork?.name;
		var bouncerNetworkHost = bouncerNetwork?.host;
		if (bouncerNetworkName != null && bouncerNetworkName != bouncerNetworkHost) {
			return bouncerNetworkName;
		}
		return _upstreamName ?? bouncerNetwork?.host ?? serverEntry.host;
	}

	set state(NetworkState state) {
		if (state == _state) {
			return;
		}
		_state = state;
		notifyListeners();
	}

	set upstreamName(String? name) {
		if (name == _upstreamName) {
			return;
		}
		_upstreamName = name;
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
	String? _host;
	BouncerNetworkState _state = BouncerNetworkState.disconnected;

	BouncerNetwork(this.id, Map<String, String?> attrs) {
		setAttrs(attrs);
	}

	String? get name => _name;
	String? get host => _host;
	BouncerNetworkState get state => _state;

	void setAttrs(Map<String, String?> attrs) {
		for (var kv in attrs.entries) {
			switch (kv.key) {
			case 'name':
				_name = kv.value;
				break;
			case 'host':
				_host = kv.value;
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

	BufferModel? byId(int id) {
		for (var buffer in buffers) {
			if (buffer.id == id) {
				return buffer;
			}
		}
		return null;
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
	int _unreadCount = 0;
	String? _lastDeliveredTime;
	bool _messageHistoryLoaded = false;
	List<MessageModel> _messages = [];

	// Kept in sync by BufferPageState
	bool focused = false;

	// For channels only
	String? _topic;
	bool _joined = false;
	MemberListModel? _members;

	// For users only
	String? _realname;
	bool? _online;

	UnmodifiableListView<MessageModel> get messages => UnmodifiableListView(_messages);

	BufferModel({ required this.entry, required this.network }) {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	String get name => entry.name;
	int get unreadCount => _unreadCount;
	String? get lastDeliveredTime => _lastDeliveredTime;
	bool get messageHistoryLoaded => _messageHistoryLoaded;

	String? get topic => _topic;
	bool get joined => _joined;
	MemberListModel? get members => _members;

	bool? get online => _online;

	String? get realname {
		if (_realname == null || _realname == name) {
			return null;
		}

		// Since the realname is mandatory, many clients set a meaningless one.
		switch (_realname!.toLowerCase()) {
		case 'realname':
		case 'unknown':
		case 'fullname':
			return null;
		}

		return _realname;
	}

	set topic(String? topic) {
		_topic = topic;
		notifyListeners();
	}

	set joined(bool joined) {
		_joined = joined;
		notifyListeners();
	}

	set unreadCount(int n) {
		_unreadCount = n;
		notifyListeners();
	}

	set members(MemberListModel? members) {
		_members = members;
		notifyListeners();
	}

	set realname(String? realname) {
		_realname = realname;
		notifyListeners();
	}

	set online(bool? online) {
		_online = online;
		notifyListeners();
	}

	void addMessages(Iterable<MessageModel> msgs, { bool append = false }) {
		assert(messageHistoryLoaded);
		if (append) {
			_messages.addAll(msgs);
		} else {
			// TODO: optimize this case
			_messages.addAll(msgs);
			_messages.sort(_compareMessageModels);
		}
		notifyListeners();
	}

	void populateMessageHistory(List<MessageModel> l) {
		assert(!messageHistoryLoaded);
		assert(_messages.isEmpty);
		// The messages passed here must be already sorted by the caller
		_messages = l;
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

int _compareMessageModels(MessageModel a, MessageModel b) {
	if (a.entry.time != b.entry.time) {
		return a.entry.time.compareTo(b.entry.time);
	}
	return a.id.compareTo(b.id);
}

class MessageModel {
	final MessageEntry entry;

	MessageModel({ required this.entry }) {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	IrcMessage get msg => entry.msg;
}

class MemberListModel extends ChangeNotifier {
	final IrcNameMap<String> _members;

	MemberListModel(CaseMapping cm) : _members = IrcNameMap(cm);

	UnmodifiableMapView<String, String> get members => UnmodifiableMapView(_members);

	void set(String nick, String prefix) {
		_members[nick] = prefix;
		notifyListeners();
	}

	void remove(String nick) {
		_members.remove(nick);
		notifyListeners();
	}
}
