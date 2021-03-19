import 'package:flutter/material.dart';

void main() {
	runApp(Goguma());
}

class Goguma extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return MaterialApp(
			title: 'Goguma',
			theme: ThemeData(primarySwatch: Colors.indigo),
			//home: BufferListPage(),
			home: ConnectPage(),
			debugShowCheckedModeBanner: false,
		);
	}
}

class ConnectPage extends StatefulWidget {
	@override
	ConnectPageState createState() => ConnectPageState();
}

class ConnectPageState extends State<ConnectPage> {
	final formKey = GlobalKey<FormState>();

	void submit() {
		Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
			return BufferListPage();
		}));
	}

	@override
	Widget build(BuildContext context) {
		final focusNode = FocusScope.of(context);
		return Scaffold(
			appBar: AppBar(
				title: Text('Goguma'),
			),
			body: Form(
				key: formKey,
				child: Container(padding: EdgeInsets.all(10), child: Column(children: [
					TextFormField(
						keyboardType: TextInputType.url,
						decoration: InputDecoration(labelText: "Server"),
						autofocus: true,
						onEditingComplete: () => focusNode.nextFocus(),
					),
					TextFormField(
						decoration: InputDecoration(labelText: "Username"),
						onEditingComplete: () => focusNode.nextFocus(),
					),
					TextFormField(
						obscureText: true,
						decoration: InputDecoration(labelText: "Password"),
						onFieldSubmitted: (_) {
							focusNode.unfocus();
							submit();
						},
					),
					SizedBox(height: 20),
					FloatingActionButton.extended(
						onPressed: submit,
						label: Text('Connect'),
					),
				])),
			),
		);
	}
}

class BufferListPage extends StatefulWidget {
	@override
	BufferListPageState createState() => BufferListPageState();
}

class Buffer {
	String title;
	String subtitle;

	Buffer({ required this.title, required this.subtitle });
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
	List<Buffer> buffers = [
		Buffer(title: '#dri-devel', subtitle: '<ajax> nothing involved with X should ever be unable to find a bar'),
		Buffer(title: '#wayland', subtitle: 'https://wayland.freedesktop.org | Discussion about the Wayland protocol and its implementations, plus libinput'),
	];

	bool searching = false;
	TextEditingController searchController = TextEditingController();
	List<Buffer> filteredBuffers = [];

	@override
	void dispose() {
		searchController.dispose();
		super.dispose();
	}

	void search(String query) {
		query = query.toLowerCase();
		setState(() {
			filteredBuffers.clear();
			for (var buf in buffers) {
				if (buf.title.toLowerCase().contains(query) || buf.subtitle.toLowerCase().contains(query)) {
					filteredBuffers.add(buf);
				}
			}
		});
	}

	void startSearch() {
		ModalRoute.of(context)?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
			searching = false;
			filteredBuffers.clear();
			searchController.text = '';
		}));
		setState(() {
			searching = true;
		});
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

	@override
	Widget build(BuildContext context) {
		var bufs = buffers;
		if (searching) {
			bufs = filteredBuffers;
		}

		return Scaffold(
			appBar: AppBar(
				leading: searching ? CloseButton() : null,
				title: searching ? buildSearchField(context) : Text('Goguma'),
				actions: searching ? null : [
					IconButton(
						tooltip: 'Search',
						icon: const Icon(Icons.search),
						onPressed: startSearch,
					),
					PopupMenuButton<Text>(
						itemBuilder: (context) {
							return [
								PopupMenuItem(child: Text('Join')),
								PopupMenuItem(child: Text('Settings')),
							];
						},
					),
				],
			),
			body: ListView.builder(
				itemCount: bufs.length,
				itemBuilder: (context, index) {
					Buffer buf = bufs[index];
					return ListTile(
						leading: CircleAvatar(child: Text(initials(buf.title))),
						title: Text(buf.title, overflow: TextOverflow.ellipsis),
						subtitle: Text(buf.subtitle, overflow: TextOverflow.ellipsis),
						onTap: () {
							Navigator.push(context, MaterialPageRoute(builder: (context) {
								return BufferPage();
							}));
						},
					);
				},
			),
		);
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
