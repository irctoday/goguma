import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../irc.dart';
import '../models.dart';
import 'buffer.dart';
import 'edit_network.dart';

class NetworkDetailsPage extends StatefulWidget {
	static const routeName = '/network/details';

	const NetworkDetailsPage({ Key? key }) : super(key: key);

	@override
	_NetworkDetailsPageState createState() => _NetworkDetailsPageState();
}

class _NetworkDetailsPageState extends State<NetworkDetailsPage> {
	@override
	Widget build(BuildContext context) {
		var network = context.watch<NetworkModel>();
		List<Widget> children = [];

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

		var client = context.read<Client>();
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
								onPressed: () {
									var msg = IrcMessage('BOUNCER', ['DELNETWORK', network.networkId.toString()]);
									client.send(msg);
									Navigator.pop(context);
								},
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
