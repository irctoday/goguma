import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect.dart';
import '../client_controller.dart';
import '../database.dart';
import '../dialog/edit_profile.dart';
import '../irc.dart';
import '../models.dart';

class SettingsPage extends StatefulWidget {
	static const routeName = '/settings';

	const SettingsPage({ Key? key }) : super(key: key);

	@override
	_SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
	late bool _compact;

	@override
	void initState() {
		super.initState();
		_compact = context.read<SharedPreferences>().getBool('buffer_compact') ?? false;
	}

	void _logout() {
		var db = context.read<DB>();
		var networkList = context.read<NetworkListModel>();

		for (var network in networkList.networks) {
			db.deleteNetwork(network.networkId);
			db.deleteServer(network.serverId);
		}
		networkList.clear();
		context.read<ClientProvider>().disconnectAll();

		Navigator.pushNamedAndRemoveUntil(context, ConnectPage.routeName, (Route<dynamic> route) => false);
	}

	@override
	Widget build(BuildContext context) {
		var networkList = context.watch<NetworkListModel>();

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

		List<Widget> networks = [];
		for (var network in networkList.networks) {
			if (network.networkEntry.bouncerId == null) {
				continue;
			}
			networks.add(_NetworkItem(network: network));
		}

		var networkListenable = Listenable.merge(networkList.networks);
		return AnimatedBuilder(animation: networkListenable, builder: (context, _) => Scaffold(
			appBar: AppBar(
				title: Text('Settings'),
			),
			body: ListView(children: [
				SizedBox(height: 10),
				ListTile(
					title: Builder(builder: (context) => Text(
						mainNetwork!.nickname,
						style: DefaultTextStyle.of(context).style.apply(
							fontSizeFactor: 1.2,
						).copyWith(
							fontWeight: FontWeight.bold,
						),
					)),
					subtitle: isStubRealname(mainNetwork!.realname, mainNetwork.nickname) ? null : Text(mainNetwork.realname),
					leading: CircleAvatar(
						radius: 40,
						child: Icon(Icons.face, size: 32),
					),
					trailing: IconButton(
						icon: Icon(Icons.edit),
						onPressed: () {
							EditProfileDialog.show(context, mainNetwork!);
						},
					),
				),
				Column(children: networks),
				Divider(),
				ListTile(
					title: Text('Compact message list'),
					leading: Icon(Icons.reorder),
					trailing: Switch(
						value: _compact,
						onChanged: (bool c) {
							setState(() {
								_compact = c;
								context.read<SharedPreferences>().setBool('buffer_compact', c);
							});
						},
					),
				),
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
		));
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
