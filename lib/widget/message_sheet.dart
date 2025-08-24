import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import '../page/buffer.dart';
import '../page/buffer_details.dart';
import './emoji_sheet.dart';

const _defaultReactions = ['❤️', '👍', '👎', '😂', '😮', '😢'];

class MessageSheet extends StatelessWidget {
	final MessageModel message;
	final VoidCallback? onReply;

	const MessageSheet({ super.key, required this.message, this.onReply });

	static void open(BuildContext context, BufferModel buffer, MessageModel message, VoidCallback? onReply) {
		showModalBottomSheet<void>(
			context: context,
			showDragHandle: true,
			builder: (context) {
				var client = context.read<ClientProvider>().get(buffer.network);
				return MultiProvider(
					providers: [
						ChangeNotifierProvider<BufferModel>.value(value: buffer),
						ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
						Provider<Client>.value(value: client),
					],
					child: MessageSheet(message: message, onReply: onReply),
				);
			},
		);
	}

	void _handleViewProfile(BuildContext context, String sender) async {
		var db = context.read<DB>();
		var bufferList = context.read<BufferListModel>();
		var network = context.read<NetworkModel>();
		var navigator = Navigator.of(context);

		var buffer = bufferList.get(sender, network);
		if (buffer == null) {
			var entry = await db.storeBuffer(BufferEntry(name: sender, network: network.networkId));
			buffer = BufferModel(entry: entry, network: network);
			bufferList.add(buffer);
		}

		await navigator.pushNamed(BufferDetailsPage.routeName, arguments: buffer);
	}

	void _handleReact(BuildContext context, String reaction) async {
		var bufferList = context.read<BufferListModel>();
		var buffer = context.read<BufferModel>();
		var db = context.read<DB>();
		var client = context.read<Client>();
		var network = context.read<NetworkModel>();

		if (message.reactionMap[reaction]?.contains(client.nick) == true) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(
				content: Text('Cannot remove reaction'),
			));
			return;
		}

		var msg = await client.sendTextMessage(IrcMessage('TAGMSG', [buffer.name], tags: {
			'+draft/reply': message.entry.networkMsgid!,
			'+draft/react': reaction,
		}));

		if (client.caps.enabled.contains('echo-message')) {
			return;
		}

		var entry = ReactionEntry(msg, buffer.id);
		await db.storeReactions([entry]);
		if (buffer.messageHistoryLoaded) {
			buffer.addReactions([entry]);
		}

		bufferList.bumpLastDeliveredTime(buffer, entry.time);
		if (network.networkEntry.bumpLastDeliveredTime(entry.time)) {
			await db.storeNetwork(network.networkEntry);
		}
	}

	@override
	Widget build(BuildContext context) {
		var ircMsg = message.msg;
		var sender = ircMsg.source!.name;
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var isOwn = client.isMyNick(sender);
		var ctcp = CtcpMessage.parse(ircMsg);
		var isAction = ctcp != null && ctcp.cmd == 'ACTION';
		var canSendMessage = canSendMessageToBuffer(buffer, network);
		// TODO: we can redact if we are channel operator too
		var canRedact = canSendMessage && client.caps.enabled.contains('draft/message-redaction') && ircMsg.tags['msgid'] != null && isOwn && !message.entry.redacted;
		var reactions = message.reactionMap;
		var canReact = canSendMessage && client.caps.enabled.contains('message-tags') && client.isupport.isClientTagAllowed('draft/react') && message.entry.networkMsgid != null;

		return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
			if (canReact) Container(
				padding: EdgeInsets.symmetric(vertical: 10),
				child: Row(
					mainAxisAlignment: MainAxisAlignment.spaceEvenly,
					children: _defaultReactions.map((reaction) => IconButton.filledTonal(
						isSelected: reactions[reaction]?.contains(client.nick) ?? false,
						constraints: BoxConstraints(minWidth: 50, minHeight: 50),
						onPressed: () {
							Navigator.pop(context);
							_handleReact(context, reaction);
						},
						icon: Text(
							reaction,
							style: TextStyle(fontSize: 20),
						),
					)).followedBy([
						IconButton.filledTonal(
							isSelected: false,
							constraints: BoxConstraints(minWidth: 50, minHeight: 50),
							onPressed: () async {
								var reaction = await EmojiSheet.open(context);
								if (!context.mounted) {
									return;
								}
								if (reaction != null) {
									_handleReact(context, reaction);
								}
								Navigator.pop(context);
							},
							icon: Icon(Icons.add_reaction),
						),
					]).toList(),
				),
			),
			if (onReply != null && !isOwn) ListTile(
				title: Text('Reply'),
				leading: Icon(Icons.reply),
				onTap: () {
					Navigator.pop(context);
					onReply!();
				},
			),
			if (!isOwn) ListTile(
				title: Text('Message $sender'),
				leading: Icon(Icons.chat_bubble),
				onTap: () {
					var network = context.read<NetworkModel>();
					Navigator.pop(context);
					BufferPage.open(context, sender, network);
				},
			),
			if (!isOwn) ListTile(
				title: Text('View profile'),
				leading: Icon(Icons.person),
				onTap: () {
					Navigator.pop(context);
					_handleViewProfile(context, sender);
				},
			),
			ListTile(
				title: Text('Copy'),
				leading: Icon(Icons.content_copy),
				onTap: () async {
					var text = '';
					if (isAction) {
						var body = ctcp.param;
						if (body == null) {
							return;
						}
						body = stripAnsiFormatting(body);
						text = '$sender $body';
					} else {
						var body = stripAnsiFormatting(ircMsg.params[1]);
						text = '<$sender> $body';
					}
					await Clipboard.setData(ClipboardData(text: text));
					if (context.mounted) {
						Navigator.pop(context);
					}
				},
			),
			if (canRedact) ListTile(
				title: Text('Delete'),
				leading: Icon(Icons.delete),
				onTap: () async {
					var buffer = context.read<BufferModel>();
					client.send(IrcMessage('REDACT', [buffer.name, ircMsg.tags['msgid']!]));
					Navigator.pop(context);
				},
			),
		]));
	}
}
