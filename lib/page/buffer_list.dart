import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../database.dart';
import '../models.dart';
import '../page/join.dart';
import '../widget/network_indicator.dart';
import 'buffer.dart';
import 'connect.dart';

class BufferListPage extends StatefulWidget {
	static const routeName = '/';

	@override
	BufferListPageState createState() => BufferListPageState();
}

String _initials(String name) {
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
	String? _searchQuery;
	final TextEditingController _searchController = TextEditingController();

	@override
	void dispose() {
		_searchController.dispose();
		super.dispose();
	}

	void _search(String query) {
		setState(() {
			_searchQuery = query.toLowerCase();
		});
	}

	void _startSearch() {
		ModalRoute.of(context)?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
			setState(() {
				_searchQuery = null;
			});
			_searchController.text = '';
		}));
		_search('');
	}

	Widget _buildSearchField(BuildContext context) {
		return TextField(
			controller: _searchController,
			autofocus: true,
			decoration: InputDecoration(
				hintText: 'Search...',
				border: InputBorder.none,
			),
			style: TextStyle(color: Colors.white),
			cursorColor: Colors.white,
			onChanged: _search,
		);
	}

	void _markAllBuffersRead(BuildContext context) {
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

	void _logout(BuildContext context) {
		var db = context.read<DB>();
		var networkList = context.read<NetworkListModel>();

		for (var network in networkList.networks) {
			db.deleteNetwork(network.networkId);
			db.deleteServer(network.serverId);
		}
		networkList.clear();
		context.read<ClientProvider>().disconnectAll();

		Navigator.pushReplacementNamed(context, ConnectPage.routeName);
	}

	@override
	Widget build(BuildContext context) {
		List<BufferModel> buffers = context.watch<BufferListModel>().buffers;
		if (_searchQuery != null) {
			var query = _searchQuery!;
			List<BufferModel> filtered = [];
			for (var buf in buffers) {
				if (buf.name.toLowerCase().contains(query) || (buf.topic ?? '').toLowerCase().contains(query)) {
					filtered.add(buf);
				}
			}
			buffers = filtered;
		}

		Map<String, int> bufferNames = {};
		var hasUnreadBuffer = false;
		for (var buffer in buffers) {
			bufferNames.update(buffer.name.toLowerCase(), (n) => n + 1, ifAbsent: () => 1);
			if (buffer.unreadCount > 0) {
				hasUnreadBuffer = true;
			}
		}

		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();

		return Scaffold(
			appBar: AppBar(
				leading: _searchQuery != null ? CloseButton() : null,
				title: Builder(builder: (context) {
					if (_searchQuery != null) {
						return _buildSearchField(context);
					} else {
						return Text('Goguma');
					}
				}),
				actions: _searchQuery != null ? null : [
					IconButton(
						tooltip: 'Search',
						icon: const Icon(Icons.search),
						onPressed: _startSearch,
					),
					PopupMenuButton(
						onSelected: (key) {
							switch (key) {
							case 'join':
								Navigator.pushNamed(context, JoinPage.routeName);
								break;
							case 'mark-all-read':
								_markAllBuffersRead(context);
								break;
							case 'logout':
								_logout(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('New conversation'), value: 'join'),
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
						var buffer = buffers[index];
						return _BufferItem(
							buffer: buffer,
							showNetworkName: bufferNames[buffer.name.toLowerCase()]! > 1,
						);
					},
				),
			)),
		);
	}
}

class _BufferItem extends AnimatedWidget {
	final BufferModel buffer;
	final bool showNetworkName;

	const _BufferItem({ Key? key, required this.buffer, this.showNetworkName = false }) : super(key: key, listenable: buffer);

	@override
	Widget build(BuildContext context) {
		var subtitle = buffer.topic ?? buffer.realname;

		Widget title;
		if (showNetworkName) {
			title = Text.rich(
				TextSpan(children: [
					TextSpan(text: buffer.name),
					TextSpan(
						text: ' on ${buffer.network.displayName}',
						style: TextStyle(color: Theme.of(context).textTheme.caption!.color),
					),
				]),
				overflow: TextOverflow.fade,
			);
		} else {
			title = Text(buffer.name, overflow: TextOverflow.ellipsis);
		}

		return ListTile(
			leading: CircleAvatar(child: Text(_initials(buffer.name))),
			trailing: (buffer.unreadCount == 0) ? null : Container(
				padding: EdgeInsets.all(3),
				decoration: BoxDecoration(
					color: Colors.red,
					borderRadius: BorderRadius.circular(20),
				),
				constraints: BoxConstraints(minWidth: 20, minHeight: 20),
				child: Text(
					'${buffer.unreadCount}',
					style: TextStyle(color: Colors.white, fontSize: 12),
					textAlign: TextAlign.center,
				),
			),
			title: title,
			subtitle: subtitle == null ? null : Text(subtitle,
				overflow: TextOverflow.fade,
				softWrap: false,
			),
			onTap: () {
				Navigator.pushNamed(context, BufferPage.routeName, arguments: buffer);
			},
		);
	}
}
