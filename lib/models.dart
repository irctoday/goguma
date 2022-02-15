import 'dart:collection';
import 'package:flutter/material.dart';

import 'client.dart';
import 'database.dart';
import 'irc.dart';

class ServerListModel extends ChangeNotifier {
	List<ServerModel> _servers = [];

	UnmodifiableListView<ServerModel> get servers => UnmodifiableListView(_servers);

	void add(ServerModel server) {
		_servers.add(server);
		notifyListeners();
	}

	void clear() {
		_servers.clear();
		notifyListeners();
	}
}

class ServerModel extends ChangeNotifier {
	final ServerEntry entry;

	ClientState _state = ClientState.disconnected;
	String? _network;

	ServerModel(this.entry) {
		assert(entry.id != null);
	}

	int get id => entry.id!;

	String? get network => _network;
	ClientState get state => _state;

	set network(String? network) {
		_network = network;
		notifyListeners();
	}

	set state(ClientState state) {
		_state = state;
		notifyListeners();
	}
}

class BufferKey {
	final String name;
	final ServerModel server;

	BufferKey(this.name, this.server);

	@override
	bool operator ==(Object other) {
		if (identical(this, other)) {
			return true;
		}
		return other is BufferKey && name == other.name && server == other.server;
	}

	@override
	int get hashCode {
		return hashValues(name, server);
	}
}

class BufferListModel extends ChangeNotifier {
	Map<BufferKey, BufferModel> _buffers = Map();
	List<BufferModel> _sorted = [];

	UnmodifiableListView<BufferModel> get buffers => UnmodifiableListView(_sorted);

	@override
	void dispose() {
		_buffers.values.forEach((buf) => buf.dispose());
		super.dispose();
	}

	void add(BufferModel buf) {
		_buffers[BufferKey(buf.name, buf.server)] = buf;
		_rebuildSorted();
		notifyListeners();
	}

	void remove(BufferModel buf) {
		_buffers.remove(BufferKey(buf.name, buf.server));
		_rebuildSorted();
		notifyListeners();
	}

	void clear() {
		_buffers.clear();
		_sorted.clear();
		notifyListeners();
	}

	BufferModel? get(String name, ServerModel server) {
		return _buffers[BufferKey(name, server)];
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
}

class BufferModel extends ChangeNotifier {
	final BufferEntry entry;
	final ServerModel server;
	String? _subtitle;
	int _unreadCount = 0;
	String? _lastDeliveredTime;
	bool _messageHistoryLoaded = false;

	List<MessageModel> _messages = [];

	UnmodifiableListView<MessageModel> get messages => UnmodifiableListView(_messages);

	BufferModel({ required this.entry, required this.server, String? subtitle }) : _subtitle = subtitle {
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
	final BufferModel buffer;

	MessageModel({ required this.entry, required this.buffer }) {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	IRCMessage get msg => entry.msg;
}
