import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'buffer-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'connect-page.dart';
import 'database.dart';
import 'irc.dart';
import 'join-dialog.dart';
import 'models.dart';
import 'network-indicator.dart';

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
			return JoinDialog(onSubmit: (name, network) {
				var client = context.read<ClientProvider>().get(network);
				if (client.isChannel(name)) {
					client.send(IrcMessage('JOIN', [name]));
				} else {
					var db = context.read<DB>();
					db.storeBuffer(BufferEntry(name: name, network: network.networkId)).then((entry) {
						var buffer = BufferModel(entry: entry, network: network);
						context.read<BufferListModel>().add(buffer);
						fetchBufferUser(client, buffer);
						client.monitor([name]);
					});
				}
			});
		});
	}

	void markAllBuffersRead(BuildContext context) {
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();
		var db = context.read<DB>();

		for (var buffer in bufferList.buffers) {
			if (buffer.unreadCount == 0 || buffer.lastDeliveredTime == null) {
				continue;
			}

			buffer.unreadCount = 0;
			buffer.entry.lastReadTime = buffer.lastDeliveredTime!;
			db.storeBuffer(buffer.entry);

			var client = clientProvider.get(buffer.network);
			client.setRead(buffer.name, buffer.lastDeliveredTime!);
		}

		// Re-compute hasUnreadBuffer
		setState(() {});
	}

	void logout(BuildContext context) {
		var db = context.read<DB>();
		var networkList = context.read<NetworkListModel>();

		networkList.networks.forEach((network) {
			db.deleteNetwork(network.networkId);
			db.deleteServer(network.serverId);
		});
		networkList.clear();
		context.read<ClientProvider>().disconnectAll();

		Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
			return ConnectPage();
		}));
	}

	@override
	Widget build(BuildContext context) {
		List<BufferModel> buffers = context.watch<BufferListModel>().buffers;
		if (searchQuery != null) {
			var query = searchQuery!;
			List<BufferModel> filtered = [];
			for (var buf in buffers) {
				if (buf.name.toLowerCase().contains(query) || (buf.topic ?? '').toLowerCase().contains(query)) {
					filtered.add(buf);
				}
			}
			buffers = filtered;
		}

		var hasUnreadBuffer = false;
		buffers.forEach((buffer) {
			if (buffer.unreadCount > 0) {
				hasUnreadBuffer = true;
			}
		});

		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();

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
							case 'mark-all-read':
								markAllBuffersRead(context);
								break;
							case 'logout':
								logout(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Join'), value: 'join'),
								if (hasUnreadBuffer) PopupMenuItem(child: Text('Mark all as read'), value: 'mark-all-read'),
								PopupMenuItem(child: Text('Logout'), value: 'logout'),
							];
						},
					),
				],
			),
			body: NetworkListIndicator(networkList: networkList, child: ValueListenableBuilder<bool>(
				valueListenable: clientProvider.needBackgroundServicePermissions,
				builder: (context, needPermissions, child) {
					if (!needPermissions) {
						return child!;
					}
					return Column(children: [
						MaterialBanner(
							content: Text('This server doesn\'t support modern IRCv3 features. Goguma needs additional permissions to maintain a persistent network connection. This may increase battery usage.'),
							actions: [
								TextButton(
									child: Text('DISMISS'),
									onPressed: () {
										clientProvider.needBackgroundServicePermissions.value = false;
									},
								),
								TextButton(
									child: Text('ALLOW'),
									onPressed: () {
										clientProvider.askBackgroundServicePermissions();
									},
								),
							],
						),
						Expanded(child: child!),
					]);
				},
				child: ListView.builder(
					itemCount: buffers.length,
					itemBuilder: (context, index) {
						var buf = buffers[index];
						return ChangeNotifierProvider.value(
							value: buf,
							child: BufferItem(),
						);
					},
				),
			)),
		);
	}
}

class BufferItem extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return Consumer<BufferModel>(builder: (context, buf, child) {
			var subtitle = buf.topic ?? buf.realname;
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
				subtitle: subtitle == null ? null : Text(subtitle,
					overflow: TextOverflow.fade,
					softWrap: false,
				),
				onTap: () {
					Navigator.push(context, MaterialPageRoute(builder: (context) {
						return buildBufferPage(context, buf);
					}));
				},
			);
		});
	}
}
