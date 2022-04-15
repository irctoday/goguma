import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import '../page/join.dart';
import '../page/settings.dart';
import '../widget/network_indicator.dart';
import 'buffer.dart';

class BufferListPage extends StatefulWidget {
	static const routeName = '/';

	const BufferListPage({ Key? key }) : super(key: key);

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

	void _markAllBuffersRead() {
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

		return Scaffold(
			appBar: AppBar(
				leading: _searchQuery != null ? CloseButton() : null,
				title: Builder(builder: (context) {
					if (_searchQuery != null) {
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
								_markAllBuffersRead();
								break;
							case 'settings':
								Navigator.pushNamed(context, SettingsPage.routeName);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('New conversation'), value: 'join'),
								if (hasUnreadBuffer) PopupMenuItem(child: Text('Mark all as read'), value: 'mark-all-read'),
								PopupMenuItem(child: Text('Settings'), value: 'settings'),
							];
						},
					),
				],
			),
			body: NetworkListIndicator(
				child: _BackgroundServicePermissionBanner(
					child: buffers.length == 0 ? _BufferListPlaceholder() : ListView.builder(
						itemCount: buffers.length,
						itemBuilder: (context, index) {
							var buffer = buffers[index];
							return _BufferItem(
								buffer: buffer,
								showNetworkName: bufferNames[buffer.name.toLowerCase()]! > 1,
							);
						},
					),
				),
			),
		);
	}
}

class _BackgroundServicePermissionBanner extends StatelessWidget {
	final Widget child;

	const _BackgroundServicePermissionBanner({
		Key? key,
		required this.child,
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		var clientProvider = context.read<ClientProvider>();
		return ValueListenableBuilder<bool>(
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
			child: child,
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

		List<Widget> trailing = [];
		if (buffer.muted) {
			trailing.add(Icon(
				Icons.notifications_off,
				size: 20,
				color: Theme.of(context).textTheme.caption!.color,
			));
		}
		if (buffer.pinned) {
			trailing.add(Icon(
				Icons.push_pin,
				size: 20,
				color: Theme.of(context).textTheme.caption!.color,
			));
		}
		if (buffer.unreadCount != 0) {
			trailing.add(Container(
				padding: EdgeInsets.all(3),
				decoration: BoxDecoration(
					color: buffer.muted ? Theme.of(context).textTheme.caption!.color : Colors.red,
					borderRadius: BorderRadius.circular(20),
				),
				constraints: BoxConstraints(minWidth: 20, minHeight: 20),
				child: Text(
					'${buffer.unreadCount}',
					style: TextStyle(color: Colors.white, fontSize: 12),
					textAlign: TextAlign.center,
				),
			));
		}

		// extracted from the ListTile source
		var theme = Theme.of(context);
		var dense = theme.listTileTheme.dense ?? false;
		var height = (dense ? 64.0 : 72.0) + theme.visualDensity.baseSizeAdjustment.dy;

		return Container(alignment: Alignment.center, height: height, child: ListTile(
			leading: CircleAvatar(child: Text(_initials(buffer.name))),
			trailing: trailing.isEmpty ? null : Wrap(
				spacing: 5,
				children: trailing,
			),
			title: title,
			subtitle: subtitle == null ? null : Text(
				stripAnsiFormatting(subtitle),
				overflow: TextOverflow.fade,
				softWrap: false,
			),
			onTap: () {
				Navigator.pushNamed(context, BufferPage.routeName, arguments: buffer);
			},
		));
	}
}

class _BufferListPlaceholder extends StatelessWidget {
	_BufferListPlaceholder({ Key? key }) : super(key: key);

	@override
	Widget build(BuildContext context) {
		// TODO: suggest to add a new network in the soju.im/bouncer-networks case
		return Center(child: Column(
			mainAxisAlignment: MainAxisAlignment.center,
			children: [
				Icon(Icons.tag, size: 100),
				Text(
					'Join a conversation',
					style: Theme.of(context).textTheme.headlineSmall,
					textAlign: TextAlign.center,
				),
				SizedBox(height: 15),
				Container(
					constraints: BoxConstraints(maxWidth: 300),
					child: Text(
						'Welcome to IRC! To get started, join a channel or start a discussion with a user.',
						textAlign: TextAlign.center,
					),
				),
				SizedBox(height: 15),
				ElevatedButton(
					child: Text('New conversation'),
					onPressed: () {
						Navigator.pushNamed(context, JoinPage.routeName);
					},
				),
			],
		));
	}
}
