import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client_controller.dart';
import '../database.dart';
import '../models.dart';
import '../page/edit_bouncer_network.dart';
import '../page/join.dart';
import '../page/settings.dart';
import '../widget/network_indicator.dart';
import 'buffer.dart';

class BufferListPage extends StatefulWidget {
	static const routeName = '/';

	const BufferListPage({ super.key });

	@override
	State<BufferListPage> createState() => _BufferListPageState();
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

class _BufferListPageState extends State<BufferListPage> {
	String? _searchQuery;
	final TextEditingController _searchController = TextEditingController();
	final _listKey = GlobalKey();

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
			client.setReadMarker(buffer.name, buffer.lastDeliveredTime!);
		}

		// Re-compute hasUnreadBuffer
		setState(() {});
	}

	bool _shouldSuggestNewNetwork() {
		var clientProvider = context.read<ClientProvider>();
		if (clientProvider.clients.length != 1) {
			return false;
		}

		var client = clientProvider.clients.first;
		return client.caps.enabled.contains('soju.im/bouncer-networks') && client.params.bouncerNetId == null;
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

		Widget body;
		if (buffers.length == 0) {
			if (_searchQuery != null) {
				body = _BufferListPlaceholder(
					icon: Icons.search,
					title: 'No search result',
					subtitle: 'No conversation matches the search query.',
				);
			} else if (_shouldSuggestNewNetwork()) {
				body = _BufferListPlaceholder(
					icon: Icons.hub,
					title: 'Join a network',
					subtitle: 'Welcome to IRC! To get started, join a network.',
					trailing: ElevatedButton(
						child: Text('New network'),
						onPressed: () {
							Navigator.pushNamed(context, EditBouncerNetworkPage.routeName);
						},
					),
				);
			} else {
				body = _BufferListPlaceholder(
					icon: Icons.tag,
					title: 'Join a conversation',
					subtitle: 'Welcome to IRC! To get started, join a channel or start a discussion with a user.',
					trailing: ElevatedButton(
						child: Text('New conversation'),
						onPressed: () {
							Navigator.pushNamed(context, JoinPage.routeName);
						},
					),
				);
			}
		} else {
			body = ListView.builder(
				key: _listKey,
				itemCount: buffers.length,
				itemBuilder: (context, index) {
					var buffer = buffers[index];
					return _BufferItem(
						buffer: buffer,
						showNetworkName: bufferNames[buffer.name.toLowerCase()]! > 1,
					);
				},
			);
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
				child: _BackgroundServicePermissionBanner(child: body)
			),
		);
	}
}

class _BackgroundServicePermissionBanner extends StatelessWidget {
	final Widget child;

	const _BackgroundServicePermissionBanner({
		required this.child,
	});

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

	const _BufferItem({ required this.buffer, this.showNetworkName = false }) : super(listenable: buffer);

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
						style: TextStyle(color: Theme.of(context).textTheme.bodySmall!.color),
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
				color: Theme.of(context).textTheme.bodySmall!.color,
			));
		}
		if (buffer.pinned) {
			trailing.add(Icon(
				Icons.push_pin,
				size: 20,
				color: Theme.of(context).textTheme.bodySmall!.color,
			));
		}
		if (buffer.archived) {
			trailing.add(Icon(
				Icons.inventory_2,
				size: 20,
				color: Theme.of(context).textTheme.bodySmall!.color,
			));
		}
		if (buffer.unreadCount != 0) {
			var theme = Theme.of(context);
			trailing.add(Container(
				padding: EdgeInsets.all(3),
				decoration: BoxDecoration(
					color: buffer.muted ? theme.textTheme.bodySmall!.color : theme.colorScheme.secondaryContainer,
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

		// extracted from the ListTile sourceIconData
		var theme = Theme.of(context);
		var dense = theme.listTileTheme.dense ?? false;
		var height = (dense ? 64.0 : 72.0) + theme.visualDensity.baseSizeAdjustment.dy;

		return Container(alignment: Alignment.center, height: height, child: ListTile(
			leading: CircleAvatar(
				child: Text(
					_initials(buffer.name),
					semanticsLabel: ''
				)
			),
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
				Navigator.pushNamed(context, BufferPage.routeName, arguments: BufferPageArguments(buffer: buffer));
			},
		));
	}
}

class _BufferListPlaceholder extends StatelessWidget {
	final IconData icon;
	final String title;
	final String subtitle;
	final Widget? trailing;

	const _BufferListPlaceholder({
		required this.icon,
		required this.title,
		required this.subtitle,
		this.trailing,
	});

	@override
	Widget build(BuildContext context) {
		return Center(child: Column(
			mainAxisAlignment: MainAxisAlignment.center,
			children: [
				Icon(icon, size: 100),
				Text(
					title,
					style: Theme.of(context).textTheme.headlineSmall,
					textAlign: TextAlign.center,
				),
				SizedBox(height: 15),
				Container(
					constraints: BoxConstraints(maxWidth: 300),
					child: Text(
						subtitle,
						textAlign: TextAlign.center,
					),
				),
				SizedBox(height: 15),
				if (trailing != null) trailing!,
			],
		));
	}
}
