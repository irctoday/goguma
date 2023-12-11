import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../linkify.dart';
import '../models.dart';
import '../dialog/authenticate.dart';
import 'buffer.dart';
import 'edit_bouncer_network.dart';

class NetworkDetailsPage extends StatefulWidget {
	static const routeName = '/settings/network';

	const NetworkDetailsPage({ super.key });

	@override
	State<NetworkDetailsPage> createState() => _NetworkDetailsPageState();
}

class _NetworkDetailsPageState extends State<NetworkDetailsPage> {
	String? _motd;

	@override
	void initState() {
		super.initState();
		_fetchMotd();
	}

	void _fetchMotd() async {
		var client = context.read<Client>();
		var motd = await client.motd();
		if (!mounted) {
			return;
		}
		setState(() {
			_motd = motd;
		});
	}

	void _showDeleteDialog() {
		var network = context.read<NetworkModel>();
		showDialog<void>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text('Delete network ${network.displayName}?'),
				content: Text('Are you sure you want to delete this network?'),
				actions: [
					TextButton(
						child: Text('CANCEL'),
						onPressed: () {
							Navigator.pop(context);
						},
					),
					ElevatedButton(
						child: Text('DELETE'),
						onPressed: _delete,
					),
				],
			),
		);
	}

	void _delete() {
		var network = context.read<NetworkModel>();
		var client = context.read<Client>();

		// TODO: use main client for this
		client.deleteBouncerNetwork(network.bouncerNetwork!.id);

		Navigator.pop(context);
		Navigator.pop(context);
	}

	void _showLogoutDialog() {
		var network = context.read<NetworkModel>();
		showDialog<void>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text('Log out from ${network.displayName}?'),
				content: Text('Are you sure you want to log out from this network?'),
				actions: [
					TextButton(
						child: Text('CANCEL'),
						onPressed: () {
							Navigator.pop(context);
						},
					),
					ElevatedButton(
						child: Text('LOG OUT'),
						onPressed: _logout,
					),
				],
			),
		);
	}

	void _logout() {
		var client = context.read<Client>();
		client.authWithAnonymous(client.nick);
		Navigator.pop(context);
	}

	@override
	Widget build(BuildContext context) {
		var network = context.watch<NetworkModel>();
		var client = context.read<Client>();

		List<Widget> children = [];

		if (_motd != null) {
			var motd = stripAnsiFormatting(_motd!);
			children.add(Container(
				margin: const EdgeInsets.all(15),
				child: Builder(builder: (context) {
					var textStyle = DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2);
					var linkStyle = TextStyle(color: Colors.blue, decoration: TextDecoration.underline);
					return DefaultTextStyle(
						style: textStyle,
						child: SelectableText.rich(
							linkify(context, motd, linkStyle: linkStyle),
							textAlign: TextAlign.center,
						),
					);
				}),
			));
			children.add(Divider());
		}

		String statusTitle;
		String? statusSubtitle;
		Widget? statusTrailing;
		if (network.bouncerNetwork != null && network.state == NetworkState.online) {
			statusTitle = bouncerNetworkStateDescription(network.bouncerNetwork!.state);
			if (network.bouncerNetwork?.error?.isNotEmpty == true) {
				statusSubtitle = network.bouncerNetwork!.error!;
			}
		} else {
			statusTitle = networkStateDescription(network.state);
		}
		if (network.state == NetworkState.offline) {
			statusTrailing = ElevatedButton(
				onPressed: () {
					client.connect().ignore();
				},
				child: Text('RECONNECT'),
			);
		}
		children.add(ListTile(
			leading: Icon(Icons.sync),
			title: Text(statusTitle),
			subtitle: statusSubtitle == null ? null : Text(statusSubtitle),
			trailing: statusTrailing,
		));

		if (client.caps.enabled.contains('sasl') && network.state == NetworkState.online) {
			if (network.account != null) {
				Widget? trailing;
				if (client.caps.available.containsSasl('ANONYMOUS')) {
					trailing = ElevatedButton(
						onPressed: _showLogoutDialog,
						child: Text('LOG OUT'),
					);
				}

				children.add(ListTile(
					leading: Icon(Icons.gpp_good),
					title: Text('Authenticated'),
					subtitle: Text('You are logged in with the account "${network.account}" on this network.'),
					trailing: trailing,
				));
			} else {
				children.add(ListTile(
					leading: Icon(Icons.gpp_bad),
					title: Text('Unauthenticated'),
					subtitle: Text('You are not logged in with an account on this network.'),
					trailing: ElevatedButton(
						onPressed: () {
							AuthenticateDialog.show(context, network);
						},
						child: Text('LOG IN'),
					),
				));
			}
		}

		var buffers = context.watch<BufferListModel>().buffers.where((buffer) => buffer.network == network).toList();

		var bufferList = SliverList(delegate: SliverChildBuilderDelegate((context, index) {
				var buffer = buffers[index];
				return ListTile(
					leading: CircleAvatar(child: Text(_initials(buffer.name))),
					title: Text(buffer.name),
					onTap: () {
						BufferPage.open(context, buffer.name, buffer.network);
					},
				);
			},
			childCount: buffers.length,
		));
		var s = buffers.length > 1 ? 's' : '';

		children.add(Divider());
		children.add(Container(
			margin: const EdgeInsets.all(15),
			child: Text('${buffers.length} conversation$s', style: TextStyle(fontWeight: FontWeight.bold)),
		));

		return Scaffold(
			body: CustomScrollView(
				slivers: [
					SliverAppBar(
						pinned: true,
						snap: true,
						floating: true,
						expandedHeight: 128,
						flexibleSpace: FlexibleSpaceBar(
							title: Text(network.displayName),
							centerTitle: true,
						),
						actions: [
							if (network.bouncerNetwork != null) IconButton(
								icon: Icon(Icons.edit),
								tooltip: 'Edit network',
								onPressed: () {
									Navigator.pushNamed(context, EditBouncerNetworkPage.routeName, arguments: network.bouncerNetwork!);
								},
							),
							if (network.bouncerNetwork != null) IconButton(
								icon: Icon(Icons.delete_forever),
								tooltip: 'Delete network',
								onPressed: _showDeleteDialog,
							),
						],
					),
					SliverList(delegate: SliverChildListDelegate(children)),
					bufferList,
				],
			),
		);
	}
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
