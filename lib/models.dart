import 'dart:collection';
import 'package:flutter/material.dart';

import 'irc.dart';

class BufferListModel extends ChangeNotifier {
	List<BufferModel> _buffers = [];

	UnmodifiableListView<BufferModel> get buffers => UnmodifiableListView(_buffers);

	@override
	void dispose() {
		_buffers.forEach((buf) => buf.dispose());
		super.dispose();
	}

	void add(BufferModel buf) {
		_buffers.add(buf);
		notifyListeners();
	}

	BufferModel? getByName(String name) {
		for (var item in _buffers) {
			if (item.name == name) {
				return item;
			}
		}
		return null;
	}
}

class BufferModel extends ChangeNotifier {
	String name;
	String? _subtitle;

	final MessageListModel messages = MessageListModel();

	BufferModel({ required this.name, String? subtitle }) : _subtitle = subtitle;

	String? get subtitle => _subtitle;

	set subtitle(String? subtitle) {
		_subtitle = subtitle;
		notifyListeners();
	}
}

class MessageListModel extends ChangeNotifier {
	List<IRCMessage> _messages = [];

	UnmodifiableListView<IRCMessage> get list => UnmodifiableListView(_messages);

	void add(IRCMessage msg) {
		// TODO: insert at correct position
		_messages.add(msg);
		notifyListeners();
	}
}
