import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:share_handler/share_handler.dart';

import '../ansi.dart';
import '../models.dart';
import 'buffer.dart';
import 'buffer_list.dart';

class SharePage extends StatefulWidget {
	static const routeName = '/share';

	final SharedMedia sharedMedia;

	const SharePage({ super.key, required this.sharedMedia });

	@override
	State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
	final _listKey = GlobalKey();

	@override
	Widget build(BuildContext context) {
		List<BufferModel> buffers = context.watch<BufferListModel>().buffers;

		Map<String, int> bufferNames = {};
		for (var buffer in buffers) {
			bufferNames.update(buffer.name.toLowerCase(), (n) => n + 1, ifAbsent: () => 1);
		}

		return Scaffold(
			appBar: AppBar(
				leading: CloseButton(
					onPressed: () async {
						var handled = await Navigator.maybePop(context);
						if (!handled) {
							await SystemNavigator.pop();
						}
					},
				),
				title: Text('Share'),
			),
			body: ListView.builder(
				key: _listKey,
				itemCount: buffers.length,
				itemBuilder: (context, index) {
					var buffer = buffers[index];
					return _BufferItem(
						buffer: buffer,
						sharedMedia: widget.sharedMedia,
						showNetworkName: bufferNames[buffer.name.toLowerCase()]! > 1,
					);
				},
			),
		);
	}
}

class _BufferItem extends AnimatedWidget {
	final BufferModel buffer;
	final SharedMedia sharedMedia;
	final bool showNetworkName;

	const _BufferItem({
		required this.buffer,
		required this.sharedMedia,
		this.showNetworkName = false,
	}) : super(listenable: buffer);

	@override
	Widget build(BuildContext context) {
		var subtitle = buffer.topic ?? buffer.realname;

		Widget title;
		if (showNetworkName) {
			title = Text.rich(
				TextSpan(children: [
					TextSpan(text: buffer.name),
					TextSpan(
						text: ' on ${buffer.network.displayName}',
						style: TextStyle(color: Theme.of(context).textTheme.bodySmall!.color),
					),
				]),
				overflow: TextOverflow.fade,
			);
		} else {
			title = Text(buffer.name, overflow: TextOverflow.ellipsis);
		}

		// extracted from the ListTile sourceIconData
		var theme = Theme.of(context);
		var dense = theme.listTileTheme.dense ?? false;
		var height = (dense ? 64.0 : 72.0) + theme.visualDensity.baseSizeAdjustment.dy;

		return Container(alignment: Alignment.center, height: height, child: ListTile(
			leading: CircleAvatar(
				child: Text(
					_initials(buffer.name),
					semanticsLabel: ''
				),
			),
			title: title,
			subtitle: subtitle == null ? null : Text(
				stripAnsiFormatting(subtitle),
				overflow: TextOverflow.fade,
				softWrap: false,
			),
			onTap: () {
				var navigatorState = Navigator.of(context);
				navigatorState.pushNamedAndRemoveUntil(BufferListPage.routeName, (route) => false);
				var args = BufferPageArguments(buffer: buffer, sharedMedia: sharedMedia);
				navigatorState.pushNamed(BufferPage.routeName, arguments: args);
			},
		));
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
