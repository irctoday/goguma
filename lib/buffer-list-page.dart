import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'client-snackbar.dart';
import 'database.dart';
import 'irc.dart';
import 'join-dialog.dart';
import 'models.dart';
import 'main.dart';

class BufferListPage extends StatefulWidget {
	@override
	BufferListPageState createState() => BufferListPageState();
}

String initials(String name) {
	for (var r in name.runes) {
		var ch = String.fromCharCode(r);
		if (ch == '#') {
			continue;
		}
		return ch.toUpperCase();
	}
	return '';
}

class BufferListPageState extends State<BufferListPage> {
	String? searchQuery;
	TextEditingController searchController = TextEditingController();

	@override
	void dispose() {
		searchController.dispose();
		super.dispose();
	}

	void search(String query) {
		setState(() {
			searchQuery = query.toLowerCase();
		});
	}

	void startSearch() {
		ModalRoute.of(context)?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
			setState(() {
				searchQuery = null;
			});
			searchController.text = '';
		}));
		search('');
	}

	Widget buildSearchField(BuildContext context) {
		return TextField(
			controller: searchController,
			autofocus: true,
			decoration: InputDecoration(
				hintText: 'Search...',
				border: InputBorder.none,
			),
			style: Theme.of(context).accentTextTheme.bodyText2,
			cursorColor: Theme.of(context).accentTextTheme.bodyText2?.color,
			onChanged: search,
		);
	}

	void showJoinDialog(BuildContext context) {
		showDialog(context: context, builder: (dialogContext) {
			return JoinDialog(onSubmit: (name) {
				// TODO: ask the user which server to use
				var server = context.read<ServerListModel>().servers[0];
				var client = context.read<ClientController>().get(server);
				if (client.isChannel(name)) {
					client.send(IRCMessage('JOIN', params: [name]));
				} else {
					var db = context.read<DB>();
					db.storeBuffer(BufferEntry(name: name, server: server.id)).then((entry) {
						var buffer = BufferModel(entry: entry, server: server);
						context.read<BufferListModel>().add(buffer);
					});
				}
			});
		});
	}

	void logout(BuildContext context) {
		var db = context.read<DB>();
		var serverList = context.read<ServerListModel>();

		serverList.servers.forEach((server) {
			db.deleteServer(server.id);
		});
		serverList.clear();
		context.read<ClientController>().disconnectAll();

		Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
			return Goguma();
		}));
	}

	@override
	Widget build(BuildContext context) {
		List<BufferModel> buffers = context.watch<BufferListModel>().buffers;
		if (searchQuery != null) {
			var query = searchQuery!;
			List<BufferModel> filtered = [];
			for (var buf in buffers) {
				if (buf.name.toLowerCase().contains(query) || (buf.subtitle ?? '').toLowerCase().contains(query)) {
					filtered.add(buf);
				}
			}
			buffers = filtered;
		}

		// TODO: aggregate all client errors
		var server = context.watch<ServerListModel>().servers[0];
		var client = context.read<ClientController>().get(server);
		return Scaffold(
			appBar: AppBar(
				leading: searchQuery != null ? CloseButton() : null,
				title: searchQuery != null ? buildSearchField(context) : Text('Goguma'),
				actions: searchQuery != null ? null : [
					IconButton(
						tooltip: 'Search',
						icon: const Icon(Icons.search),
						onPressed: startSearch,
					),
					PopupMenuButton(
						onSelected: (key) {
							switch (key) {
							case 'join':
								showJoinDialog(context);
								break;
							case 'logout':
								logout(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Join'), value: 'join'),
								PopupMenuItem(child: Text('Settings'), value: 'settings'),
								PopupMenuItem(child: Text('Logout'), value: 'logout'),
							];
						},
					),
				],
			),
			body: ClientSnackbar(client: client, child: ListView.builder(
				itemCount: buffers.length,
				itemBuilder: (context, index) {
					var buf = buffers[index];
					return ChangeNotifierProvider.value(
						value: buf,
						child: BufferItem(),
					);
				},
			)),
		);
	}
}

class BufferItem extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return Consumer<BufferModel>(builder: (context, buf, child) {
			return ListTile(
				leading: CircleAvatar(child: Text(initials(buf.name))),
				trailing: (buf.unreadCount == 0) ? null : Container(
					padding: EdgeInsets.all(3),
					decoration: new BoxDecoration(
						color: Colors.red,
						borderRadius: BorderRadius.circular(20),
					),
					constraints: BoxConstraints(minWidth: 20, minHeight: 20),
					child: Text(
						'${buf.unreadCount}',
						style: TextStyle(color: Colors.white, fontSize: 12),
						textAlign: TextAlign.center,
					),
				),
				title: Text(buf.name, overflow: TextOverflow.ellipsis),
				subtitle: buf.subtitle != null ? Text(buf.subtitle!, overflow: TextOverflow.ellipsis) : null,
				onTap: () {
					var client = context.read<ClientController>().get(buf.server);
					buf.unreadCount = 0;
					Navigator.push(context, MaterialPageRoute(builder: (context) {
						return MultiProvider(
							providers: [
								ChangeNotifierProvider<BufferModel>.value(value: buf),
								ChangeNotifierProvider<ServerModel>.value(value: buf.server),
								Provider<Client>.value(value: client),
							],
							child: BufferPage(),
						);
					}));
				},
			);
		});
	}
}
