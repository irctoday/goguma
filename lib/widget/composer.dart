import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_flipped_autocomplete/flutter_flipped_autocomplete.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../commands.dart';
import '../database.dart';
import '../irc.dart';
import '../logging.dart';
import '../models.dart';
import '../prefs.dart';

final whitespaceRegExp = RegExp(r'\s', unicode: true);

class Composer extends StatefulWidget {
	const Composer({ super.key });

	@override
	ComposerState createState() => ComposerState();
}

class ComposerState extends State<Composer> {
	final _formKey = GlobalKey<FormState>();
	final _focusNode = FocusNode();
	final _controller = TextEditingController();

	bool _isCommand = false;
	bool _locationServiceAvailable = false;
	bool _addMenuLoading = false;

	DateTime? _ownTyping;
	String? _replyPrefix;
	MessageModel? _replyTo;

	@override
	void initState() {
		super.initState();
		_checkLocationService();
	}

	void _checkLocationService() async {
		bool avail = false;
		try {
			avail = await Geolocator.isLocationServiceEnabled();
		} on Exception catch (err) {
			log.print('Failed to check for location service: $err');
		}

		if (avail) {
			var permission = await Geolocator.checkPermission();
			avail = permission != LocationPermission.deniedForever;
		}

		if (!mounted) {
			return;
		}
		setState(() {
			_locationServiceAvailable = avail;
		});
	}

	int _getMaxPrivmsgLen() {
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		var msg = IrcMessage(
			'PRIVMSG',
			[buffer.name, ''],
			source: IrcSource(
				client.nick,
				user: '_' * client.isupport.usernameLen,
				host: '_' * client.isupport.hostnameLen,
			),
		);
		var raw = msg.toString() + '\r\n';
		return client.isupport.lineLen - raw.length;
	}

	List<IrcMessage> _buildPrivmsg(String text) {
		var buffer = context.read<BufferModel>();
		var maxLen = _getMaxPrivmsgLen();

		List<IrcMessage> messages = [];
		for (var line in text.split('\n')) {
			Map<String, String?> tags = {};
			if (messages.isEmpty && _replyTo?.msg.tags['msgid'] != null) {
				tags['+draft/reply'] = _replyTo!.msg.tags['msgid']!;
			}

			while (maxLen > 1 && line.length > maxLen) {
				// Pick a good cut-off index, preferably at a whitespace
				// character
				var i = line.substring(0, maxLen).lastIndexOf(whitespaceRegExp);
				if (i <= 0) {
					i = maxLen - 1;
				}

				var leading = line.substring(0, i + 1);
				line = line.substring(i + 1);

				messages.add(IrcMessage('PRIVMSG', [buffer.name, leading], tags: tags));
			}

			// We'll get ERR_NOTEXTTOSEND if we try to send an empty message
			if (line != '') {
				messages.add(IrcMessage('PRIVMSG', [buffer.name, line], tags: tags));
			}
		}

		return messages;
	}

	void _send(List<IrcMessage> messages) async {
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		var db = context.read<DB>();
		var bufferList = context.read<BufferListModel>();
		var network = context.read<NetworkModel>();

		List<Future<IrcMessage>> futures = [];
		for (var msg in messages) {
			futures.add(client.sendTextMessage(msg));
		}

		if (!client.caps.enabled.contains('echo-message')) {
			messages = await Future.wait(futures);

			List<MessageEntry> entries = [];
			for (var msg in messages) {
				var entry = MessageEntry(msg, buffer.id);
				entries.add(entry);
			}
			await db.storeMessages(entries);

			var models = await buildMessageModelList(db, entries);
			if (buffer.messageHistoryLoaded) {
				buffer.addMessages(models, append: true);
			}
			bufferList.bumpLastDeliveredTime(buffer, entries.last.time);
			if (network.networkEntry.bumpLastDeliveredTime(entries.last.time)) {
				await db.storeNetwork(network.networkEntry);
			}
		}
	}

	void _submitCommand(String text) {
		String name;
		String? param;
		var i = text.indexOf(' ');
		if (i >= 0) {
			name = text.substring(0, i);
			param = text.substring(i + 1);
		} else {
			name = text;
		}

		var cmd = commands[name];
		if (cmd == null) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(
				content: Text('Command not found'),
			));
			return;
		}

		String? msgText;
		try {
			msgText = cmd(context, param);
		} on CommandException catch (err) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(
				content: Text(err.message),
			));
			return;
		}
		if (msgText != null) {
			var buffer = context.read<BufferModel>();
			var msg = IrcMessage('PRIVMSG', [buffer.name, msgText]);
			_send([msg]);
		}
	}

	Future<bool> _showConfirmSendDialog(String text, int msgCount) async {
		var result = await showDialog<bool>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text('Multiple messages'),
				content: Text('You are about to send $msgCount messages because you composed a long text. Are you sure?'),
				actions: [
					TextButton(
						child: Text('CANCEL'),
						onPressed: () {
							Navigator.pop(context, false);
						},
					),
					ElevatedButton(
						child: Text('SEND'),
						onPressed: () {
							Navigator.pop(context, true);
						},
					),
				],
			),
		);
		return result!;
	}

	Future<bool> _submitText(String text) async {
		var messages = _buildPrivmsg(text);
		if (messages.length == 0) {
			return true;
		} else if (messages.length > 3) {
			var confirmed = await _showConfirmSendDialog(text, messages.length);
			if (!confirmed) {
				return false;
			}
		}

		_send(messages);
		return true;
	}

	void _submit() async {
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

		var ok = true;
		if (_isCommand) {
			assert(text.startsWith('/'));
			assert(!text.contains('\n'));

			if (text.startsWith('//')) {
				ok = await _submitText(text.substring(1));
			} else {
				_submitCommand(text.substring(1));
			}
		} else {
			ok = await _submitText(text);
		}
		if (!ok) {
			return;
		}

		_setOwnTyping(false);
		_replyPrefix = null;
		_replyTo = null;
		_controller.text = '';
		_focusNode.requestFocus();
		setState(() {
			_isCommand = false;
		});
	}

	Future<Iterable<String>> _buildOptions(TextEditingValue textEditingValue) async {
		var text = textEditingValue.text;
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		var bufferList = context.read<BufferListModel>();

		if (buffer.members == null && client.isChannel(buffer.name)) {
			await client.names(buffer.name);
		}

		if (text.startsWith('/') && !text.contains(' ')) {
			text = text.toLowerCase();
			return commands.keys.where((cmd) {
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

	String _displayStringForOption(String option) {
		var text = _controller.text;

		var i = text.lastIndexOf(' ');
		if (i >= 0) {
			return text.substring(0, i + 1) + option + ' ';
		} else if (option.startsWith('/')) { // command
			return option + ' ';
		} else {
			return option + ': ';
		}
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

	void replyTo(MessageModel msg) {
		var buffer = context.read<BufferModel>();

		// TODO: disable swap when source is not in channel
		// TODO: query members when BufferPage is first displayed
		var nickname = msg.msg.source!.name;
		if (buffer.members != null && !buffer.members!.members.containsKey(nickname)) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(
				content: Text('This user is no longer in this channel.'),
			));
			return;
		}

		var prefix = '$nickname: ';
		if (prefix.startsWith('/')) {
			// Insert a zero-width space to ensure this doesn't end up
			// being executed as a command
			prefix = '\u200B$prefix';
		}

		_replyPrefix = prefix;
		_replyTo = msg;
		if (!_controller.text.startsWith(prefix)) {
			_controller.text = prefix + _controller.text;
			_controller.selection = TextSelection.collapsed(offset: _controller.text.length);
		}
		_focusNode.requestFocus();
		setState(() {
			_isCommand = false;
		});
	}

	Future<void> _shareLocation() async {
		var permission = await Geolocator.checkPermission();
		if (permission == LocationPermission.denied) {
			permission = await Geolocator.requestPermission();
		}
		if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
			if (mounted) {
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
					content: Text('Permission to access current location denied'),
				));
			}
			return;
		}

		Position pos;
		try {
			pos = await Geolocator.getCurrentPosition(timeLimit: Duration(seconds: 15));
		} on TimeoutException {
			if (mounted) {
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
					content: Text('Current location unavailable'),
				));
			}
			return;
		}

		// TODO: consider including the "u" (uncertainty) parameter, however
		// some consumers choke on parameters (e.g. Google Maps)
		var uri = 'geo:${pos.latitude},${pos.longitude}';
		if (_controller.text == '') {
			_controller.text = uri;
		} else {
			_controller.text += ' ' + uri;
		}
	}

	@override
	void dispose() {
		_focusNode.dispose();
		_controller.dispose();
		super.dispose();
	}

	Widget _buildTextField(BuildContext context, TextEditingController controller, FocusNode focusNode, VoidCallback onFieldSubmitted) {
		var prefs = context.read<Prefs>();
		var sendTyping = prefs.typingIndicator;

		return TextFormField(
			controller: controller,
			focusNode: focusNode,
			onChanged: (value) {
				if (sendTyping) {
					_sendTypingStatus();
				}

				if (_replyPrefix != null && !value.startsWith(_replyPrefix!)) {
					_replyPrefix = null;
					_replyTo = null;
				}

				setState(() {
					_isCommand = value.startsWith('/') && !value.contains('\n');
				});
			},
			onFieldSubmitted: (value) {
				onFieldSubmitted();
				_submit();
			},
			// Prevent the virtual keyboard from being closed when
			// sending a message
			onEditingComplete: () {},
			decoration: InputDecoration(
				hintText: 'Write a message...',
				border: InputBorder.none,
			),
			textInputAction: TextInputAction.send,
			minLines: 1,
			maxLines: 5,
			keyboardType: TextInputType.text, // disallows newlines
		);
	}

	Widget _buildOptionsView(BuildContext context, AutocompleteOnSelected<String> onSelected, Iterable<String> options) {
		var listView = ListView.builder(
			padding: EdgeInsets.zero,
			shrinkWrap: true,
			itemCount: options.length,
			reverse: true,
			itemBuilder: (context, index) {
				var option = options.elementAt(index);
				return InkWell(
					onTap: () {
						onSelected(option);
					},
					child: Builder(
						builder: (context) {
							var highlight = AutocompleteHighlightedOption.of(context) == index;
							if (highlight) {
								SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
									Scrollable.ensureVisible(context, alignment: 0.5);
								});
							}
							return Container(
								color: highlight ? Theme.of(context).focusColor : null,
								padding: const EdgeInsets.all(16.0),
								child: Text(option),
							);
						},
					),
				);
			},
		);

		return Align(
			alignment: Alignment.bottomLeft,
			child: Material(
				elevation: 4.0,
				child: ConstrainedBox(
					constraints: BoxConstraints(
						maxHeight: 200,
						// TODO: use the width of the text field instead:
						// https://github.com/flutter/flutter/pull/110032
						maxWidth: MediaQuery.of(context).size.width - 100,
					),
					child: listView,
				),
			),
		);
	}

	@override
	Widget build(BuildContext context) {
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

		Widget? addMenu;
		if (_addMenuLoading) {
			addMenu = Container(
				width: 15,
				height: 15,
				margin: EdgeInsets.all(10),
				child: CircularProgressIndicator(strokeWidth: 2),
			);
		} else if (_locationServiceAvailable) {
			addMenu = IconButton(
				icon: const Icon(Icons.add),
				tooltip: 'Add',
				onPressed: () {
					showModalBottomSheet<void>(
						context: context,
						builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
							ListTile(
								title: Text('Share my location'),
								leading: Icon(Icons.my_location),
								onTap: () async {
									Navigator.pop(context);
									setState(() {
										_addMenuLoading = true;
									});
									try {
										await _shareLocation();
									} finally {
										if (mounted) {
											setState(() {
												_addMenuLoading = false;
											});
										}
									}
								}
							),
						]),
					);
				},
			);
		}

		return Form(key: _formKey, child: Row(children: [
			Expanded(child: RawFlippedAutocomplete(
				optionsBuilder: _buildOptions,
				displayStringForOption: _displayStringForOption,
				fieldViewBuilder: _buildTextField,
				focusNode: _focusNode,
				textEditingController: _controller,
				optionsViewBuilder: _buildOptionsView,
			)),
			if (addMenu != null) addMenu,
			fab,
		]));
	}
}
