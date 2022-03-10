import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'client_controller.dart';
import 'linkify.dart';
import 'models.dart';

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
	@override
	Widget build(BuildContext context) {
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();

		Widget? topic;
		if (buffer.topic != null) {
			topic = Container(
				margin: const EdgeInsets.all(15),
				child: Builder(builder: (context) {
					var textStyle = DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2);
					var linkStyle = textStyle.apply(color: Colors.blue, decoration: TextDecoration.underline);
					return RichText(
						textAlign: TextAlign.center,
						text: linkify(buffer.topic!, textStyle: textStyle, linkStyle: linkStyle),
					);
				}),
			);
		}

		ListTile? realname;
		if (buffer.realname != null) {
			realname = ListTile(
				title: Text(buffer.realname!),
				leading: Icon(Icons.person),
			);
		}

		SliverList? members;
		int? membersCount;
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
						leading: CircleAvatar(child: Text(nickname[0].toUpperCase())),
						title: Text(nickname),
						trailing: membership == null ? null : Text(membership),
					);
				},
				childCount: l.length,
			));
			membersCount = l.length;
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
					SliverList(delegate: SliverChildListDelegate([
						if (topic != null) topic,
						if (topic != null) Divider(),
						if (realname != null) realname,
						ListTile(
							title: Text(network.displayName),
							leading: Icon(Icons.hub),
						),
						if (members != null) Divider(),
						if (members != null) Container(
							margin: const EdgeInsets.all(15),
							child: Text('${membersCount!} members', style: TextStyle(fontWeight: FontWeight.bold)),
						),
					])),
					if (members != null) members,
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
