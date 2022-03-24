import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../irc.dart';
import '../linkify.dart';
import '../models.dart';
import '../widget/edit_topic_dialog.dart';
import 'buffer.dart';

class BufferDetailsPage extends StatefulWidget {
	static const routeName = '/buffer/details';

	@override
	BufferDetailsPageState createState() => BufferDetailsPageState();
}

class BufferDetailsPageState extends State<BufferDetailsPage> {
	Whois? _whois;

	List<WhoReply>? _members;
	bool? _inviteOnly;
	bool? _protectedTopic;

	@override
	void initState() {
		super.initState();

		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		if (client.isNick(buffer.name) && buffer.online != false) {
			_fetchUserDetails(client, buffer.name);
		}
		if (client.isChannel(buffer.name)) {
			_fetchChannelDetails(client, buffer.name);
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

	void _fetchChannelDetails(Client client, String channel) async {
		var modeFuture = client.fetchMode(channel);
		var whoxFields = const { WhoxField.channel, WhoxField.flags, WhoxField.nickname, WhoxField.realname };
		var whoFuture = client.who(channel, whoxFields: whoxFields);

		var modeReply = await modeFuture;
		var whoReplies = await whoFuture;
		if (!mounted) {
			return;
		}

		var modes = modeReply.params[2];

		var prefixes = client.isupport.memberships.map((m) => m.prefix).join('');
		whoReplies.sort((a, b) {
			int i = -1, j = -1;
			if (a.membershipPrefix != null && a.membershipPrefix!.length > 0) {
				i = prefixes.indexOf(a.membershipPrefix![0]);
			}
			if (b.membershipPrefix != null && b.membershipPrefix!.length > 0) {
				j = prefixes.indexOf(b.membershipPrefix![0]);
			}
			if (i < 0) {
				i = prefixes.length;
			}
			if (j < 0) {
				j = prefixes.length;
			}

			if (i != j) {
				return i - j;
			}
			return a.nickname.compareTo(b.nickname);
		});

		setState(() {
			_inviteOnly = modes.contains(ChannelMode.inviteOnly);
			_protectedTopic = modes.contains(ChannelMode.protectedTopic);
			_members = whoReplies;
		});
	}

	@override
	Widget build(BuildContext context) {
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var client = context.read<Client>();

		var canEditTopic = false;
		if (client.state == ClientState.connected && buffer.members != null) {
			var membership = buffer.members!.members[client.nick] ?? '';
			for (var prefix in <String>['~', '@', '%']) {
				if (membership.contains(prefix)) {
					canEditTopic = true;
				}
			}
		}
		if (client.state == ClientState.connected && _protectedTopic == false) {
			canEditTopic = true;
		}

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

		if (buffer.online == false) {
			children.add(ListTile(
				title: Text('Disconnected'),
				subtitle: Text('This user will not receive new messages.'),
				leading: Icon(Icons.error),
			));
		} else if (buffer.away == true) {
			children.add(ListTile(
				title: Text('Away'),
				subtitle: Text('This user might not see new messages immediately.'),
				leading: Icon(Icons.pending),
			));
		}

		if (_inviteOnly == true) {
			children.add(ListTile(
				title: Text('Invite-only'),
				subtitle: Text('Only invited users can join this channel.'),
				leading: Icon(Icons.shield),
			));
		}

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

			if (whois.bot) {
				children.add(ListTile(
					title: Text('Bot'),
					subtitle: Text('This user is an automated bot.'),
					leading: Icon(Icons.smart_toy),
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
							onTap: () {
								BufferPage.open(context, name, network);
							},
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
		if (_members != null) {
			members = SliverList(delegate: SliverChildBuilderDelegate(
				(context, index) {
					var member = _members![index];
					var membership = _membershipDescription(member.membershipPrefix ?? '');
					String? realname;
					if (!isStubRealname(member.realname, member.nickname)) {
						realname = member.realname;
					}
					return ListTile(
						leading: CircleAvatar(child: Text(_initials(member.nickname))),
						title: Text(member.nickname),
						subtitle: realname == null ? null : Text(realname, overflow: TextOverflow.fade, softWrap: false),
						trailing: membership == null ? null : Text(membership),
						onTap: () {
							BufferPage.open(context, member.nickname, network);
						},
					);
				},
				childCount: _members!.length,
			));

			var s = _members!.length > 1 ? 's' : '';

			children.add(Divider());
			children.add(Container(
				margin: const EdgeInsets.all(15),
				child: Text('${_members!.length} member$s', style: TextStyle(fontWeight: FontWeight.bold)),
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
						actions: [
							if (canEditTopic) IconButton(
								icon: Icon(Icons.edit),
								tooltip: 'Edit topic',
								onPressed: () {
									EditTopicDialog.show(context, buffer);
								},
							),
						],
					),
					SliverList(delegate: SliverChildListDelegate(children)),
					if (members != null) members,
					if (commonChannels != null) commonChannels,
				],
			),
		);
	}
}

String? _membershipDescription(String membership) {
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
