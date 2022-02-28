import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'client-controller.dart';
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
						if (buffer.topic != null) Container(
							margin: const EdgeInsets.all(15),
							child: Builder(builder: (context) => Text(buffer.topic!,
								textAlign: TextAlign.center,
								style: DefaultTextStyle.of(context).style.apply(fontSizeFactor: 1.2),
							)),
						),
					])),
				],
			),
		);
	}
}
