const RPL_WELCOME = '001';
const RPL_NOTOPIC = '331';
const RPL_TOPIC = '332';

class IRCMessage {
	IRCPrefix? prefix;
	String cmd;
	List<String> params;

	IRCMessage(this.cmd, { this.params = const [], this.prefix });

	static IRCMessage parse(String s) {
		s = s.trim();

		IRCPrefix? prefix = null;
		if (s.startsWith(':')) {
			var i = s.indexOf(' ');
			if (i < 0) {
				throw FormatException('Expected a space after prefix');
			}
			prefix = IRCPrefix.parse(s.substring(1, i));
			s = s.substring(i + 1);
		}

		String cmd;
		List<String> params = [];
		var i = s.indexOf(' ');
		if (i < 0) {
			cmd = s;
		} else {
			cmd = s.substring(0, i);
			s = s.substring(i + 1);

			while (true) {
				if (s.startsWith(':')) {
					params.add(s.substring(1));
					break;
				}

				var i = s.indexOf(' ');
				if (i < 0) {
					params.add(s);
					break;
				}

				params.add(s.substring(0, i));
				s = s.substring(i + 1);
			}
		}

		return IRCMessage(cmd.toUpperCase(), params: params, prefix: prefix);
	}

	String toString() {
		var s = '';
		if (prefix != null) {
			s += ':' + prefix!.toString() + ' ';
		}
		s += cmd;
		if (params.length > 0) {
			var last = params[params.length - 1];
			if (params.length > 1) {
				s += ' ' + params.getRange(0, params.length - 1).join(' ');
			}
			s += ' :' + last;
		}
		return s;
	}
}

class IRCPrefix {
	String name;
	String? user;
	String? host;

	IRCPrefix(this.name, { this.user, this.host });

	static IRCPrefix parse(String s) {
		var i = s.indexOf('@');
		if (i < 0) {
			return IRCPrefix(s);
		}

		var host = s.substring(i + 1);
		s = s.substring(0, i);

		i = s.indexOf('!');
		if (i < 0) {
			return IRCPrefix(s, host: host);
		}

		var name = s.substring(0, i);
		var user = s.substring(i + 1);
		return IRCPrefix(name, user: user, host: host);
	}

	String toString() {
		if (host == null) {
			return name;
		}
		if (user == null) {
			return name + '@' + host!;
		}
		return name + '!' + user! + '@' + host!;
	}
}
