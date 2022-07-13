import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'connect.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../dialog/edit_profile.dart';
import '../irc.dart';
import '../models.dart';
import '../prefs.dart';
import 'edit_bouncer_network.dart';
import 'network_details.dart';

class SettingsPage extends StatefulWidget {
	static const routeName = '/settings';

	const SettingsPage({ Key? key }) : super(key: key);

	@override
	State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
	late bool _compact;
	late bool _typing;

	@override
	void initState() {
		super.initState();

		var prefs = context.read<Prefs>();
		_compact = prefs.bufferCompact;
		_typing = prefs.typingIndicator;
	}

	void _showLogoutDialog() {
		showDialog<void>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text('Log out'),
				content: Text('Are you sure you want to log out?'),
				actions: [
					TextButton(
						child: Text('CANCEL'),
						onPressed: () {
							Navigator.pop(context);
						},
					),
					ElevatedButton(
						child: Text('LOG OUT'),
						onPressed: () {
							Navigator.pop(context);
							_logout();
						},
					),
				],
			),
		);
	}

	void _logout() {
		var db = context.read<DB>();
		var networkList = context.read<NetworkListModel>();
		var bouncerNetworkList = context.read<BouncerNetworkListModel>();

		for (var network in networkList.networks) {
			db.deleteNetwork(network.networkId);
		}
		networkList.clear();
		bouncerNetworkList.clear();
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
			// This can happen when logging out: the settings page is still
			// being displayed because of a fade-out animation but we no longer
			// have any network configured.
			return Container();
		}

		var mainClient = context.read<ClientProvider>().get(mainNetwork);

		List<Widget> networks = [];
		for (var network in networkList.networks) {
			if (network.networkEntry.caps.containsKey('soju.im/bouncer-networks') && network.networkEntry.bouncerId == null) {
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
					trailing: (mainClient.state != ClientState.connected) ? null : IconButton(
						icon: Icon(Icons.edit),
						onPressed: () {
							EditProfileDialog.show(context, mainNetwork!);
						},
					),
				),
				Column(children: networks),
				if (mainClient.caps.enabled.contains('soju.im/bouncer-networks')) ListTile(
					title: Text('Add network'),
					leading: Icon(Icons.add),
					onTap: () {
						Navigator.pushNamed(context, EditBouncerNetworkPage.routeName);
					},
				),
				Divider(),
				SwitchListTile(
					title: Text('Compact message list'),
					secondary: Icon(Icons.reorder),
					value: _compact,
					onChanged: (bool enabled) {
						context.read<Prefs>().bufferCompact = enabled;
						setState(() {
							_compact = enabled;
						});
					},
				),
				SwitchListTile(
					title: Text('Send & display typing indicators'),
					secondary: Icon(Icons.border_color),
					value: _typing,
					onChanged: (bool enabled) {
						context.read<Prefs>().typingIndicator = enabled;
						setState(() {
							_typing = enabled;
						});
					},
				),
				Divider(),
				ListTile(
					title: Text('About'),
					leading: Icon(Icons.info),
					onTap: () {
						launchUrl(Uri.parse('https://sr.ht/~emersion/goguma/'), mode: LaunchMode.externalApplication);
					},
				),
				ListTile(
					title: Text('Logout'),
					leading: Icon(Icons.logout, color: Colors.red),
					textColor: Colors.red,
					onTap: _showLogoutDialog,
				),
			]),
		));
	}
}

class _NetworkItem extends AnimatedWidget {
	final NetworkModel network;

	_NetworkItem({ Key? key, required this.network }) :
		super(key: key, listenable: Listenable.merge([network, network.bouncerNetwork]));

	@override
	Widget build(BuildContext context) {
		String subtitle;
		if (network.bouncerNetwork != null && network.state == NetworkState.online) {
			subtitle = bouncerNetworkStateDescription(network.bouncerNetwork!.state);
			if (network.bouncerNetwork?.error?.isNotEmpty == true) {
				subtitle = '$subtitle - ${network.bouncerNetwork!.error}';
			}
		} else {
			subtitle = networkStateDescription(network.state);
		}

		return ListTile(
			title: Text(network.displayName),
			subtitle: Text(subtitle),
			leading: Column(
				mainAxisAlignment: MainAxisAlignment.center,
				children: const [Icon(Icons.hub)],
			),
			onTap: () {
				Navigator.pushNamed(context, NetworkDetailsPage.routeName, arguments: network);
			},
		);
	}
}
