import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';

class ReactionsSheet extends StatelessWidget {
	final Map<String, Set<String>> _reactions;
	final UserListModel _userList; // TODO: watch list and individual users

	ReactionsSheet({ super.key, required List<ReactionEntry> reactions, required UserListModel userList }) :
		_reactions = _groupReactionsByNickname(reactions),
		_userList = userList;

	static void open(BuildContext context, List<ReactionEntry> reactions) {
    var client = context.read<ClientProvider>().get(buffer.network);
		var network = context.read<NetworkModel>();
		showModalBottomSheet<void>(
			context: context,
			showDragHandle: true,
			builder: (context) => ReactionsSheet(reactions: reactions, userList: network.users),
		);
	}

	@override
	Widget build(BuildContext context) {
    var client = context.read<Client>();

    var reactionTypes = <String, int>{};
    for (var reactions in _reactions.values) {
      for (var reaction in reactions) {
        var n = reactionTypes[reaction] ?? 0;
        reactionTypes[reaction] = n + 1;
      }
    }
    var reactionsEntries = reactionTypes.entries.toList();
    reactionsEntries.sort((a, b) => -a.value.compareTo(b.value));

		return Column(children: [
      Row(children: reactionsEntries.map((reaction) => IconButton.filledTonal(
        isSelected: _reactions[client.nick]?.contains(reaction.key) ?? false,
        constraints: BoxConstraints(minWidth: 50, minHeight: 50),
        onPressed: () {
          Navigator.pop(context);
          // TODO _handleReact(context, reaction);
        },
        icon: Text(
          '${reaction.key} ${reaction.value}',
          style: TextStyle(fontSize: 20),
        ),
      )).toList()),
      Expanded(child: ListView(shrinkWrap: true, children: _reactions.entries.map((entry) {
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

Map<String, Set<String>> _groupReactionsByNickname(List<ReactionEntry> reactions) {
	Map<String, Set<String>> byNickname = {};
	for (var reaction in reactions) {
		byNickname.putIfAbsent(reaction.msg.source!.name, () => {}).add(reaction.text);
	}
	return byNickname;
}
