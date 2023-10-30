import 'irc.dart';

typedef Command = String? Function(String? param);

String? _me(String? param) {
	return CtcpMessage('ACTION', param).format();
}

const Map<String, Command> commands = {
	'me': _me,
};
