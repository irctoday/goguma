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
			topic = Column(children: [
				Container(
					margin: const EdgeInsets.all(15),
					// TODO: linkify
					child: Builder(builder: (context) {
						var textStyle = DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2);
						var linkStyle = textStyle.apply(color: Colors.blue, decoration: TextDecoration.underline);
						return RichText(
							textAlign: TextAlign.center,
							text: linkify(buffer.topic!, textStyle: textStyle, linkStyle: linkStyle),
						);
					}),
				),
				Divider(),
			]);
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
						ListTile(
							title: Text(network.displayName),
							leading: Icon(Icons.hub),
						),
						// TODO: list of channel members, user details, etc
					])),
				],
			),
		);
	}
}
