import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';

import 'database.dart';
import 'irc.dart';

// This file contains models. Models are data structures which are can be
// listened to by UI elements so that the UI is updated whenever they change.

class NetworkListModel extends ChangeNotifier {
	final List<NetworkModel> _networks = [];

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

	NetworkModel? byId(int id) {
		for (var network in networks) {
			if (network.networkEntry.id == id) {
				return network;
			}
		}
		return null;
	}
}

enum NetworkState { offline, connecting, registering, synchronizing, online }

/// A model representing an IRC network.
///
/// It's constructed from two database types: [ServerEntry] and [NetworkEntry].
class NetworkModel extends ChangeNotifier {
	final ServerEntry serverEntry;
	final NetworkEntry networkEntry;

	NetworkState _state = NetworkState.offline;
	String? _upstreamName;
	BouncerNetworkModel? _bouncerNetwork;
	String _nickname;
	String _realname;

	NetworkModel(this.serverEntry, this.networkEntry, String nickname, String realname) :
			_nickname = nickname,
			_realname = realname {
		assert(serverEntry.id != null);
		assert(networkEntry.id != null);
		_upstreamName = networkEntry.isupport.network;
	}

	int get serverId => serverEntry.id!;
	int get networkId => networkEntry.id!;

	NetworkState get state => _state;
	String? get upstreamName => _upstreamName;
	BouncerNetworkModel? get bouncerNetwork => _bouncerNetwork;
	String get nickname => _nickname;
	String get realname => _realname;

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

	set bouncerNetwork(BouncerNetworkModel? network) {
		_bouncerNetwork = network;
		notifyListeners();
	}

	set nickname(String nickname) {
		_nickname = nickname;
		notifyListeners();
	}

	set realname(String realname) {
		_realname = realname;
		notifyListeners();
	}
}

class BouncerNetworkListModel extends ChangeNotifier {
	final Map<String, BouncerNetworkModel> _networks = {};

	UnmodifiableMapView<String, BouncerNetworkModel> get networks => UnmodifiableMapView(_networks);

	void add(BouncerNetworkModel network) {
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

/// A model representing an IRC network from the point-of-view of the bouncer.
///
/// This is different from [NetworkModel] which provides data from the
/// point-of-view of the client. For instance, the client may be connected to
/// the bouncer while the bouncer is disconnected from the upstream network.
class BouncerNetworkModel extends ChangeNotifier {
	final String id;
	String? _name;
	String? _host;
	int? _port;
	bool? _tls;
	String? _nickname;
	String? _username;
	String? _realname;
	String? _pass;
	BouncerNetworkState _state = BouncerNetworkState.disconnected;
	String? _error;

	BouncerNetworkModel(this.id, Map<String, String?> attrs) {
		setAttrs(attrs);
	}

	String? get name => _name;
	String? get host => _host;
	int? get port => _port;
	bool? get tls => _tls;
	String? get nickname => _nickname;
	String? get username => _username;
	String? get realname => _realname;
	String? get pass => _pass;
	BouncerNetworkState get state => _state;
	String? get error => _error;

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
			case 'error':
				_error = kv.value;
				break;
			case 'port':
				_port = kv.value != null ? int.tryParse(kv.value!) : null;
				break;
			case 'tls':
				_tls = kv.value == '1';
				break;
			case 'nickname':
				_nickname = kv.value;
				break;
			case 'username':
				_username = kv.value;
				break;
			case 'realname':
				_realname = kv.value;
				break;
			case 'pass':
				_pass = kv.value;
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
		name = cm(name);

	BufferKey.fromBuffer(BufferModel buffer, CaseMapping cm) :
		name = cm(buffer.name),
		network = buffer.network;

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
	Map<BufferKey, BufferModel> _buffers = {};
	List<BufferModel> _sorted = [];
	CaseMapping _cm = defaultCaseMapping;

	UnmodifiableListView<BufferModel> get buffers => UnmodifiableListView(_sorted);

	@override
	void dispose() {
		for (var buf in _buffers.values) {
			buf.dispose();
		}
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

	void removeByNetwork(NetworkModel network) {
		_buffers.removeWhere((_, buf) => buf.network == network);
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

	void setPinned(BufferModel buf, bool pinned) {
		buf.pinned = pinned;
		_rebuildSorted();
		notifyListeners();
	}

	void setMuted(BufferModel buf, bool muted) {
		buf.muted = muted;
		_rebuildSorted();
		notifyListeners();
	}

	void _rebuildSorted() {
		var l = [..._buffers.values];
		l.sort((a, b) {
			if (a.pinned != b.pinned) {
				return a.pinned ? -1 : 1;
			}
			if (a.muted != b.muted) {
				return a.muted ? 1 : -1;
			}
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

/// A model representing a "buffer".
///
/// A buffer holds a list of IRC messages. It's often called a "conversation".
/// A buffer's target can be a channel, a nickname or a server name.
class BufferModel extends ChangeNotifier {
	final BufferEntry entry;
	final NetworkModel network;
	int _unreadCount = 0;
	String? _lastDeliveredTime;
	bool _messageHistoryLoaded = false;
	List<MessageModel> _messages = [];
	final Map<String, Timer> _typing = {};

	// Kept in sync by BufferPageState
	bool focused = false;

	// For channels only
	bool _joining = false;
	bool _joined = false;
	MemberListModel? _members;

	// For users only
	bool? _online;
	bool? _away;

	UnmodifiableListView<MessageModel> get messages => UnmodifiableListView(_messages);

	BufferModel({ required this.entry, required this.network }) {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	String get name => entry.name;
	int get unreadCount => _unreadCount;
	String? get lastDeliveredTime => _lastDeliveredTime;
	bool get messageHistoryLoaded => _messageHistoryLoaded;
	bool get pinned => entry.pinned;
	bool get muted => entry.muted;

	String? get topic => entry.topic;
	bool get joining => _joining;
	bool get joined => _joined;
	MemberListModel? get members => _members;

	bool? get online => _online;
	bool? get away => _away;

	String? get realname {
		if (entry.realname == null || isStubRealname(entry.realname!, name)) {
			return null;
		}
		return entry.realname!;
	}

	set topic(String? topic) {
		entry.topic = topic;
		notifyListeners();
	}

	set joining(bool joining) {
		_joining = joining;
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

	set pinned(bool pinned) {
		entry.pinned = pinned;
		notifyListeners();
	}

	set muted(bool muted) {
		entry.muted = muted;
		notifyListeners();
	}

	set members(MemberListModel? members) {
		_members = members;
		notifyListeners();
	}

	set realname(String? realname) {
		entry.realname = realname;
		notifyListeners();
	}

	set online(bool? online) {
		_online = online;
		notifyListeners();
	}

	set away(bool? away) {
		_away = away;
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

	List<String> get typing {
		var typing = _typing.keys.toList();
		typing.sort();
		return typing;
	}

	void setTyping(String member, bool typing) {
		_typing[member]?.cancel();
		if (typing) {
			_typing[member] = Timer(Duration(seconds: 6), () {
				_typing.remove(member);
				notifyListeners();
			});
		} else {
			_typing.remove(member);
		}
		notifyListeners();
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

String networkStateDescription(NetworkState state) {
	switch (state) {
		case NetworkState.offline:
			return 'Disconnected';
		case NetworkState.connecting:
			return 'Connecting…';
		case NetworkState.registering:
			return 'Logging in…';
		case NetworkState.synchronizing:
			return 'Synchronizing…';
		case NetworkState.online:
			return 'Connected';
	}
}

String bouncerNetworkStateDescription(BouncerNetworkState state) {
	switch (state) {
		case BouncerNetworkState.disconnected:
			return 'Bouncer disconnected from network';
		case BouncerNetworkState.connecting:
			return 'Bouncer connecting to network…';
		case BouncerNetworkState.connected:
			return 'Connected';
	}
}
