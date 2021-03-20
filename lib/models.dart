import 'dart:collection';
import 'package:flutter/material.dart';

import 'irc.dart';

class ServerModel {}

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

	void clear() {
		_buffers.clear();
		notifyListeners();
	}

	BufferModel? get(String name, ServerModel server) {
		return _buffers[BufferKey(name, server)];
	}
}

class BufferModel extends ChangeNotifier {
	final String name;
	final ServerModel server;
	String? _subtitle;

	List<IRCMessage> _messages = [];

	UnmodifiableListView<IRCMessage> get messages => UnmodifiableListView(_messages);

	BufferModel({ required this.name, required this.server, String? subtitle }) : _subtitle = subtitle;

	String? get subtitle => _subtitle;

	set subtitle(String? subtitle) {
		_subtitle = subtitle;
		notifyListeners();
	}

	void addMessage(IRCMessage msg) {
		// TODO: insert at correct position
		_messages.add(msg);
		notifyListeners();
	}
}
