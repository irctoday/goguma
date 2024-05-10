import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
import 'models.dart';

typedef Command = String? Function(BuildContext context, String? param);

class CommandException implements Exception {
	final String message;
	const CommandException(this.message);
}

String _requireParam(String? param) {
	if (param == null) {
		throw CommandException('This command requires a parameter');
	}
	return param;
}

String? _join(BuildContext context, String? param) {
	var client = context.read<Client>();
	client.join([_requireParam(param)]);
	return null;
}

String? _kick(BuildContext context, String? param) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	if (!client.isChannel(buffer.name)) {
		throw CommandException('This command can only be used in channels');
	}
	var parts = _requireParam(param).split(' ');
	var nick = parts[0];
	var reason = parts.length > 1 ? [parts.sublist(1).join(' ')] : <String>[];
	client.send(IrcMessage('KICK', [buffer.name, nick, ...reason]));
	return null;
}

String? _me(BuildContext context, String? param) {
	return CtcpMessage('ACTION', param).format();
}

String? _mode(BuildContext context, String? param) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	if (!client.isChannel(buffer.name)) {
		throw CommandException('This command can only be used in channels');
	}
	client.send(IrcMessage('MODE', [buffer.name, ..._requireParam(param).split(' ')]));
	return null;
}

String? _part(BuildContext context, String? param) {
	var client = context.read<Client>();
	var bufferList = context.read<BufferListModel>();
	var buffer = context.read<BufferModel>();
	var db = context.read<DB>();
	if (!client.isChannel(buffer.name)) {
		throw CommandException('This command can only be used in channels');
	}
	if (param != null) {
		client.send(IrcMessage('PART', [buffer.name, param]));
	} else {
		client.send(IrcMessage('PART', [buffer.name]));
	}
	bufferList.setArchived(buffer, true);
	db.storeBuffer(buffer.entry);
	return null;
}

String? _quote(BuildContext context, String? param) {
	var client = context.read<Client>();
	IrcMessage msg;
	try {
		msg = IrcMessage.parse(_requireParam(param));
	} on FormatException {
		throw CommandException('Invalid IRC command');
	}
	client.send(msg);
	return null;
}

const Map<String, Command> commands = {
	'join': _join,
	'kick': _kick,
	'me': _me,
	'mode': _mode,
	'part': _part,
	'quote': _quote,
};
