import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../irc.dart';
import '../linkify.dart';
import '../models.dart';
import 'buffer.dart';
import 'edit_network.dart';

class NetworkDetailsPage extends StatefulWidget {
	static const routeName = '/settings/network';

	const NetworkDetailsPage({ Key? key }) : super(key: key);

	@override
	_NetworkDetailsPageState createState() => _NetworkDetailsPageState();
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
					TextButton(
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
		var msg = IrcMessage('BOUNCER', ['DELNETWORK', network.networkId.toString()]);
		client.send(msg);

		Navigator.pop(context);
		Navigator.pop(context);
	}

	@override
	Widget build(BuildContext context) {
		var network = context.watch<NetworkModel>();
		List<Widget> children = [];

		if (_motd != null) {
			var motd = stripAnsiFormatting(_motd!);
			children.add(Container(
				margin: const EdgeInsets.all(15),
				child: Builder(builder: (context) {
					var textStyle = DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2);
					var linkStyle = textStyle.apply(color: Colors.blue, decoration: TextDecoration.underline);
					return RichText(
						textAlign: TextAlign.center,
						text: linkify(motd, textStyle: textStyle, linkStyle: linkStyle),
					);
				}),
			));
			children.add(Divider());
		}

		String statusTitle;
		String? statusSubtitle;
		if (network.bouncerNetwork != null && network.state == NetworkState.online) {
			statusTitle = bouncerNetworkStateDescription(network.bouncerNetwork!.state);
			if (network.bouncerNetwork?.error?.isNotEmpty == true) {
				statusSubtitle = network.bouncerNetwork!.error!;
			}
		} else {
			statusTitle = networkStateDescription(network.state);
		}
		children.add(ListTile(
			leading: Icon(Icons.sync),
			title: Text(statusTitle),
			subtitle: statusSubtitle == null ? null : Text(statusSubtitle),
		));

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
							IconButton(
								icon: Icon(Icons.edit),
								tooltip: 'Edit network',
								onPressed: () {
									Navigator.pushNamed(context, EditNetworkPage.routeName, arguments: network.bouncerNetwork!);
								},
							),
							IconButton(
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
