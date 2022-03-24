import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer.dart';
import '../database.dart';
import '../irc.dart';
import '../client.dart';
import '../client_controller.dart';
import '../models.dart';

class JoinPage extends StatefulWidget {
	static const routeName = '/join';

	const JoinPage({ Key? key }) : super(key: key);

	@override
	_JoinPageState createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
	final TextEditingController _nameController = TextEditingController();
	int _serial = 0;
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
			_search(query);
		});
	}

	void _search(String query) {
		setState(() {
			_actions = [];
		});

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
			if (_serial != serial) {
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

		Future.wait(futures).whenComplete(() {
			if (_serial != serial) {
				return;
			}
			setState(() {
				_loading = false;
			});
		});
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

		var mask = query;
		if (client.isupport.elist?.mask == true) {
			mask += '*';
		}

		List<ListReply> replies = [];
		try {
			replies = await client.list(mask);
		} catch (err) {
			print('Failed to LIST channels: $err');
		}

		List<_Action> actions = [];
		bool exactMatch = false;
		for (var reply in replies) {
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
		var chanTypes = client.isupport.chanTypes;
		if (chanTypes.contains(query[0])) {
			return []; // user is explicitly searching for a channel
		}

		// TODO: find a way to know whether the server supports masks in WHO
		// https://github.com/ircv3/ircv3-ideas/issues/92
		List<WhoReply> replies = [];
		try {
			replies = await client.who(query);
		} catch (err) {
			print('Failed to WHO user: $err');
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

	const _JoinItem({ Key? key, required _Action action }) :
		_action = action,
		super(key: key);

	void _open(BuildContext context, String name, NetworkModel network) async {
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();
		var client = clientProvider.get(network);

		var buffer = bufferList.get(name, network);
		if (buffer == null) {
			var db = context.read<DB>();
			var entry = await db.storeBuffer(BufferEntry(name: name, network: network.networkId));
			buffer = BufferModel(entry: entry, network: network);
			bufferList.add(buffer);
		}

		Navigator.pop(context);
		Navigator.pushNamed(context, BufferPage.routeName, arguments: buffer);

		if (client.isChannel(name)) {
			join(client, buffer);
		} else {
			fetchBufferUser(client, buffer);
			client.monitor([name]);
		}
	}

	Widget build(BuildContext context) {
		var action = _action;

		var title = RichText(overflow: TextOverflow.fade, text: TextSpan(children: [
			TextSpan(text: action.title),
			TextSpan(
				text: ' on ${action.network.displayName}',
				style: TextStyle(color: DefaultTextStyle.of(context).style.color!.withOpacity(0.7)),
			),
		]));

		if (action is _JoinChannelAction) {
			return ListTile(
				leading: Icon(Icons.tag),
				title: title,
				subtitle: action.listReply.topic == '' ? null : Text(
					action.listReply.topic,
					overflow: TextOverflow.fade,
					softWrap: false,
				),
				onTap: () {
					_open(context, action.listReply.channel, action.network);
				},
			);
		} else if (action is _CreateChannelAction) {
			return ListTile(
				leading: Icon(Icons.add),
				title: title,
				onTap: () {
					_open(context, action.channel, action.network);
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
					_open(context, action.whoReply.nickname, action.network);
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
		return 0;
	});
}
