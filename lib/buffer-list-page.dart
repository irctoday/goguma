import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'buffer-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'client-snackbar.dart';
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
			return JoinDialog(onSubmit: (channel) {
				// TODO: ask the user which server to use
				var client = context.read<ClientController>().get(ServerModel());
				client.send(IRCMessage('JOIN', params: [channel]));
			});
		});
	}

	void logout(BuildContext context) {
		context.read<ClientController>().disconnectAll();

		SharedPreferences.getInstance().then((prefs) {
			prefs.remove('server.host');
			prefs.remove('server.port');
			prefs.remove('server.tls');
			prefs.remove('server.nick');
			prefs.remove('server.pass');
		});

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
		var client = context.read<ClientController>().get(ServerModel());
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
				title: Text(buf.name, overflow: TextOverflow.ellipsis),
				subtitle: buf.subtitle != null ? Text(buf.subtitle!, overflow: TextOverflow.ellipsis) : null,
				onTap: () {
					var client = context.read<ClientController>().get(buf.server);
					Navigator.push(context, MaterialPageRoute(builder: (context) {
						return MultiProvider(
							providers: [
								ChangeNotifierProvider<BufferModel>.value(value: buf),
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
