import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'irc.dart';

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

String? _me(BuildContext context, String? param) {
	return CtcpMessage('ACTION', param).format();
}

const Map<String, Command> commands = {
	'me': _me,
	'join': _join,
};
