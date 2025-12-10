import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../ansi.dart';
import '../client.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import 'buffer.dart';
import 'buffer_list.dart';

class SearchPage extends StatefulWidget {
	static const routeName = '/search';

	const SearchPage({ super.key });

	@override
	State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _query = '';
  bool _loading = false;
  Timer? _debounceTimer;
  final TextEditingController _searchController = TextEditingController();
  List<MessageEntry> _results = [];

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _handleChange(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      // Sometimes "onChanged" is called even if the query didn't
      // actually change (e.g. when the virtual keyboard is dismissed)
      if (_query == query) {
        return;
      }
      _query = query;
      await _search(context, query);
    });
  }

	@override
	Widget build(BuildContext context) {
		return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search...',
            border: InputBorder.none,
          ),
          onChanged: _handleChange,
        ),
        actions: _loading ? [SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2),
        ), SizedBox(width: 20)] : null,
      ),
			body: ScrollablePositionedList.builder(
        itemCount: _results.length,
        itemBuilder: (context, index) {
          return SearchMessageItem(
            msg: _results[index],
          );
        },
      ),
		);
	}

  Future<void> _search(BuildContext context, String query) async {
    setState(() {
      _loading = true;
    });

    var buffer = context.read<BufferModel>();
    var client = context.read<Client>();
    
    var batch = await client.search(buffer.name, query);
    List<MessageEntry> privmsgs = [];
    for (var msg in batch.messages) {
      if (msg.cmd != 'PRIVMSG') {
        continue;
      }
      var ctcp = CtcpMessage.parse(msg);
      if (ctcp != null && ctcp.cmd != 'ACTION') {
        continue;
      }
      if (msg.tags['+draft/react'] != null) {
        continue;
      }
      privmsgs.add(MessageEntry(msg, buffer.id));
    }
    privmsgs.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    setState(() {
      _loading = false;
      _results = privmsgs;
    });
  }
}

class SearchMessageItem extends StatelessWidget {
  final MessageEntry msg;

  const SearchMessageItem({
    super.key,
    required this.msg,
  });

  @override
  Widget build(BuildContext context) {
    var client = context.read<Client>();

    var ircMsg = msg.msg;
    var entry = msg;
    var sender = ircMsg.source!.name;
    var localDateTime = entry.dateTime.toLocal();
    var isFromMe = client.isMyNick(sender);

    var body = ircMsg.params[1];

    var colorScheme = Theme.of(context).colorScheme;

    var textColor =  colorScheme.onSurface;
    var senderNickColor = _getNickColor(sender, colorScheme.brightness);

    if (isFromMe) {
      textColor = colorScheme.onPrimaryContainer;
      senderNickColor = textColor;
    }

    var yyyy = localDateTime.year.toString().padLeft(4, '0');
    var mm = localDateTime.month.toString().padLeft(2, '0');
    var dd = localDateTime.day.toString().padLeft(2, '0');
    var hh = localDateTime.hour.toString().padLeft(2, '0');
    var mn = localDateTime.minute.toString().padLeft(2, '0');
    var time = '$yyyy-$mm-$dd $hh:$mn';
    var timeStyle = DefaultTextStyle.of(context).style.apply(
      color: textColor.withValues(alpha: 0.5),
      fontSizeFactor: 0.8,
    );

    return ListTile(
      title: Text(
        sender,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: senderNickColor,
        ),
      ),
      subtitle: Text(stripAnsiFormatting(body), overflow: TextOverflow.ellipsis),
      trailing: Text(
        time,
        style: timeStyle,
      ),
      onTap: () {
        // TODO push buffer instead of replacing
        var buffer = context.read<BufferModel>();
        var navigatorState = Navigator.of(context);
        var until = ModalRoute.withName(BufferListPage.routeName);
        var args = BufferPageArguments(buffer: buffer);
        navigatorState.pushNamedAndRemoveUntil(BufferPage.routeName, until, arguments: args);
      },
    );
  }
}

// _getNickColor returns a color for the given nickname. The same nickname will always get the same color. The color is chosen from the primary colors of the current theme. The brightness parameter is used to choose a lighter or darker shade of the color.
Color _getNickColor(String nickname, Brightness brightness) {
  var colorSwatch = Colors.primaries[nickname.hashCode % Colors.primaries.length];
  return brightness == Brightness.dark ? colorSwatch.shade400 : colorSwatch.shade800;
}
