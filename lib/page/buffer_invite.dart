import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../irc.dart';
import '../logging.dart';
import '../models.dart';
import 'buffer.dart';

class InvitePage extends StatefulWidget {
	static const routeName = '/buffer/invite';

	const InvitePage({ super.key });

	@override
	State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
	final TextEditingController _nameController = TextEditingController();
	String _query = '';
	Timer? _debounceNameTimer;

	bool _loading = false;
	List<WhoReply> whoReplies = [];

	@override
	void dispose() {
		_nameController.dispose();
		_debounceNameTimer?.cancel();
		super.dispose();
	}

	void _handleNameChange(String query) {
		_debounceNameTimer?.cancel();
		_debounceNameTimer = Timer(const Duration(milliseconds: 500), () {
			// Sometimes "onChanged" is called even if the query didn't
			// actually change (e.g. when the virtual keyboard is dismissed)
			if (_query == query) {
				return;
			}
			_query = query;

			_search(query);
		});
	}

	void _search(String query) async {
		var client = context.read<Client>();

		setState(() {
			whoReplies = [];
		});

		query = query.trim();
		if (query.length < 2 || validateNickname(query, client.isupport) != null) {
			return;
		}

		setState(() {
			_loading = true;
		});

		List<WhoReply> replies = [];
		try {
			replies = await client.who(query);
		} on Exception catch (err) {
			log.print('Failed to WHO user', error: err);
		}
		replies.sort();

		setState(() {
			whoReplies = replies;
			_loading = false;
		});
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: Text('Invite user'),
				bottom: PreferredSize(
					preferredSize: Size.fromHeight(70),
					child: Container(margin: EdgeInsets.all(10), child: TextField(
						controller: _nameController,
						onChanged: _handleNameChange,
						autofocus: true,
						decoration: InputDecoration(
							hintText: 'Nickname',
							filled: true,
							suffix: !_loading ? null : SizedBox(
								width: 15,
								height: 15,
								child: CircularProgressIndicator(strokeWidth: 2),
							),
						),
					)),
				),
			),
			body: ListView.builder(
				itemCount: whoReplies.length,
				itemBuilder: (context, index) {
					return _InviteItem(whoReply: whoReplies[index]);
				},
			),
		);
	}
}

class _InviteItem extends StatelessWidget {
	final WhoReply whoReply;

	const _InviteItem({ required this.whoReply });

	@override
	Widget build(BuildContext context) {
		return ListTile(
			leading: Icon(Icons.person),
			title: Text(whoReply.nickname, overflow: TextOverflow.fade),
			subtitle: isStubRealname(whoReply.realname, whoReply.nickname)
					? null
					: Text(
				whoReply.realname,
				overflow: TextOverflow.fade,
				softWrap: false,
			),
			onTap: () async {
				var buffer = context.read<BufferModel>();
				var client = context.read<Client>();
				Navigator.pop(context);
				await client.invite(buffer.name, whoReply.nickname);
				if (context.mounted) {
					ScaffoldMessenger.of(context).showSnackBar(SnackBar(
						content: Text('${whoReply.nickname} was invited to ${buffer.name}.'),
					));
				}
			},
		);
	}
}
