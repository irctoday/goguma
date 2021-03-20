import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'connect-page.dart';
import 'irc.dart';
import 'join-dialog.dart';

void main() {
	runApp(MultiProvider(
		providers: [
			ChangeNotifierProvider(create: (context) => BufferListModel()),
		],
		child: GogumaApp(),
	));
}

class GogumaApp extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return MaterialApp(
			title: 'Goguma',
			theme: ThemeData(primarySwatch: Colors.indigo),
			home: Goguma(),
			debugShowCheckedModeBanner: false,
		);
	}
}

class Goguma extends StatefulWidget {
	@override
	GogumaState createState() => GogumaState();
}

class GogumaState extends State<Goguma> {
	ConnectParams? connectParams;
	Client? client;

	connect(ConnectParams params) {
		connectParams = params;
		client = Client(params: params);

		client!.messages.listen((msg) {
			var bufferList = context.read<BufferListModel>();
			switch (msg.cmd) {
			case 'JOIN':
				if (msg.prefix?.name != client!.nick) {
					break;
				}
				bufferList.add(BufferItemModel(name: msg.params[0]));
				break;
			case RPL_TOPIC:
				var channel = msg.params[1];
				var topic = msg.params[2];
				bufferList.getByName(channel)?.subtitle = topic;
				break;
			case RPL_NOTOPIC:
				var channel = msg.params[1];
				bufferList.getByName(channel)?.subtitle = null;
				break;
			case 'TOPIC':
				var channel = msg.params[0];
				String? topic = null;
				if (msg.params.length > 1) {
					topic = msg.params[1];
				}
				bufferList.getByName(channel)?.subtitle = topic;
				break;
			}
		});
	}

	@override
	void dispose() {
		client?.disconnect();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		if (connectParams == null) {
			return ConnectPage(onSubmit: (params) {
				connect(params);

				Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
					return BufferListPage();
				}));
			});
		} else {
			return Provider<Client>.value(value: client!, child: BufferListPage());
		}
	}
}

class BufferListModel extends ChangeNotifier {
	List<BufferItemModel> _buffers = [];

	UnmodifiableListView<BufferItemModel> get buffers => UnmodifiableListView(_buffers);

	@override
	void dispose() {
		_buffers.forEach((buf) => buf.dispose());
		super.dispose();
	}

	void add(BufferItemModel buf) {
		_buffers.add(buf);
		notifyListeners();
	}

	BufferItemModel? getByName(String name) {
		for (var item in _buffers) {
			if (item.name == name) {
				return item;
			}
		}
		return null;
	}
}


class BufferListPage extends StatefulWidget {
	@override
	BufferListPageState createState() => BufferListPageState();
}

class BufferItemModel extends ChangeNotifier {
	String name;
	String? _subtitle;

	BufferItemModel({ required this.name, String? subtitle }) : _subtitle = subtitle;

	String? get subtitle => _subtitle;

	set subtitle(String? subtitle) {
		_subtitle = subtitle;
		notifyListeners();
	}
}

String initials(String name) {
	for (var r in name.runes) {
		var ch = String.fromCharCode(r);
		if (ch == '#') {
			continue;
		}
		return ch.toUpperCase();
	}
	return '';
}

class BufferListPageState extends State<BufferListPage> {
	String? searchQuery;
	TextEditingController searchController = TextEditingController();

	@override
	void dispose() {
		searchController.dispose();
		super.dispose();
	}

	void search(String query) {
		setState(() {
			searchQuery = query.toLowerCase();
		});
	}

	void startSearch() {
		ModalRoute.of(context)?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
			setState(() {
				searchQuery = null;
			});
			searchController.text = '';
		}));
		search('');
	}

	Widget buildSearchField(BuildContext context) {
		return TextField(
			controller: searchController,
			autofocus: true,
			decoration: InputDecoration(
				hintText: 'Search...',
				border: InputBorder.none,
			),
			style: Theme.of(context).accentTextTheme.bodyText2,
			onChanged: search,
		);
	}

	void showJoinDialog(BuildContext context) {
		showDialog(context: context, builder: (dialogContext) {
			return JoinDialog(onSubmit: (channel) {
				context.read<Client>().send(IRCMessage('JOIN', params: [channel]));
			});
		});
	}

	@override
	Widget build(BuildContext context) {
		List<BufferItemModel> buffers = context.watch<BufferListModel>().buffers;
		if (searchQuery != null) {
			var query = searchQuery!;
			List<BufferItemModel> filtered = [];
			for (var buf in buffers) {
				if (buf.name.toLowerCase().contains(query) || (buf.subtitle ?? '').toLowerCase().contains(query)) {
					filtered.add(buf);
				}
			}
			buffers = filtered;
		}

		return Scaffold(
			appBar: AppBar(
				leading: searchQuery != null ? CloseButton() : null,
				title: searchQuery != null ? buildSearchField(context) : Text('Goguma'),
				actions: searchQuery != null ? null : [
					IconButton(
						tooltip: 'Search',
						icon: const Icon(Icons.search),
						onPressed: startSearch,
					),
					PopupMenuButton(
						onSelected: (key) {
							switch (key) {
							case 'join':
								showJoinDialog(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Join'), value: 'join'),
								PopupMenuItem(child: Text('Settings'), value: 'settings'),
							];
						},
					),
				],
			),
			body: ListView.builder(
				itemCount: buffers.length,
				itemBuilder: (context, index) {
					var buf = buffers[index];
					return ChangeNotifierProvider.value(
						value: buf,
						child: BufferItem(),
					);
				},
			),
		);
	}
}

class BufferItem extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return Consumer<BufferItemModel>(builder: (context, buf, child) {
			return ListTile(
				leading: CircleAvatar(child: Text(initials(buf.name))),
				title: Text(buf.name, overflow: TextOverflow.ellipsis),
				subtitle: buf.subtitle != null ? Text(buf.subtitle!, overflow: TextOverflow.ellipsis) : null,
				onTap: () {
					Navigator.push(context, MaterialPageRoute(builder: (context) {
						return BufferPage();
					}));
				},
			);
		});
	}
}

class BufferPage extends StatefulWidget {
	@override
	BufferPageState createState() => BufferPageState();
}

class Message {
	String sender;
	String body;

	Message({ required this.sender, required this.body });
}

class BufferPageState extends State<BufferPage> {
	List<Message> messages = [
		Message(sender: 'romangg', body: 'I think it would be a nice way to push improvements for multi-seat'),
		Message(sender: 'emersion', body: 'just need to make sure we didn\'t miss any use-case'),
		Message(sender: 'pq', body: 'iirc it uses text-input-unstable something something'),
	];

	final composerFocusNode = FocusNode();
	final composerFormKey = GlobalKey<FormState>();
	final composerController = TextEditingController();

	void submitComposer() {
		if (composerController.text != '') {
			setState(() {
				messages.add(Message(sender: 'emersion', body: composerController.text));
			});
		}
		composerFormKey.currentState!.reset();
		composerFocusNode.requestFocus();
	}

	@override
	void dispose() {
		composerController.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: Column(
					mainAxisAlignment: MainAxisAlignment.center,
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
						Text('#wayland'),
						Text('https://wayland.freedesktop.org | Discussion about the Wayland protocol and its implementations, plus libinput', style: TextStyle(fontSize: 12.0)),
					],
				),
				actions: [
					PopupMenuButton<Text>(
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Details')),
								PopupMenuItem(child: Text('Leave')),
							];
						},
					),
				],
			),
			body: Column(children: [
				Expanded(child: ListView.builder(
					itemCount: messages.length,
					itemBuilder: (context, index) {
						var msg = messages[index];

						var colorSwatch = Colors.primaries[msg.sender.hashCode % Colors.primaries.length];
						var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);

						//var boxColor = Theme.of(context).accentColor;
						var boxColor = colorScheme.primary;
						var boxAlignment = Alignment.centerLeft;
						var textStyle = DefaultTextStyle.of(context).style.apply(color: colorScheme.onPrimary);
						if (msg.sender == 'emersion') {
							boxColor = Colors.grey[200]!;
							boxAlignment = Alignment.centerRight;
							textStyle = DefaultTextStyle.of(context).style;
						}

						const margin = 16.0;
						var marginTop = margin;
						if (index > 0) {
							marginTop = 0.0;
						}

						return Align(
							alignment: boxAlignment,
							child: Container(
								decoration: BoxDecoration(
									borderRadius: BorderRadius.circular(10),
									color: boxColor,
								),
								padding: EdgeInsets.all(10),
								margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: margin),
								child: RichText(text: TextSpan(
									children: [
										TextSpan(text: msg.sender + '\n', style: TextStyle(fontWeight: FontWeight.bold)),
										TextSpan(text: msg.body),
									],
									style: textStyle,
								)),
							),
						);
					},
				)),
				Material(elevation: 15, child: Container(
					padding: EdgeInsets.all(10),
					child: Form(key: composerFormKey, child: Row(children: [
						Expanded(child: TextFormField(
							decoration: InputDecoration(
								hintText: 'Write a message...',
								border: InputBorder.none,
							),
							onFieldSubmitted: (value) {
								submitComposer();
							},
							focusNode: composerFocusNode,
							controller: composerController,
						)),
						FloatingActionButton(
							onPressed: () {
								submitComposer();
							},
							tooltip: 'Send',
							child: Icon(Icons.send, size: 18),
							mini: true,
							elevation: 0,
						),
					])),
				)),
			]),
		);
	}
}
