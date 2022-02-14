import 'dart:collection';

// RFC 1459
const RPL_WELCOME = '001';
const RPL_YOURHOST = '002';
const RPL_CREATED = '003';
const RPL_MYINFO = '004';
const RPL_ISUPPORT = '005';
const RPL_ENDOFWHO = '315';
const RPL_NOTOPIC = '331';
const RPL_TOPIC = '332';
const RPL_TOPICWHOTIME = '333';
const RPL_WHOREPLY = '352';
const RPL_NAMREPLY = '353';
const RPL_ENDOFNAMES = '366';
const ERR_NOMOTD = '422';
const ERR_ERRONEUSNICKNAME = '432';
const ERR_NICKNAMEINUSE = '433';
const ERR_NICKCOLLISION = '436';
const ERR_NOPERMFORHOST = '463';
const ERR_PASSWDMISMATCH = '464';
const ERR_YOUREBANNEDCREEP = '465';
// RFC 2812
const ERR_UNAVAILRESOURCE = '437';
// IRCv3 SASL: https://ircv3.net/specs/extensions/sasl-3.1
const RPL_LOGGEDIN = '900';
const RPL_LOGGEDOUT = '901';
const ERR_NICKLOCKED = '902';
const RPL_SASLSUCCESS = '903';
const ERR_SASLFAIL = '904';
const ERR_SASLTOOLONG = '905';
const ERR_SASLABORTED = '906';
const ERR_SASLALREADY = '907';

class IRCMessage {
	final IRCPrefix? prefix;
	final String cmd;
	final List<String> params;

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

	bool isError() {
		switch (cmd) {
		case ERR_NICKLOCKED:
		case ERR_SASLFAIL:
		case ERR_SASLTOOLONG:
		case ERR_SASLABORTED:
		case ERR_SASLALREADY:
			return true;
		case ERR_NOMOTD:
			return false;
		default:
			return cmd.compareTo('400') >= 0 && cmd.compareTo('568') <= 0;
		}
	}
}

class IRCPrefix {
	final String name;
	final String? user;
	final String? host;

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

class IRCException implements Exception {
	final IRCMessage msg;

	IRCException(this.msg) {
		assert(msg.isError());
	}

	@override
	String toString() {
		if (msg.params.length > 0) {
			return msg.params.last;
		}
		return msg.toString();
	}
}

class IRCCapRegistry {
	Map<String, String?> _available = Map();

	UnmodifiableMapView get available => UnmodifiableMapView(_available);

	void parse(IRCMessage msg) {
		assert(msg.cmd == 'CAP');

		var subcommand = msg.params[1].toUpperCase();
		var params = msg.params.sublist(2);
		switch (subcommand) {
		case 'LS':
			_addAvailable(params[params.length - 1]);
			break;
		case 'NEW':
			_addAvailable(params[0]);
			break;
		case 'DEL':
			for (var cap in params[0].split(' ')) {
				_available.remove(cap.toLowerCase());
			}
			break;
		default:
			throw FormatException('Unknown CAP subcommand: ' + subcommand);
		}
	}

	_addAvailable(String caps) {
		for (var s in caps.split(' ')) {
			var i = s.indexOf('=');
			String k = s;
			String? v = null;
			if (i >= 0) {
				k = s.substring(0, i);
				v = s.substring(i + 1);
			}
			_available[k.toLowerCase()] = v;
		}
	}

	void clear() {
		_available.clear();
	}
}

class IRCIsupportRegistry {
	String? _network;

	String? get network => _network;

	void parse(List<String> tokens) {
		tokens.forEach((tok) {
			if (tok.startsWith('-')) {
				var k = tok.substring(1).toUpperCase();
				switch (k) {
				case "NETWORK":
					_network = null;
					break;
				}
				return;
			}

			var i = tok.indexOf('=');
			var k = tok, v = null;
			if (i >= 0) {
				k = tok.substring(0, i);
				v = tok.substring(i + 1);
				v = v.replaceAll('\\x20', '').replaceAll('\\x5C', '').replaceAll('\\x3D', '');
			}

			switch (k.toUpperCase()) {
			case "NETWORK":
				_network = v;
				break;
			}
		});
	}

	void clear() {
		_network = null;
	}
}
