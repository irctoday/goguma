import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'client-controller.dart';
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

		SliverList? members;
		int? membersCount;
		if (buffer.members != null) {
			// TODO: sort by nickname/membership
			var map = buffer.members!.members;
			members = SliverList(delegate: SliverChildBuilderDelegate(
				(context, index) {
					var kv = map.entries.elementAt(index);
					var nickname = kv.key;
					return ListTile(
						leading: CircleAvatar(child: Text(nickname[0].toUpperCase())),
						title: Text(nickname),
					);
				},
				childCount: map.length,
			));
			membersCount = map.length;
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
