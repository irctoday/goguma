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

	UnmodifiableListView<BufferModel> get buffers => UnmodifiableListView(_buffers.values);

	@override
	void dispose() {
		_buffers.values.forEach((buf) => buf.dispose());
		super.dispose();
	}

	void add(BufferModel buf) {
		_buffers[BufferKey(buf.name, buf.server)] = buf;
		notifyListeners();
	}

	void remove(BufferModel buf) {
		_buffers.remove(BufferKey(buf.name, buf.server));
		notifyListeners();
	}

	void clear() {
		_buffers.clear();
		notifyListeners();
	}

	BufferModel? get(String name, ServerModel server) {
		return _buffers[BufferKey(name, server)];
	}
}

class BufferModel extends ChangeNotifier {
	final BufferEntry entry;
	final ServerModel server;
	String? _subtitle;
	bool _messageHistoryLoaded = false;

	List<MessageModel> _messages = [];

	UnmodifiableListView<MessageModel> get messages => UnmodifiableListView(_messages);

	BufferModel({ required this.entry, required this.server, String? subtitle }) : _subtitle = subtitle {
		assert(entry.id != null);
	}

	int get id => entry.id!;
	String get name => entry.name;
	String? get subtitle => _subtitle;
	bool get messageHistoryLoaded => _messageHistoryLoaded;

	set subtitle(String? subtitle) {
		_subtitle = subtitle;
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
