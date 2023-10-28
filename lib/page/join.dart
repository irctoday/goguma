import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer.dart';
import '../ansi.dart';
import '../irc.dart';
import '../client.dart';
import '../client_controller.dart';
import '../logging.dart';
import '../models.dart';

class JoinPage extends StatefulWidget {
	static const routeName = '/join';

	const JoinPage({ super.key });

	@override
	State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
	final TextEditingController _nameController = TextEditingController();
	int _serial = 0;
	String _query = '';
	Timer? _debounceNameTimer;

	bool _loading = false;
	List<_Action> _actions = [];

	@override
	void dispose() {
		_nameController.dispose();
		_debounceNameTimer?.cancel();
		super.dispose();
	}

	void _handleNameChange(String query) {
		_debounceNameTimer?.cancel();
		_debounceNameTimer = Timer(const Duration(milliseconds: 500), () {
			// Sometimes "onChanged" is called even if the query didn't
			// actually change (e.g. when the virtual keyboard is dismissed)
			if (_query == query) {
				return;
			}
			_query = query;

			_search(query);
		});
	}

	void _search(String query) async {
		setState(() {
			_actions = [];
		});

		query = query.trim();

		if (query.length < 2) {
			return;
		}

		_serial++;
		var serial = _serial;

		setState(() {
			_loading = true;
		});

		// TODO: when refining a search, don't query servers again, instead
		// filter the local results list

		void handleActions(Iterable<_Action> actions) {
			if (_serial != serial || !mounted) {
				return;
			}
			setState(() {
				_actions.addAll(actions);
				_sortActions(_actions);
			});
		}

		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();
		List<Future<void>> futures = [];
		for (var network in networkList.networks) {
			if (network.state != NetworkState.online) {
				continue;
			}
			if (network.bouncerNetwork != null && network.bouncerNetwork!.state != BouncerNetworkState.connected) {
				continue;
			}
			var client = clientProvider.get(network);
			futures.add(_searchNetworkChannels(query, network, client).then(handleActions));
			futures.add(_searchNetworkUsers(query, network, client).then(handleActions));
		}

		try {
			await Future.wait(futures);
		} finally {
			if (_serial == serial && mounted) {
				setState(() {
					_loading = false;
				});
			}
		}
	}

	Future<Iterable<_Action>> _searchNetworkChannels(String query, NetworkModel network, Client client) async {
		var chanTypes = client.isupport.chanTypes;
		if (chanTypes.length == 0) {
			return []; // server doesn't support channels
		}
		if (!chanTypes.contains(query[0])) {
			// TODO: search with as many prefixes as there are CHANTYPES
			query = chanTypes[0] + query;
		}

		if (validateChannel(query, client.isupport) != null) {
			// Not a valid channel name, don't bother
			return [];
		}

		var mask = query;
		if (client.isupport.elist?.mask == true) {
			mask += '*';
		}

		List<ListReply> replies = [];
		try {
			// Use a pretty strict timeout here: it's annoying for users to
			// wait forever before being able to join a channel
			replies = await client.list(mask).timeout(const Duration(seconds: 10));
		} on Exception catch (err) {
			log.print('Failed to LIST channels', error: err);
		}

		List<_Action> actions = [];
		bool exactMatch = false;
		for (var reply in replies) {
			if (!reply.channel.toLowerCase().contains(query.toLowerCase())) {
				continue;
			}
			if (reply.channel.toLowerCase() == query.toLowerCase()) {
				exactMatch = true;
			}
			actions.add(_JoinChannelAction(reply, network));
		}
		if (!exactMatch) {
			actions.add(_CreateChannelAction(query, network));
		}
		return actions;
	}

	Future<Iterable<_Action>> _searchNetworkUsers(String query, NetworkModel network, Client client) async {
		if (validateNickname(query, client.isupport) != null) {
			// Not a valid nickname, don't bother
			return [];
		}

		// TODO: find a way to know whether the server supports masks in WHO
		// https://github.com/ircv3/ircv3-ideas/issues/92
		List<WhoReply> replies = [];
		try {
			replies = await client.who(query);
		} on Exception catch (err) {
			log.print('Failed to WHO user', error: err);
		}

		return replies.map((reply) => _JoinUserAction(reply, network));
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: Text('New conversation'),
				bottom: PreferredSize(
					preferredSize: Size.fromHeight(70),
					child: Container(margin: EdgeInsets.all(10), child: TextField(
						controller: _nameController,
						onChanged: _handleNameChange,
						autofocus: true,
						decoration: InputDecoration(
							hintText: 'Channel name or nickname',
							filled: true,
							border: InputBorder.none,
							suffix: !_loading ? null : SizedBox(
								width: 15,
								height: 15,
								child: CircularProgressIndicator(strokeWidth: 2),
							),
						),
						style: TextStyle(color: Colors.white),
						cursorColor: Colors.white,
					)),
				),
			),
			body: ListView.builder(
				itemCount: _actions.length,
				itemBuilder: (context, index) {
					return _JoinItem(action: _actions[index]);
				},
			),
		);
	}
}

class _JoinItem extends StatelessWidget {
	final _Action _action;

	const _JoinItem({ required _Action action }) :
		_action = action;

	@override
	Widget build(BuildContext context) {
		var action = _action;

		var title = Text.rich(
			TextSpan(children: [
				TextSpan(text: action.title),
				TextSpan(
					text: ' on ${action.network.displayName}',
					style: TextStyle(color: Theme.of(context).textTheme.bodySmall!.color),
				),
			]),
			overflow: TextOverflow.fade,
		);

		if (action is _JoinChannelAction) {
			Widget? trailing;
			if(action.listReply.clients > 0) {
				trailing = Row(
					mainAxisSize: MainAxisSize.min,
					children: [
						Icon(Icons.person),
						Text('${action.listReply.clients}'),
					],
				);
			}
			return ListTile(
				leading: Icon(Icons.tag),
				trailing: trailing,
				title: title,
				subtitle: action.listReply.topic == '' ? null : Text(
					stripAnsiFormatting(action.listReply.topic),
					overflow: TextOverflow.fade,
					softWrap: false,
				),
				onTap: () {
					BufferPage.open(context, action.listReply.channel, action.network);
				},
			);
		} else if (action is _CreateChannelAction) {
			return ListTile(
				leading: Icon(Icons.add),
				title: title,
				onTap: () {
					BufferPage.open(context, action.channel, action.network);
				},
			);
		} else if (action is _JoinUserAction) {
			return ListTile(
				leading: Icon(Icons.person),
				title: title,
				subtitle: isStubRealname(action.whoReply.realname, action.whoReply.nickname) ? null : Text(
					action.whoReply.realname,
					overflow: TextOverflow.fade,
					softWrap: false,
				),
				onTap: () {
					BufferPage.open(context, action.whoReply.nickname, action.network);
				},
			);
		} else {
			throw Exception('Unknown action type: $action');
		}
	}
}

abstract class _Action {
	final NetworkModel network;

	const _Action(this.network);

	String get title;
	int get index;
}

class _JoinChannelAction extends _Action {
	final ListReply listReply;

	const _JoinChannelAction(this.listReply, NetworkModel network) : super(network);

	@override
	String get title => listReply.channel;

	@override
	int get index => 1;
}

class _CreateChannelAction extends _Action {
	final String channel;

	const _CreateChannelAction(this.channel, NetworkModel network) : super(network);

	@override
	String get title => 'Join channel $channel';

	@override
	int get index => 2;
}

class _JoinUserAction extends _Action {
	final WhoReply whoReply;

	const _JoinUserAction(this.whoReply, NetworkModel network) : super(network);

	@override
	String get title => whoReply.nickname;

	@override
	int get index => 0;
}

void _sortActions(List<_Action> actions) {
	actions.sort((a, b) {
		if (a.index != b.index) {
			return a.index - b.index;
		}
		if (a is _JoinChannelAction && b is _JoinChannelAction) {
			return b.listReply.clients - a.listReply.clients;
		}
		return 0;
	});
}
