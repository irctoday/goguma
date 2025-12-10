import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_handler/share_handler.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../logging.dart';
import '../models.dart';
import '../notification_controller.dart';
import '../prefs.dart';
import '../widget/composer.dart';
import '../widget/date_indicator.dart';
import '../widget/message_item.dart';
import '../widget/network_indicator.dart';
import 'buffer_details.dart';
import 'buffer_list.dart';
import 'search.dart';

class BufferPageArguments {
	final BufferModel buffer;
	final SharedMedia? sharedMedia;
	final MessageEntry? searchMessage;

	const BufferPageArguments({
		required this.buffer,
		this.sharedMedia,
		this.searchMessage,
	});
}

class BufferPage extends StatefulWidget {
	static const routeName = '/buffer';

	final String? unreadMarkerTime;
	final SharedMedia? sharedMedia;
  final MessageEntry? searchMessage;

	const BufferPage({ super.key, this.unreadMarkerTime, this.sharedMedia, this.searchMessage });

	@override
	State<BufferPage> createState() => _BufferPageState();

	static void open(BuildContext context, String name, NetworkModel network) async {
		var db = context.read<DB>();
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();
		var client = clientProvider.get(network);
		var navigator = Navigator.of(context);

		var buffer = bufferList.get(name, network);
		if (buffer == null) {
			var entry = await db.storeBuffer(BufferEntry(name: name, network: network.networkId));
			buffer = BufferModel(entry: entry, network: network);
			bufferList.add(buffer);
		}

		// TODO: this is racy if the user has navigated away since the
		// BufferPage.open() call
		var until = ModalRoute.withName(BufferListPage.routeName);
		var args = BufferPageArguments(buffer: buffer);
		unawaited(navigator.pushNamedAndRemoveUntil(routeName, until, arguments: args));

		if (client.isChannel(name)) {
			_join(client, buffer);
		}
	}
}

void _join(Client client, BufferModel buffer) async {
	if (buffer.joined) {
		return;
	}

	buffer.joining = true;
	try {
		await client.join([buffer.name]);
	} on IrcException catch (err) {
		log.print('Failed to join "${buffer.name}"', error: err);
	} finally {
		buffer.joining = false;
	}
}

class _BufferPageState extends State<BufferPage> with WidgetsBindingObserver, TickerProviderStateMixin {
	final _itemScrollController = ItemScrollController();
	final _itemPositionsListener = ItemPositionsListener.create();
	final _userScrollListener = ScrollOffsetListener.create(recordProgrammaticScrolls: false);
	final _dateIndicatorValue = ValueNotifier<DateTime?>(null);
	final _showJumpToBottomValue = ValueNotifier<bool>(false);
	final _listKey = GlobalKey();
	final GlobalKey<ComposerState> _composerKey = GlobalKey();
	final GlobalKey<DateIndicatorState> _dateIndicatorKey = GlobalKey();
	late final AnimationController _blinkMsgController;
	late final StreamSubscription<double> _userScrollSubscription;

	bool _activated = true;
	bool _chatHistoryLoading = false;
	int _initialScrollIndex = 0;
	bool _isAtTop = false;
	bool _isAtBottom = false;

	bool _initialChatHistoryLoaded = false;
	int? _blinkMsgIndex;

	@override
	void initState() {
		super.initState();

		WidgetsBinding.instance.addObserver(this);

		_itemPositionsListener.itemPositions.addListener(_handleScroll);
		_userScrollSubscription = _userScrollListener.changes.listen(_handleUserScroll);

		_blinkMsgController = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 200),
			value: 1,
		);

		var buffer = context.read<BufferModel>();
		if (widget.searchMessage == null && buffer.messages.length >= 1000) {
			_setInitialChatHistoryLoaded();
			_updateBufferFocus();
			return;
		}

		_fetchMetadata();

		// Timer.run prevents calling setState() from inside initState()
		Timer.run(() async {
			try {
        await _fetchSearchMessage();
				await _fetchChatHistory();
			} on Exception catch (err) {
				log.print('Failed to fetch chat history', error: err);
			}
			if (mounted) {
				_updateBufferFocus();
			}
		});
	}

	void _handleScroll() {
		var positions = _itemPositionsListener.itemPositions.value;
		if (positions.isEmpty) {
			return;
		}

		var buffer = context.read<BufferModel>();
		var isAtTop = positions.any((pos) => pos.index == buffer.messages.length - 1);
		if (!_isAtTop && isAtTop) {
			_fetchChatHistory();
		}
		_isAtTop = isAtTop;

		var isAtBottom = positions.any((pos) => pos.index < 2);
		if (_isAtBottom != isAtBottom) {
			_isAtBottom = isAtBottom;
			_updateBufferFocus();
		}

		var firstDateTime = buffer.messages[buffer.messages.length - positions.last.index - 1].entry.dateTime;
		_dateIndicatorValue.value = firstDateTime;

		var showJumpToBottom = positions.any((pos) => pos.index >= 20) && !isAtBottom;
		_showJumpToBottomValue.value = showJumpToBottom;

		// Workaround for the last messages becoming hidden when the virtual
		// keyboard is opened: reset the alignment to 0.
		if (_initialScrollIndex != 0 && positions.any((pos) => pos.index == 0 && pos.itemLeadingEdge == 0)) {
			_itemScrollController.jumpTo(index: 0, alignment: 0);
			_initialScrollIndex = 0;
		}
	}

	void _handleUserScroll(double value) {
		_dateIndicatorKey.currentState?.show();
	}

	void _fetchMetadata() async {
		var clientProvider = context.read<ClientProvider>();
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		var userList = context.read<NetworkModel>().users;

		if (client.isChannel(buffer.name)) {
			if (buffer.members != null) {
				return;
			}

			List<WhoReply> replies;
			try {
				replies = await client.who(buffer.name);
			} on Exception catch (err) {
				log.print('Failed to fetch channel WHO', error: err);
				await client.names(buffer.name);
				return;
			}

			var members = MemberListModel(client.isupport.caseMapping);
			for (var reply in replies) {
				members.set(reply.nickname, reply.membershipPrefix!);
				userList.updateUser(UserModel(
					nickname: reply.nickname,
					realname: reply.realname,
				));
			}

			buffer.members = members;
		} else {
			clientProvider.fetchBufferUser(buffer);
			client.monitor([buffer.name]);
		}
	}

  Future<void> _fetchSearchMessage() async {
    if (widget.searchMessage == null) {
      return;
    }

    var db = context.read<DB>();
    var clientProvider = context.read<ClientProvider>();
    var buffer = context.read<BufferModel>();
    var msg = await db.fetchMessageByEntry(widget.searchMessage!);
    if (msg != null) {
      List<MessageEntry> entries = [];
      entries.addAll(await db.listMessagesBefore(buffer.id, msg.id, 500));
      entries.add(msg);
      entries.addAll(await db.listMessagesAfter(buffer.id, msg.id, 500));
      var models = await buildMessageModelList(db, entries);
      // TODO: oops populateMessageHistory, merge
      buffer.populateMessageHistory(models.toList());
    } else {
      await clientProvider.fetchChatHistory(buffer, around: widget.searchMessage!.time);
    }
  }

	Future<void> _fetchChatHistory() async {
		if (_chatHistoryLoading) {
			return;
		}

		var db = context.read<DB>();
		var clientProvider = context.read<ClientProvider>();
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		// First try to load history from the DB, then try from the server

		int? firstMsgId;
		if (!buffer.messages.isEmpty) {
			firstMsgId = buffer.messages.first.id;
		}

		var limit = 1000;
		var entries = await db.listMessagesBefore(buffer.id, firstMsgId, limit);
		var models = await buildMessageModelList(db, entries);
		buffer.populateMessageHistory(models.toList());

		if (entries.length >= limit || !client.caps.enabled.contains('draft/chathistory')) {
			if (mounted) {
				setState(_setInitialChatHistoryLoaded);
			}
			return;
		}

		setState(() {
			_chatHistoryLoading = true;
		});

		try {
			await clientProvider.fetchChatHistory(buffer);
		} finally {
			if (mounted) {
				setState(() {
					_chatHistoryLoading = false;
					_setInitialChatHistoryLoaded();
				});
			}
		}
	}

	void _setInitialChatHistoryLoaded() {
		if (_initialChatHistoryLoaded) {
			return;
		}
		_initialChatHistoryLoaded = true;

		if (widget.unreadMarkerTime == null) {
			return;
		}

		var buffer = context.read<BufferModel>();
		for (var i = buffer.messages.length - 1; i >= 0; i--) {
			var msg = buffer.messages[i];
			if (widget.unreadMarkerTime!.compareTo(msg.entry.time) >= 0) {
				_initialScrollIndex = buffer.messages.length - i - 1;
				break;
			}
		}
	}

	@override
	void dispose() {
		_itemPositionsListener.itemPositions.removeListener(_handleScroll);
		_userScrollSubscription.cancel();
		_blinkMsgController.dispose();
		WidgetsBinding.instance.removeObserver(this);
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
	Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
		super.didChangeAppLifecycleState(state);
		_updateBufferFocus();
		if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
			await _saveDraft();
		}
	}

	@override
	Future<AppExitResponse> didRequestAppExit() async {
		await _saveDraft();
		return AppExitResponse.exit;
	}

	void _updateBufferFocus() {
		var buffer = context.read<BufferModel>();
		var state = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
		buffer.focused = state == AppLifecycleState.resumed && _activated && _isAtBottom;
		if (buffer.focused) {
			_markRead();
		}
	}

	Future<void> _saveDraft() async {
		var composer = _composerKey.currentState;
		if (composer == null) {
			return;
		}
		var buffer = context.read<BufferModel>();
		buffer.draft = composer.draft;
		await context.read<DB>().storeBuffer(buffer.entry);
	}

	void _markRead() {
		var db = context.read<DB>();
		var client = context.read<Client>();
		var buffer = context.read<BufferModel>();
		var notifController = context.read<NotificationController>();

		if (buffer.unreadCount > 0 && buffer.messages.length > 0) {
			buffer.entry.lastReadTime = buffer.messages.last.entry.time;
			db.storeBuffer(buffer.entry);

			if (buffer.entry.lastReadTime != null && client.state != ClientState.disconnected) {
				client.setReadMarker(buffer.name, buffer.entry.lastReadTime!);
			}
		}
		buffer.unreadCount = 0;

		notifController.cancelAllWithBuffer(buffer, null);
	}

	void _handleMsgRefTap(int id) {
		var buffer = context.read<BufferModel>();

		int? index;
		for (var i = 0; i < buffer.messages.length; i++) {
			if (buffer.messages[i].id == id) {
				index = buffer.messages.length - i - 1;
				break;
			}
		}
		if (index == null) {
			return;
		}

		setState(() {
			_blinkMsgIndex = index;
		});

		_itemScrollController.jumpTo(
			index: index,
			alignment: 0.5,
		);
		_blinkMsgController.repeat(reverse: true);
		Timer(_blinkMsgController.duration! * 4, () {
			if (!mounted) {
				return;
			}
			_blinkMsgController.animateTo(1);
			setState(() {
				_blinkMsgIndex = null;
			});
		});
	}

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var prefs = context.read<Prefs>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();

		var subtitle = buffer.topic ?? buffer.realname;
		var isOnline = network.state == NetworkState.synchronizing || network.state == NetworkState.online;
		var canSendMessage = canSendMessageToBuffer(buffer, network);
		var isChannel = client.isChannel(buffer.name);
		var messages = buffer.messages;

		var compact = prefs.bufferCompact;
		var showTyping = prefs.typingIndicator;
		if (!client.caps.enabled.contains('message-tags')) {
			showTyping = false;
		}

		if (canSendMessage && showTyping) {
			var typingNicks = buffer.typing;
			if (typingNicks.isNotEmpty) {
				subtitle = typingNicks.join(', ') + ' ${typingNicks.length > 1 ? 'are' : 'is'} typing...';
			}
		}

		MaterialBanner? banner;
		if (network.state == NetworkState.online && isChannel && !buffer.joined && !buffer.joining) {
			banner = MaterialBanner(
				content: Text('You have left this channel.'),
				actions: [
					TextButton(
						child: Text('JOIN'),
						onPressed: () {
							var bufferList = context.read<BufferListModel>();
							var db = context.read<DB>();

							bufferList.setArchived(buffer, false);
							db.storeBuffer(buffer.entry);

							_join(client, buffer);
							_fetchMetadata();
						},
					),
				],
			);
		}
		if (banner == null && buffer.archived) {
			banner = MaterialBanner(
				content: Text('This conversation is archived.'),
				actions: [
					TextButton(
						child: Text('UNARCHIVE'),
						onPressed: () {
							var bufferList = context.read<BufferListModel>();
							var db = context.read<DB>();

							bufferList.setArchived(buffer, false);
							db.storeBuffer(buffer.entry);

							_fetchMetadata();
						},
					),
				],
			);
		}

		Widget msgList;
		if (_initialChatHistoryLoaded && messages.isEmpty) {
			msgList = Center(child: Column(
				mainAxisAlignment: MainAxisAlignment.center,
				children: [
					Icon(Icons.forum, size: 100),
					Text(
						buffer.name,
						style: Theme.of(context).textTheme.headlineSmall,
						textAlign: TextAlign.center,
					),
					SizedBox(height: 15),
					Container(
						constraints: BoxConstraints(maxWidth: 300),
						child: Text(
							'No messages yet in this conversation.',
							textAlign: TextAlign.center,
						),
					),
				],
			));
		} else if (_initialChatHistoryLoaded) {
			msgList = ScrollablePositionedList.builder(
				key: _listKey,
				reverse: true,
				itemScrollController: _itemScrollController,
				itemPositionsListener: _itemPositionsListener,
				scrollOffsetListener: _userScrollListener,
				itemCount: messages.length,
				initialScrollIndex: _initialScrollIndex,
				initialAlignment: _initialScrollIndex > 0 ? 1 : 0,
				itemBuilder: (context, index) {
					var msgIndex = messages.length - index - 1;
					var msg = messages[msgIndex];
					var prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;
					var key = ValueKey(msg.id);

					VoidCallback? onReply;
					if (isChannel) {
						onReply = () {
							_composerKey.currentState!.setReplyTo(msg);
						};
					}

					if (compact) {
						return CompactMessageItem(
							key: key,
							msg: msg,
							prevMsg: prevMsg,
							unreadMarkerTime: widget.unreadMarkerTime,
							onReply: onReply,
							last: msgIndex == messages.length - 1,
						);
					}

					var nextMsg = msgIndex + 1 < messages.length ? messages[msgIndex + 1] : null;

					Widget msgWidget = RegularMessageItem(
						key: key,
						msg: msg,
						prevMsg: prevMsg,
						nextMsg: nextMsg,
						unreadMarkerTime: widget.unreadMarkerTime,
						onReply: onReply,
						onMsgRefTap: _handleMsgRefTap,
					);
					if (index == _blinkMsgIndex) {
						msgWidget = FadeTransition(opacity: _blinkMsgController, child: msgWidget);
					}
					return msgWidget;
				},
			);
		} else {
			msgList = Container();
		}

		Widget? composer;
		if (!buffer.archived && !(isOnline && isChannel && !buffer.joined)) {
			composer = Padding(
				// Hack to keep the bottomNavigationBar displayed when the
				// virtual keyboard shows up
				padding: EdgeInsets.only(
					bottom: MediaQuery.of(context).viewInsets.bottom,
				),
				child: Material(elevation: 15, child: Container(
					padding: EdgeInsets.all(10),
					child: Composer(
						key: _composerKey,
						sharedMedia: widget.sharedMedia,
						draft: buffer.draft,
					),
				)),
			);
		}

		Widget jumpToBottom = ValueListenableBuilder(
			valueListenable: _showJumpToBottomValue,
			builder: (context, showJumpToBottom, _) {
				if (!showJumpToBottom) return Container();
				return Positioned(
					right: 15,
					bottom: 15,
					child: FloatingActionButton(
						mini: true,
						tooltip: 'Jump to bottom',
						heroTag: null,
						backgroundColor: Colors.grey,
						foregroundColor: Colors.white,
						onPressed: () {
							_itemScrollController.jumpTo(index: 0);
						},
						child: const Icon(Icons.keyboard_double_arrow_down, size: 18),
					),
				);
			},
		);

		Widget dateIndicator = Container(
			padding: EdgeInsets.only(top: 10),
			alignment: Alignment.topCenter,
			child: DateIndicator(key: _dateIndicatorKey, date: _dateIndicatorValue),
		);

		var scaffold = Scaffold(
			appBar: AppBar(
				title: InkResponse(
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Text(buffer.name, overflow: TextOverflow.fade),
							if (subtitle != null) Text(
								stripAnsiFormatting(subtitle),
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
							var bufferList = context.read<BufferListModel>();
							var db = context.read<DB>();
							switch (key) {
							case 'details':
								Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
								break;
							case 'search':
								Navigator.pushNamed(context, SearchPage.routeName, arguments: buffer);
								break;
							case 'pin':
								var client = context.read<Client>();
								if (client.metadataSubs.contains('soju.im/pinned')) {
									client.setMetadata(buffer.name, 'soju.im/pinned', buffer.pinned ? '0' : '1');
								} else {
									bufferList.setPinned(buffer, !buffer.pinned);
									db.storeBuffer(buffer.entry);
								}
								break;
							case 'mute':
								var client = context.read<Client>();
								if (client.metadataSubs.contains('soju.im/muted')) {
									client.setMetadata(buffer.name, 'soju.im/muted', buffer.muted ? '0' : '1');
								} else {
									bufferList.setMuted(buffer, !buffer.muted);
									db.storeBuffer(buffer.entry);
								}
								break;
							case 'part':
								var client = context.read<Client>();
								if (client.isChannel(buffer.name)) {
									client.send(IrcMessage('PART', [buffer.name]));
								} else {
									client.unmonitor([buffer.name]);
								}
								bufferList.setArchived(buffer, true);
								db.storeBuffer(buffer.entry);
								Navigator.pop(context);
								break;
							case 'delete':
								bufferList.remove(buffer);
								db.deleteBuffer(buffer.entry.id!);
								Navigator.pop(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(value: 'details', child: Text('Details')),
								PopupMenuItem(value: 'search', child: Text('Search')),
								if (isOnline) PopupMenuItem(value: 'pin', child: Text(buffer.pinned ? 'Unpin' : 'Pin')),
								if (isOnline) PopupMenuItem(value: 'mute', child: Text(buffer.muted ? 'Unmute' : 'Mute')),
								if (!buffer.archived && (isOnline || !isChannel)) PopupMenuItem(value: 'part', child: Text(buffer.joined ? 'Leave' : 'Archive')),
								if (buffer.archived) PopupMenuItem(value: 'delete', child: Text('Delete')),
							];
						},
					),
				],
			),
			body: NetworkIndicator(network: network, child: Column(children: [
				if (banner != null) banner,
				Expanded(child: SafeArea(child: Stack(children: [
					msgList,
					jumpToBottom,
					dateIndicator,
				]))),
			])),
			bottomNavigationBar: composer,
		);

		return PopScope(
			canPop: true,
			onPopInvokedWithResult: (bool didPop, bool? result) async {
				if (didPop) {
					await _saveDraft();
				}
			},
			child: scaffold
		);
	}
}
