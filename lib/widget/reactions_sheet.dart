import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import 'emoji_sheet.dart';

class ReactionsSheet extends StatelessWidget {
	final MessageModel message;
	final UserListModel _userList; // TODO: watch list and individual users

	ReactionsSheet({ super.key, required this.message, required UserListModel userList }) :
		_userList = userList;

	static void open(BuildContext context, BufferModel buffer, MessageModel message) {
		var network = context.read<NetworkModel>();
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
					child: ReactionsSheet(message: message, userList: network.users),
				);
			},
		);
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
		// Watch Buffer to get redrawn on reaction changes.
		context.watch<BufferModel>();

		var client = context.read<Client>();
		var reactionsByNickname = <String, Set<String>>{};
		for (var reaction in message.reactions) {
			reactionsByNickname.putIfAbsent(reaction.msg.source!.name, () => {}).add(reaction.text);
		}
		var reactionsByType = <String, int>{};
		for (var reaction in message.reactions) {
			var current = reactionsByType[reaction.text] ?? 0;
			reactionsByType[reaction.text] = current + 1;
		}
		var bgSelected = Theme.of(context).colorScheme.secondaryContainer;

		var reactionsByTypeSorted = reactionsByType.entries.toList();
		reactionsByTypeSorted.sort((a, b) => -a.value.compareTo(b.value));

		return Column(children: [
			Container(
				padding: EdgeInsets.symmetric(vertical: 10, horizontal: 10),
				child: Row(
					spacing: 10,
					children: reactionsByTypeSorted.map((entry) => ActionChip(
							backgroundColor: (reactionsByNickname[client.nick]?.contains(entry.key) ?? false) ? bgSelected : null,
							avatar: Text(entry.key),
							label: Text('${entry.value}'),
							labelPadding: EdgeInsets.only(left: 4, right: 1),
							visualDensity: VisualDensity(vertical: -4),
							onPressed: () {
								_handleReact(context, entry.key);
							},
						) as Widget
					).followedBy([
						ActionChip(
							avatar: Icon(Icons.add_reaction),
							label: Text(''),
							labelPadding: EdgeInsets.zero,
							visualDensity: VisualDensity(vertical: -4),
							onPressed: () async {
								var reaction = await EmojiSheet.open(context);
								if (!context.mounted) {
									return;
								}
								if (reaction != null) {
									_handleReact(context, reaction);
								}
							},
						) as Widget
					]).toList(),
				),
			),
			Expanded(child: ListView(shrinkWrap: true, children: reactionsByNickname.entries.map((entry) {
				var nickname = entry.key;
				var reactions = entry.value;
				var user = _userList.map[nickname];
				var realname = user?.realname;

				return ListTile(
					title: Text(nickname),
					subtitle: realname != null && !isStubRealname(realname, nickname) ? Text(realname) : null,
					trailing: Row(
						mainAxisSize: MainAxisSize.min,
						spacing: 5,
						children: reactions.map((reaction) => Text(
							reaction,
							style: TextStyle(fontSize: 22),
						)).toList(),
					),
				);
			}).toList())),
		]);
	}
}
