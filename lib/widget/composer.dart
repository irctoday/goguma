import 'package:flutter/material.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import '../prefs.dart';

class Composer extends StatefulWidget {
	const Composer({ Key? key }) : super(key: key);

	@override
	ComposerState createState() => ComposerState();
}

class ComposerState extends State<Composer> {
	final _formKey = GlobalKey<FormState>();
	final _focusNode = FocusNode();
	final _controller = TextEditingController();

	bool _isCommand = false;

	DateTime? _ownTyping;

	void _send(String text) async {
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		var db = context.read<DB>();
		var bufferList = context.read<BufferListModel>();

		_setOwnTyping(false);

		List<IrcMessage> messages = [];
		for (var line in text.split('\n')) {
			var msg = IrcMessage('PRIVMSG', [buffer.name, line]);
			client.send(msg);
			messages.add(msg);
		}

		if (!client.caps.enabled.contains('echo-message')) {
			List<MessageEntry> entries = [];
			List<MessageModel> models = [];
			for (var msg in messages) {
				msg = IrcMessage(msg.cmd, msg.params, source: IrcSource(client.nick));
				var entry = MessageEntry(msg, buffer.id);
				entries.add(entry);
				models.add(MessageModel(entry: entry));
			}
			await db.storeMessages(entries);
			if (buffer.messageHistoryLoaded) {
				buffer.addMessages(models, append: true);
			}
			bufferList.bumpLastDeliveredTime(buffer, entries.last.time);
		}
	}

	void _submitCommand(String text) {
		String cmd;
		String? param;
		var i = text.indexOf(' ');
		if (i >= 0) {
			cmd = text.substring(0, i);
			param = text.substring(i + 1);
		} else {
			cmd = text;
		}

		switch (cmd.toLowerCase()) {
		case 'me':
			_send(CtcpMessage('ACTION', param).format());
			break;
		default:
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(
				content: Text('Command not found'),
			));
			break;
		}
	}

	void _submitText(String text) {
		if (!_isCommand) {
			_send(text);
			return;
		}

		assert(text.startsWith('/'));
		assert(!text.contains('\n'));

		if (text.startsWith('//')) {
			_send(text.substring(1));
		} else {
			_submitCommand(text.substring(1));
		}
	}

	void _showConfirmSendDialog(String text) {
		var lineCount = 1 + '\n'.allMatches(text).length;
		showDialog<void>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text('Multiple messages'),
				content: Text('You are about to send $lineCount messages because you composed multiple lines of text. Are you sure?'),
				actions: [
					TextButton(
						child: Text('CANCEL'),
						onPressed: () {
							Navigator.pop(context);
						},
					),
					ElevatedButton(
						child: Text('SEND'),
						onPressed: () {
							Navigator.pop(context);
							_submit(confirmed: true);
						},
					),
				],
			),
		);
	}

	void _submit({ bool confirmed = false }) {
		// Remove empty lines at start and end of the text (can happen when
		// pasting text)
		var lines = _controller.text.split('\n');
		while (!lines.isEmpty && lines.first.trim() == '') {
			lines = lines.sublist(1);
		}
		while (!lines.isEmpty && lines.last.trim() == '') {
			lines = lines.sublist(0, lines.length - 1);
		}
		var text = lines.join('\n');

		var lineCount = 1 + '\n'.allMatches(text).length;
		if (lineCount > 3 && !confirmed) {
			_showConfirmSendDialog(text);
			return;
		}

		if (_controller.text != '') {
			_submitText(text);
		}
		_controller.text = '';
		_focusNode.requestFocus();
		setState(() {
			_isCommand = false;
		});
	}

	Future<Iterable<String>> _generateSuggestions(String text) async {
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		var bufferList = context.read<BufferListModel>();

		if (buffer.members == null && client.isChannel(buffer.name)) {
			await client.names(buffer.name);
		}

		if (text.startsWith('/') && !text.contains(' ')) {
			text = text.toLowerCase();
			return ['/me'].where((cmd) {
				return cmd.startsWith(text);
			});
		}

		String pattern;
		var i = text.lastIndexOf(' ');
		if (i >= 0) {
			pattern = text.substring(i + 1);
		} else {
			pattern = text;
		}
		pattern = pattern.toLowerCase();

		if (pattern.length < 3) {
			return [];
		}

		Iterable<String> result;
		if (client.isChannel(pattern)) {
			result = bufferList.buffers.map((buffer) => buffer.name);
		} else {
			result = buffer.members?.members.keys ?? [];
		}

		return result.where((name) {
			return name.toLowerCase().startsWith(pattern);
		}).take(10).map((name) {
			if (name.startsWith('/')) {
				// Insert a zero-width space to ensure this doesn't end up
				// being executed as a command
				return '\u200B$name';
			}
			return name;
		});
	}

	void _handleSuggestionSelected(String suggestion) {
		var text = _controller.text;

		var i = text.lastIndexOf(' ');
		if (i >= 0) {
			_controller.text = text.substring(0, i + 1) + suggestion + ' ';
		} else if (suggestion.startsWith('/')) { // command
			_controller.text = suggestion + ' ';
		} else {
			_controller.text = suggestion + ': ';
		}

		_controller.selection = TextSelection.collapsed(offset: _controller.text.length);
		_focusNode.requestFocus();
	}

	void _sendTypingStatus() {
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		if (!client.caps.enabled.contains('message-tags')) {
			return;
		}

		var active = _controller.text != '';
		var notify = _setOwnTyping(active);
		if (notify) {
			var msg = IrcMessage('TAGMSG', [buffer.name], tags: {'+typing': active ? 'active' : 'done'});
			client.send(msg);
		}
	}

	bool _setOwnTyping(bool active) {
		bool notify;
		var time = DateTime.now();
		if (!active) {
			notify = _ownTyping != null && _ownTyping!.add(Duration(seconds: 6)).isAfter(time);
			_ownTyping = null;
		} else {
			notify = _ownTyping == null || _ownTyping!.add(Duration(seconds: 3)).isBefore(time);
			if (notify) {
				_ownTyping = time;
			}
		}
		return notify;
	}

	void setTextPrefix(String prefix) {
		if (!_controller.text.startsWith(prefix)) {
			_controller.text = prefix + _controller.text;
			_controller.selection = TextSelection.collapsed(offset: _controller.text.length);
		}
		_focusNode.requestFocus();
		setState(() {
			_isCommand = false;
		});
	}

	@override
	void dispose() {
		_focusNode.dispose();
		_controller.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		var prefs = context.read<Prefs>();
		var sendTyping = prefs.typingIndicator;

		var fab = FloatingActionButton(
			onPressed: () {
				_submit();
			},
			tooltip: _isCommand ? 'Execute' : 'Send',
			child: Icon(_isCommand ? Icons.done : Icons.send, size: 18),
			backgroundColor: _isCommand ? Colors.red : null,
			mini: true,
			elevation: 0,
		);

		return Form(key: _formKey, child: Row(children: [
			Expanded(child: TypeAheadFormField<String>(
				textFieldConfiguration: TextFieldConfiguration(
					decoration: InputDecoration(
						hintText: 'Write a message...',
						border: InputBorder.none,
					),
					onChanged: (value) {
						if (sendTyping) {
							_sendTypingStatus();
						}

						setState(() {
							_isCommand = value.startsWith('/') && !value.contains('\n');
						});
					},
					onSubmitted: (value) {
						_submit();
					},
					focusNode: _focusNode,
					controller: _controller,
					textInputAction: TextInputAction.send,
					minLines: 1,
					maxLines: 5,
					keyboardType: TextInputType.text, // disallows newlines
				),
				direction: AxisDirection.up,
				hideOnEmpty: true,
				hideOnLoading: true,
				// To allow to select a suggestion, type some more,
				// then select another suggestion, without
				// unfocusing the text field.
				keepSuggestionsOnSuggestionSelected: true,
				animationDuration: const Duration(milliseconds: 300),
				debounceDuration: const Duration(milliseconds: 50),
				itemBuilder: (context, suggestion) {
					return ListTile(title: Text(suggestion));
				},
				suggestionsCallback: _generateSuggestions,
				onSuggestionSelected: _handleSuggestionSelected,
			)),
			fab,
		]));
	}
}
