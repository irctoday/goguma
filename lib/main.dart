import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'buffer-list-page.dart';
import 'client.dart';
import 'client-controller.dart';
import 'connect-page.dart';
import 'irc.dart';
import 'models.dart';

void main() {
	var bufferList = BufferListModel();
	runApp(MultiProvider(
		providers: [
			Provider<ClientController>.value(value: ClientController(bufferList)),
			ChangeNotifierProvider<BufferListModel>.value(value: bufferList),
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
	bool initing = true;
	bool loading = false;
	Exception? error = null;

	@override
	void initState() {
		super.initState();

		SharedPreferences.getInstance().then((prefs) {
			if (!prefs.containsKey('server.host')) {
				return;
			}

			context.read<ClientController>().connect(ConnectParams(
				host: prefs.getString('server.host')!,
				port: prefs.getInt('server.port')!,
				tls: prefs.getBool('server.tls')!,
				nick: prefs.getString('server.nick')!,
				pass: prefs.getString('server.pass'),
			));

			Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
				return BufferListPage();
			}));
		}).whenComplete(() {
			setState(() {
				initing = false;
			});
		});
	}

	@override
	Widget build(BuildContext context) {
		if (initing) {
			return Container();
		}

		return ConnectPage(loading: loading, error: error, onSubmit: (params) {
			setState(() {
				loading = true;
			});

			context.read<ClientController>().connect(params).then((_) {
				SharedPreferences.getInstance().then((prefs) {
					// TODO: save credentials in keyring instead
					prefs.setString('server.host', params.host);
					prefs.setInt('server.port', params.port);
					prefs.setBool('server.tls', params.tls);
					prefs.setString('server.nick', params.nick);
					if (params.pass != null) {
						prefs.setString('server.pass', params.pass!);
					} else {
						prefs.remove('server.pass');
					}
				});

				Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) {
					return BufferListPage();
				}));
			}).catchError((err) {
				setState(() {
					error = err;
				});
			}).whenComplete(() {
				setState(() {
					loading = false;
				});
			});
		});
	}
}
