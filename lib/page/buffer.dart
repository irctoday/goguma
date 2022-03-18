import 'package:flutter/material.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../linkify.dart';
import '../models.dart';
import '../notification_controller.dart';
import '../widget/network_indicator.dart';
import '../widget/swipe_action.dart';
import 'buffer_details.dart';

class BufferPage extends StatefulWidget {
	static const routeName = '/buffer';

	final String? unreadMarkerTime;

	BufferPage({ Key? key, this.unreadMarkerTime }) : super(key: key);

	@override
	BufferPageState createState() => BufferPageState();
}

class BufferPageState extends State<BufferPage> with WidgetsBindingObserver {
	final _composerFocusNode = FocusNode();
	final _composerFormKey = GlobalKey<FormState>();
	final _composerController = TextEditingController();
	final _scrollController = ScrollController();

	bool _activated = true;
	bool _chatHistoryLoading = false;

	@override
	void initState() {
		super.initState();

		WidgetsBinding.instance!.addObserver(this);

		_scrollController.addListener(_handleScroll);

		var buffer = context.read<BufferModel>();
		var future = Future.value();
		if (!buffer.messageHistoryLoaded) {
			// TODO: only load a partial view of the messages
			future = context.read<DB>().listMessages(buffer.id).then((entries) {
				buffer.populateMessageHistory(entries.map((entry) {
					return MessageModel(entry: entry);
				}).toList());

				if (buffer.messages.length < 100) {
					_fetchChatHistory();
				}
			});
		}

		future.then((_) {
			_updateBufferFocus();
		});
	}

	void _submitComposer() {
		if (_composerController.text != '') {
			var buffer = context.read<BufferModel>();
			var client = context.read<Client>();

			var msg = IrcMessage('PRIVMSG', [buffer.name, _composerController.text]);
			client.send(msg);

			if (!client.caps.enabled.contains('echo-message')) {
				msg = IrcMessage(msg.cmd, msg.params, source: IrcSource(client.nick));
				var entry = MessageEntry(msg, buffer.id);
				context.read<DB>().storeMessages([entry]).then((_) {
					if (buffer.messageHistoryLoaded) {
						buffer.addMessages([MessageModel(entry: entry)], append: true);
					}
					context.read<BufferListModel>().bumpLastDeliveredTime(buffer, entry.time);
				});
			}
		}
		_composerController.text = '';
		_composerFocusNode.requestFocus();
	}

	void _handleMessageSwipe(MessageModel msg) {
		_composerController.text = '${msg.msg.source!.name}: ';
		_composerController.selection = TextSelection.collapsed(offset: _composerController.text.length);
		_composerFocusNode.requestFocus();
	}

	void _handleScroll() {
		if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
			_fetchChatHistory();
		}
	}

	void _fetchChatHistory() {
		if (_chatHistoryLoading) {
			return;
		}

		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		if (!buffer.messageHistoryLoaded || !client.caps.enabled.contains('draft/chathistory')) {
			return;
		}

		setState(() {
			_chatHistoryLoading = true;
		});

		var limit = 100;
		Future<void> future;
		if (buffer.messages.length > 0) {
			var t = buffer.messages.first.entry.time;
			future = client.fetchChatHistoryBefore(buffer.name, t, limit);
		} else {
			future = client.fetchChatHistoryLatest(buffer.name, null, limit);
		}

		future.whenComplete(() {
			setState(() {
				_chatHistoryLoading = false;
			});
		}).ignore();
	}

	@override
	void dispose() {
		_composerFocusNode.dispose();
		_composerController.dispose();
		_scrollController.removeListener(_handleScroll);
		_scrollController.dispose();
		WidgetsBinding.instance!.removeObserver(this);
		super.dispose();
	}

	@override
	void deactivate() {
		_activated = false;
		_updateBufferFocus();
		super.deactivate();
	}

	@override
	void activate() {
		super.activate();
		_activated = true;
		_updateBufferFocus();
	}

	@override
	void didChangeAppLifecycleState(AppLifecycleState state) {
		super.didChangeAppLifecycleState(state);
		_updateBufferFocus();
	}

	void _updateBufferFocus() {
		var buffer = context.read<BufferModel>();
		var state = WidgetsBinding.instance!.lifecycleState ?? AppLifecycleState.resumed;
		buffer.focused = state == AppLifecycleState.resumed && _activated;
		if (buffer.focused) {
			_markRead();
		}
	}

	void _markRead() {
		var buffer = context.read<BufferModel>();
		var notifController = context.read<NotificationController>();

		if (buffer.unreadCount > 0 && buffer.messages.length > 0) {
			buffer.entry.lastReadTime = buffer.messages.last.entry.time;
			context.read<DB>().storeBuffer(buffer.entry);

			var client = context.read<Client>();
			if (buffer.entry.lastReadTime != null) {
				client.setRead(buffer.name, buffer.entry.lastReadTime!);
			}
		}
		buffer.unreadCount = 0;

		notifController.cancelAllWithBuffer(buffer);
	}

	Iterable<String> _generateSuggestions(String text) {
		var buffer = context.read<BufferModel>();
		var members = buffer.members;
		if (members == null) {
			return [];
		}

		String pattern;
		var i = text.lastIndexOf(' ');
		if (i >= 0) {
			pattern = text.substring(i + 1);
		} else {
			pattern = text;
		}

		if (pattern.length < 3) {
			return [];
		}

		pattern = pattern.toLowerCase();
		return members.members.keys.where((name) {
			return name.toLowerCase().startsWith(pattern);
		}).take(10);
	}

	void _handleSuggestionSelected(String suggestion) {
		var text = _composerController.text;

		var i = text.lastIndexOf(' ');
		if (i >= 0) {
			_composerController.text = text.substring(0, i + 1) + suggestion + ' ';
		} else {
			_composerController.text = suggestion + ': ';
		}

		_composerController.selection = TextSelection.collapsed(offset: _composerController.text.length);
		_composerFocusNode.requestFocus();
	}

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var subtitle = buffer.topic ?? buffer.realname;
		var isOnline = network.state == NetworkState.synchronizing || network.state == NetworkState.online;
		var canSendMessage = isOnline;
		var isChannel = client.isChannel(buffer.name);
		if (isChannel) {
			canSendMessage = canSendMessage && buffer.joined;
		} else {
			canSendMessage = canSendMessage && buffer.online != false;
		}
		var messages = buffer.messages;
		return Scaffold(
			appBar: AppBar(
				title: InkResponse(
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Text(buffer.name, overflow: TextOverflow.fade),
							if (subtitle != null) Text(
								subtitle,
								style: TextStyle(fontSize: 12.0),
								overflow: TextOverflow.fade,
							),
						],
					),
					onTap: () {
						Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
					},
				),
				actions: [
					PopupMenuButton<String>(
						onSelected: (key) {
							switch (key) {
							case 'details':
								Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
								break;
							case 'part':
								var client = context.read<Client>();
								if (client.isChannel(buffer.name)) {
									client.send(IrcMessage('PART', [buffer.name]));
								} else {
									client.unmonitor([buffer.name]);
								}
								context.read<BufferListModel>().remove(buffer);
								context.read<DB>().deleteBuffer(buffer.entry.id!);
								Navigator.pop(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Details'), value: 'details'),
								PopupMenuItem(child: Text('Leave'), value: 'part'),
							];
						},
					),
				],
			),
			body: NetworkIndicator(network: network, child: Column(children: [
				if (isChannel && !buffer.joined && !buffer.joining) MaterialBanner(
					content: Text('You have left this channel.'),
					actions: [
						if (isOnline) FlatButton(
							child: Text('JOIN'),
							onPressed: () {
								join(client, buffer);
							},
						),
					],
				),
				Expanded(child: ListView.builder(
					reverse: true,
					controller: _scrollController,
					itemCount: messages.length,
					itemBuilder: (context, index) {
						var msgIndex = messages.length - index - 1;
						var msg = messages[msgIndex];
						var prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;
						var nextMsg = msgIndex + 1 < messages.length ? messages[msgIndex + 1] : null;

						VoidCallback? onSwipe;
						if (isChannel) {
							onSwipe = () => _handleMessageSwipe(msg);
						}

						return _MessageItem(
							key: ValueKey(msg.id),
							msg: msg,
							prevMsg: prevMsg,
							nextMsg: nextMsg,
							unreadMarkerTime: widget.unreadMarkerTime,
							onSwipe: onSwipe,
						);
					},
				)),
				if (canSendMessage) Material(elevation: 15, child: Container(
					padding: EdgeInsets.all(10),
					child: Form(key: _composerFormKey, child: Row(children: [
						Expanded(child: TypeAheadFormField<String>(
							textFieldConfiguration: TextFieldConfiguration(
								decoration: InputDecoration(
									hintText: 'Write a message...',
									border: InputBorder.none,
								),
								onSubmitted: (value) {
									_submitComposer();
								},
								focusNode: _composerFocusNode,
								controller: _composerController,
								textInputAction: TextInputAction.send,
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
						FloatingActionButton(
							onPressed: () {
								_submitComposer();
							},
							tooltip: 'Send',
							child: Icon(Icons.send, size: 18),
							mini: true,
							elevation: 0,
						),
					])),
				)),
			])),
		);
	}
}

class _MessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg, nextMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onSwipe;

	_MessageItem({ Key? key, required this.msg, this.prevMsg, this.nextMsg, this.unreadMarkerTime, this.onSwipe }) : super(key: key);

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();

		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var prevIrcMsg = prevMsg?.msg;
		var prevEntry = prevMsg?.entry;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;

		var nextMsgSameSender = nextMsg != null && ircMsg.source!.name == nextMsg!.msg.source!.name;

		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());
		var showSender = showUnreadMarker || !prevMsgSameSender;
		var showTime = !nextMsgSameSender || nextMsg!.entry.dateTime.difference(entry.dateTime) > Duration(minutes: 2);

		var unreadMarkerColor = Theme.of(context).accentColor;
		var eventColor = DefaultTextStyle.of(context).style.color!.withOpacity(0.5);

		var colorSwatch = Colors.primaries[sender.hashCode % Colors.primaries.length];
		var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);

		//var boxColor = Theme.of(context).accentColor;
		var boxColor = colorScheme.primary;
		var boxAlignment = Alignment.centerLeft;
		var textStyle = DefaultTextStyle.of(context).style.apply(color: colorScheme.onPrimary);
		if (client.isMyNick(sender)) {
			boxColor = Colors.grey[200]!;
			boxAlignment = Alignment.centerRight;
			textStyle = DefaultTextStyle.of(context).style.apply(color: boxColor.computeLuminance() > 0.5 ? Colors.black : Colors.white);
		}

		const margin = 16.0;
		var marginBottom = margin;
		if (nextMsg != null) {
			marginBottom = 0.0;
		}
		var marginTop = margin;
		if (!showSender) {
			marginTop = margin / 4;
		}

		var senderTextSpan = TextSpan(
			text: sender,
			style: TextStyle(fontWeight: FontWeight.bold),
		);

		var linkStyle = textStyle.apply(decoration: TextDecoration.underline);

		List<InlineSpan> content;
		if (ctcp != null && ctcp.cmd == 'ACTION') {
			textStyle = textStyle.apply(fontStyle: FontStyle.italic);

			String actionText;
			if (ctcp.cmd == 'ACTION') {
				actionText = stripAnsiFormatting(ctcp.param ?? '');
			} else {
				actionText = 'has sent a CTCP "${ctcp.cmd}" command';
			}

			content = [
				senderTextSpan,
				TextSpan(text: ' '),
				linkify(actionText, textStyle: textStyle, linkStyle: linkStyle),
			];
		} else {
			var body = stripAnsiFormatting(ircMsg.params[1]);
			content = [
				if (showSender) senderTextSpan,
				if (showSender) TextSpan(text: '\n'),
				linkify(body, textStyle: textStyle, linkStyle: linkStyle),
			];
		}

		Widget inner = RichText(text: TextSpan(
			children: content,
			style: textStyle,
		));

		if (showTime) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var time = '   $hh:$mm';
			var timeStyle = textStyle.apply(
				color: textStyle.color!.withOpacity(0.5),
				fontSizeFactor: 0.8,
			);

			// Add a fully transparent text span with the time, so that the real
			// time text doesn't collide with the message text.
			content.add(TextSpan(text: time, style: timeStyle.apply(color: Color(0))));

			inner = Stack(children: [
				inner,
				Positioned(
					bottom: 0,
					right: 0,
					child: Text(time, style: timeStyle),
				),
			]);
		}

		Widget bubble = Align(
			alignment: boxAlignment,
			child: Container(
				decoration: BoxDecoration(
					borderRadius: BorderRadius.circular(10),
					color: boxColor,
				),
				padding: EdgeInsets.all(10),
				child: inner,
			),
		);
		if (!client.isMyNick(sender)) {
			bubble = SwipeAction(
				child: bubble,
				background: Align(
					alignment: Alignment.centerLeft,
					child: Opacity(
						opacity: 0.6,
						child: Icon(Icons.reply),
					),
				),
				onSwipe: onSwipe,
			);
		}

		return Column(children: [
			if (showUnreadMarker) Container(
				margin: EdgeInsets.only(top: margin),
				child: Row(children: [
					Expanded(child: Divider(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Expanded(child: Divider(color: unreadMarkerColor)),
				]),
			),
			if (showDateMarker) Container(
				margin: EdgeInsets.symmetric(vertical: 20),
				child: Center(child: Text(_formatDate(localDateTime), style: TextStyle(color: eventColor))),
			),
			Container(
				margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: marginBottom),
				child: bubble,
			),
		]);
	}
}

bool _isSameDate(DateTime a, DateTime b) {
	return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.month.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}
