import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';

class SettingsPage extends StatefulWidget {
	static const routeName = '/settings';

	const SettingsPage({ Key? key }) : super(key: key);

	@override
	_SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
	void _logout() {
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
		var networkList = context.read<NetworkListModel>();
		var clientProvider = context.read<ClientProvider>();

		NetworkModel? mainNetwork;
		for (var network in networkList.networks) {
			if (network.networkEntry.bouncerId == null) {
				mainNetwork = network;
				break;
			}
		}
		if (mainNetwork == null) {
			throw Exception('No main network found');
		}

		var client = clientProvider.get(mainNetwork);

		List<Widget> networks = [];
		for (var network in networkList.networks) {
			if (network.networkEntry.bouncerId == null) {
				continue;
			}
			networks.add(_NetworkItem(network: network));
		}

		return Scaffold(
			appBar: AppBar(
				title: Text('Settings'),
			),
			body: ListView(children: [
				SizedBox(height: 10),
				ListTile(
					title: Builder(builder: (context) => Text(
						client.nick,
						style: DefaultTextStyle.of(context).style.apply(
							fontSizeFactor: 1.2,
						).copyWith(
							fontWeight: FontWeight.bold,
						),
					)),
					subtitle: isStubRealname(client.realname, client.nick) ? null : Text(client.realname),
					leading: CircleAvatar(
						radius: 40,
						child: Icon(Icons.face, size: 32),
					),
				),
				Column(children: networks),
				Divider(),
				ListTile(
					title: Text('About'),
					leading: Icon(Icons.info),
					onTap: () {
						launch('https://sr.ht/~emersion/goguma/');
					},
				),
				ListTile(
					title: Text('Logout'),
					leading: Icon(Icons.logout, color: Colors.red),
					textColor: Colors.red,
					onTap: _logout,
				),
			]),
		);
	}
}

class _NetworkItem extends AnimatedWidget {
	final NetworkModel network;

	const _NetworkItem({ Key? key, required this.network }) : super(key: key, listenable: network);

	@override
	Widget build(BuildContext context) {
		String subtitle;
		if (network.bouncerNetwork != null && network.state == NetworkState.online) {
			subtitle = _bouncerNetworkStateDescription(network.bouncerNetwork!.state);
		} else {
			subtitle = _networkStateDescription(network.state);
		}

		return ListTile(
			title: Text(network.displayName),
			subtitle: Text(subtitle),
			leading: Icon(Icons.hub),
		);
	}
}

String _networkStateDescription(NetworkState state) {
	switch (state) {
	case NetworkState.offline:
		return 'Disconnected';
	case NetworkState.connecting:
		return 'Connecting…';
	case NetworkState.registering:
		return 'Logging in…';
	case NetworkState.synchronizing:
		return 'Synchronizing…';
	case NetworkState.online:
		return 'Connected';
	}
}

String _bouncerNetworkStateDescription(BouncerNetworkState state) {
	switch (state) {
	case BouncerNetworkState.disconnected:
		return 'Bouncer disconnected from network';
	case BouncerNetworkState.connecting:
		return 'Bouncer connecting to network…';
	case BouncerNetworkState.connected:
		return 'Connected';
	}
}
