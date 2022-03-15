import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../client_controller.dart';
import '../irc.dart';
import '../linkify.dart';
import '../models.dart';

Widget buildBufferDetailsPage(BuildContext context, BufferModel buf) {
	var client = context.read<ClientProvider>().get(buf.network);
	return MultiProvider(
		providers: [
			ChangeNotifierProvider<BufferModel>.value(value: buf),
			ChangeNotifierProvider<NetworkModel>.value(value: buf.network),
			Provider<Client>.value(value: client),
		],
		child: BufferDetailsPage(),
	);
}

class BufferDetailsPage extends StatefulWidget {
	@override
	BufferDetailsPageState createState() => BufferDetailsPageState();
}

class BufferDetailsPageState extends State<BufferDetailsPage> {
	Whois? _whois;

	@override
	void initState() {
		super.initState();

		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		if (client.isNick(buffer.name)) {
			_fetchUserDetails(client, buffer.name);
		}
	}

	void _fetchUserDetails(Client client, String nick) async {
		var whois = await client.whois(nick);
		if (!mounted) {
			return;
		}
		setState(() {
			_whois = whois;
		});
	}

	@override
	Widget build(BuildContext context) {
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var client = context.read<Client>();

		List<Widget> children = [];

		if (buffer.topic != null) {
			children.add(Container(
				margin: const EdgeInsets.all(15),
				child: Builder(builder: (context) {
					var textStyle = DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2);
					var linkStyle = textStyle.apply(color: Colors.blue, decoration: TextDecoration.underline);
					return RichText(
						textAlign: TextAlign.center,
						text: linkify(buffer.topic!, textStyle: textStyle, linkStyle: linkStyle),
					);
				}),
			));
			children.add(Divider());
		}

		if (buffer.realname != null) {
			children.add(ListTile(
				title: Text(buffer.realname!),
				leading: Icon(Icons.person),
			));
		}

		children.add(ListTile(
			title: Text(network.displayName),
			leading: Icon(Icons.hub),
		));

		var whois = _whois;
		SliverList? commonChannels;
		if (whois != null) {
			var loggedInTitle = 'Unauthenticated';
			var loggedInSubtitle = 'This user is logged out.';
			var loggedInIcon = Icons.gpp_bad;
			if (whois.account != null) {
				loggedInIcon = Icons.gpp_good;
				loggedInSubtitle = 'This user is logged in with the account ${whois.account}.';
				if (whois.account == whois.nickname) {
					loggedInTitle = 'Authenticated';
				} else {
					loggedInTitle = 'Authenticated as ${whois.account}';
				}
			}
			children.add(ListTile(
				title: Text(loggedInTitle),
				subtitle: Text(loggedInSubtitle),
				leading: Icon(loggedInIcon),
			));

			if (whois.op) {
				children.add(ListTile(
					title: Text('Network operator'),
					subtitle: Text('This user is a server operator, they have administrator privileges.'),
					leading: Icon(Icons.gavel),
				));
			}

			if (client.params.tls && whois.secureConnection) {
				children.add(ListTile(
					title: Text('Secure connection'),
					subtitle: Text('This user has established a secure connection to the server.'),
					leading: Icon(Icons.lock),
				));
			}

			if (!whois.channels.isEmpty) {
				// TODO: don't sort on each build() call
				var l = whois.channels.keys.toList();
				l.sort();
				commonChannels = SliverList(delegate: SliverChildBuilderDelegate(
					(context, index) {
						var name = l[index];
						return ListTile(
							leading: CircleAvatar(child: Text(_initials(name))),
							title: Text(name),
						);
					},
					childCount: l.length,
				));

				var s = l.length > 1 ? 's' : '';

				children.add(Divider());
				children.add(Container(
					margin: const EdgeInsets.all(15),
					child: Text('${l.length} channel$s in common', style: TextStyle(fontWeight: FontWeight.bold)),
				));
			}
		}

		SliverList? members;
		if (buffer.members != null) {
			// TODO: don't sort on each build() call
			var l = buffer.members!.members.entries.toList();
			l.sort((a, b) {
				var aLevel = _membershipLevel(a.value);
				var bLevel = _membershipLevel(b.value);
				if (aLevel != bLevel) {
					return bLevel - aLevel;
				}
				return a.key.toLowerCase().compareTo(b.key.toLowerCase());
			});
			members = SliverList(delegate: SliverChildBuilderDelegate(
				(context, index) {
					var kv = l.elementAt(index);
					var nickname = kv.key;
					var membership = membershipDescription(kv.value);
					return ListTile(
						leading: CircleAvatar(child: Text(_initials(nickname))),
						title: Text(nickname),
						trailing: membership == null ? null : Text(membership),
					);
				},
				childCount: l.length,
			));

			var s = l.length > 1 ? 's' : '';

			children.add(Divider());
			children.add(Container(
				margin: const EdgeInsets.all(15),
				child: Text('${l.length} members', style: TextStyle(fontWeight: FontWeight.bold)),
			));
		}

		return Scaffold(
			body: CustomScrollView(
				slivers: [
					SliverAppBar(
						pinned: true,
						snap: true,
						floating: true,
						expandedHeight: 128,
						flexibleSpace: FlexibleSpaceBar(
							title: Text(buffer.name),
							centerTitle: true,
						),
					),
					SliverList(delegate: SliverChildListDelegate(children)),
					if (members != null) members,
					if (commonChannels != null) commonChannels,
				],
			),
		);
	}
}

String? membershipDescription(String membership) {
	if (membership == '') {
		return null;
	}
	return membership.split('').map((prefix) {
		switch (prefix) {
		case '~':
			return 'founder';
		case '&':
			return 'protected';
		case '@':
			return 'operator';
		case '%':
			return 'halfop';
		case '+':
			return 'voice';
		default:
			return prefix;
		}
	}).join(', ');
}

int _membershipLevel(String membership) {
	if (membership == '') {
		return 0;
	}
	switch (membership[0]) {
	case '~':
		return 5;
	case '&':
		return 4;
	case '@':
		return 3;
	case '%':
		return 2;
	case '+':
		return 1;
	default:
		return 0;
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
