import 'dart:collection';
import 'dart:core';

// RFC 1459
const RPL_WELCOME = '001';
const RPL_YOURHOST = '002';
const RPL_CREATED = '003';
const RPL_MYINFO = '004';
const RPL_ISUPPORT = '005';
const RPL_TRYAGAIN = '263';
const RPL_WHOISCERTFP = '276';
const RPL_WHOISREGNICK = '307';
const RPL_WHOISUSER = '311';
const RPL_WHOISSERVER = '312';
const RPL_WHOISOPERATOR = '313';
const RPL_ENDOFWHO = '315';
const RPL_WHOISIDLE = '317';
const RPL_ENDOFWHOIS = '318';
const RPL_WHOISCHANNELS = '319';
const RPL_WHOISSPECIAL = '320';
const RPL_WHOISACCOUNT = '330';
const RPL_NOTOPIC = '331';
const RPL_TOPIC = '332';
const RPL_TOPICWHOTIME = '333';
const RPL_WHOISACTUALLY = '338';
const RPL_WHOREPLY = '352';
const RPL_NAMREPLY = '353';
const RPL_ENDOFNAMES = '366';
const RPL_ENDOFMOTD = '376';
const RPL_WHOISHOST = '378';
const RPL_WHOISMODES = '379';
const ERR_UNKNOWNERROR = '400';
const ERR_NOSUCHNICK = '401';
const ERR_UNKNOWNCOMMAND = '421';
const ERR_NOMOTD = '422';
const ERR_ERRONEUSNICKNAME = '432';
const ERR_NICKNAMEINUSE = '433';
const ERR_NICKCOLLISION = '436';
const ERR_NEEDMOREPARAMS = '461';
const ERR_NOPERMFORHOST = '463';
const ERR_PASSWDMISMATCH = '464';
const ERR_YOUREBANNEDCREEP = '465';
const RPL_WHOISSECURE = '671';
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
// IRCv3 MONITOR: https://ircv3.net/specs/extensions/monitor
const RPL_MONONLINE = '730';
const RPL_MONOFFLINE = '731';
const ERR_MONLISTFULL = '734';

String formatIrcTime(DateTime dt) {
	dt = dt.toUtc();
	// toIso8601String omits the microseconds if zero
	return DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.millisecond).toIso8601String();
}

class IrcMessage {
	final UnmodifiableMapView<String, String?> tags;
	final IrcSource? source;
	final String cmd;
	final UnmodifiableListView<String> params;

	IrcMessage(this.cmd, List<String> params, { Map<String, String?> tags = const {}, this.source }) :
		this.tags = UnmodifiableMapView(tags),
		this.params = UnmodifiableListView(params);

	static IrcMessage parse(String s) {
		s = s.trim();

		Map<String, String?> tags;
		if (s.startsWith('@')) {
			var i = s.indexOf(' ');
			if (i < 0) {
				throw FormatException('Expected a space after tags');
			}
			tags = parseIrcTags(s.substring(1, i));
			s = s.substring(i + 1);
		} else {
			tags = const {};
		}

		IrcSource? source = null;
		if (s.startsWith(':')) {
			var i = s.indexOf(' ');
			if (i < 0) {
				throw FormatException('Expected a space after source');
			}
			source = IrcSource.parse(s.substring(1, i));
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

		return IrcMessage(cmd.toUpperCase(), params, tags: tags, source: source);
	}

	String toString() {
		var s = '';
		if (tags.length > 0) {
			s += '@' + formatIrcTags(tags) + ' ';
		}
		if (source != null) {
			s += ':' + source!.toString() + ' ';
		}
		s += cmd;
		if (params.length > 0) {
			if (params.length > 1) {
				s += ' ' + params.getRange(0, params.length - 1).join(' ');
			}

			if (params.last.length == 0 || params.last.startsWith(':') || params.last.indexOf(' ') >= 0) {
				s += ' :' + params.last;
			} else {
				s += ' ' + params.last;
			}
		}
		return s;
	}

	bool isError() {
		switch (cmd) {
		case 'ERROR':
		case 'FAIL':
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

Map<String, String?> parseIrcTags(String s) {
	return Map.fromEntries(s.split(';').map((s) {
		if (s.length == 0) {
			throw FormatException('Empty tag entries are invalid');
		}

		String k = s;
		String? v;
		var i = s.indexOf('=');
		if (i >= 0) {
			k = s.substring(0, i);
			v = _unescapeTag(s.substring(i + 1));
		}

		return MapEntry(k, v);
	}));
}

String formatIrcTags(Map<String, String?> tags) {
	return tags.entries.map((entry) {
		if (entry.value == null) {
			return entry.key;
		}
		return entry.key + '=' + _escapeTag(entry.value!);
	}).join(';');
}

String _escapeTag(String s) {
	return s.split('').map((ch) {
		switch (ch) {
		case ';':
			return '\\:';
		case ' ':
			return '\\s';
		case '\\':
			return '\\\\';
		case '\r':
			return '\\r';
		case '\n':
			return '\\n';
		default:
			return ch;
		}
	}).join('');
}

final _unescapeTagRegExp = RegExp(r'\\.');

String _unescapeTag(String s) {
	return s.replaceAllMapped(_unescapeTagRegExp, (match) {
		switch (match.input) {
		case '\\:':
			return ';';
		case '\\s':
			return ' ';
		case '\\\\':
			return '\\';
		case '\\r':
			return '\r';
		case '\\n':
			return '\\n';
		default:
			return match.input[1];
		}
	});
}

class IrcSource {
	final String name;
	final String? user;
	final String? host;

	IrcSource(this.name, { this.user, this.host });

	static IrcSource parse(String s) {
		var i = s.indexOf('@');
		if (i < 0) {
			return IrcSource(s);
		}

		var host = s.substring(i + 1);
		s = s.substring(0, i);

		i = s.indexOf('!');
		if (i < 0) {
			return IrcSource(s, host: host);
		}

		var name = s.substring(0, i);
		var user = s.substring(i + 1);
		return IrcSource(name, user: user, host: host);
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

class IrcException implements Exception {
	final IrcMessage msg;

	IrcException(this.msg) {
		assert(msg.isError() || msg.cmd == RPL_TRYAGAIN);
	}

	@override
	String toString() {
		if (msg.params.length > 0) {
			return msg.params.last;
		}
		return msg.toString();
	}
}

class IrcCapRegistry {
	Map<String, String?> _available = Map();
	Set<String> _enabled = Set();

	UnmodifiableMapView<String, String?> get available => UnmodifiableMapView(_available);
	UnmodifiableSetView<String> get enabled => UnmodifiableSetView(_enabled);

	void parse(IrcMessage msg) {
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
				cap = cap.toLowerCase();
				_available.remove(cap);
				_enabled.remove(cap);
			}
			break;
		case 'ACK':
			for (var cap in params[0].split(' ')) {
				cap = cap.toLowerCase();
				if (cap.startsWith('-')) {
					_enabled.remove(cap.substring(1));
				} else {
					_enabled.add(cap);
				}
			}
			break;
		case 'NAK':
			break; // nothing to do
		default:
			throw FormatException('Unknown CAP subcommand: ' + subcommand);
		}
	}

	void _addAvailable(String caps) {
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

	int? get chatHistory {
		if (!available.containsKey('draft/chathistory')) {
			return null;
		}
		var v = available['draft/chathistory'] ?? '0';
		return int.parse(v);
	}
}

final defaultCaseMapping = _caseMappingByName('rfc1459')!;

class IrcIsupportRegistry {
	String? _network;
	CaseMapping? _caseMapping;
	String? _chanTypes;
	String? _bouncerNetId;
	final List<IrcIsupportMembership> _memberships = [];
	int? _monitor;

	String? get network => _network;
	String get chanTypes => _chanTypes ?? '';
	CaseMapping get caseMapping => _caseMapping ?? defaultCaseMapping;
	String? get bouncerNetId => _bouncerNetId;
	UnmodifiableListView<IrcIsupportMembership> get memberships => UnmodifiableListView(_memberships);
	int? get monitor => _monitor;

	void parse(List<String> tokens) {
		tokens.forEach((tok) {
			if (tok.startsWith('-')) {
				var k = tok.substring(1).toUpperCase();
				switch (k) {
				case 'BOUNCER_NETID':
					_bouncerNetId = null;
					break;
				case 'NETWORK':
					_network = null;
					break;
				case 'CASEMAPPING':
					_caseMapping = null;
					break;
				case 'CHANTYPES':
					_chanTypes = null;
					break;
				case 'MONITOR':
					_monitor = null;
					break;
				case 'PREFIX':
					_memberships.clear();
					break;
				}
				return;
			}

			var i = tok.indexOf('=');
			var k = tok;
			String? v;
			if (i >= 0) {
				k = tok.substring(0, i);
				v = tok.substring(i + 1);
				v = v.replaceAll('\\x20', '').replaceAll('\\x5C', '').replaceAll('\\x3D', '');
			}

			switch (k.toUpperCase()) {
			case 'BOUNCER_NETID':
				_bouncerNetId = v;
				break;
			case 'NETWORK':
				_network = v;
				break;
			case 'CASEMAPPING':
				_caseMapping = _caseMappingByName(v ?? '');
				break;
			case 'CHANTYPES':
				_chanTypes = v ?? '';
				break;
			case 'MONITOR':
				_monitor = int.parse(v ?? '0');
				break;
			case 'PREFIX':
				_memberships.clear();
				if (v == null || v == '') {
					break;
				}
				var i = v.indexOf(')');
				if (!v.startsWith('(') || i < 0) {
					throw FormatException('Malformed ISUPPORT PREFIX value (expected parentheses): $v');
				}
				var modes = v.substring(1, i);
				var prefixes = v.substring(i + 1);
				if (modes.length != prefixes.length) {
					throw FormatException('Malformed ISUPPORT PREFIX value (modes and prefixes count mismatch): $v');
				}
				for (var i = 0; i < modes.length; i++) {
					_memberships.add(IrcIsupportMembership(modes[i], prefixes[i]));
				}
				break;
			}
		});
	}

	void clear() {
		_network = null;
		_caseMapping = null;
		_chanTypes = null;
		_bouncerNetId = null;
		_memberships.clear();
		_monitor = null;
	}
}

class IrcIsupportMembership {
	final String mode;
	final String prefix;

	IrcIsupportMembership(this.mode, this.prefix);
}

typedef String CaseMapping(String s);

CaseMapping? _caseMappingByName(String s) {
	CaseMapping caseMapChar;
	switch (s) {
	case 'ascii':
		caseMapChar = _caseMapCharAscii;
		break;
	case 'rfc1459':
		caseMapChar = _caseMapCharRfc1459;
		break;
	case 'rfc1459-strict':
		caseMapChar = _caseMapCharRfc1459Strict;
		break;
	default:
		return null;
	}
	return (String s) => s.split('').map(caseMapChar).join('');
}

String _caseMapCharRfc1459(String ch) {
	if (ch == '~') {
		return '^';
	}
	return _caseMapCharRfc1459Strict(ch);
}

String _caseMapCharRfc1459Strict(String ch) {
	switch (ch) {
	case '{':
		return '[';
	case '}':
		return ']';
	case '\\':
		return '|';
	default:
		return _caseMapCharAscii(ch);
	}
}

String _caseMapCharAscii(String ch) {
	if ('A'.codeUnits.first <= ch.codeUnits.first && ch.codeUnits.first <= 'Z'.codeUnits.first) {
		return ch.toLowerCase();
	}
	return ch;
}

class IrcNameMap<V> extends MapBase<String, V> {
	CaseMapping _cm;
	Map<String, _IrcNameMapEntry<V>> _m = Map();

	IrcNameMap(CaseMapping cm) : _cm = cm;

	V? operator [](Object? key) {
		return _m[_cm(key as String)]?.value;
	}

	void operator []=(String key, V value) {
		_m[_cm(key)] = _IrcNameMapEntry(key, value);
	}

	void clear() {
		_m.clear();
	}

	Iterable<String> get keys {
		return _m.values.map((entry) => entry.name);
	}

	V? remove(Object? key) {
		return _m.remove(_cm(key as String))?.value;
	}

	void setCaseMapping(CaseMapping cm) {
		_m = Map.fromIterables(_m.values.map((entry) => cm(entry.name)), _m.values);
		_cm = cm;
	}
}

class _IrcNameMapEntry<V> {
	final String name;
	final V value;

	_IrcNameMapEntry(this.name, this.value);
}

/// A CTCP message as defined in:
/// https://rawgit.com/DanielOaks/irc-rfcs/master/dist/draft-oakley-irc-ctcp-latest.html
class CtcpMessage {
	final String cmd;
	final String? param;

	CtcpMessage(String cmd, [ this.param ]) :
		this.cmd = cmd.toUpperCase();

	static CtcpMessage? parse(IrcMessage msg) {
		if (msg.cmd != 'PRIVMSG' && msg.cmd != 'NOTICE') {
			return null;
		}

		var s = msg.params[1];
		if (!s.startsWith('\x01')) {
			return null;
		}
		s = s.substring(1);
		if (s.endsWith('\x01')) {
			s = s.substring(0, s.length - 1);
		}

		var i = s.indexOf(' ');
		if (i >= 0) {
			return CtcpMessage(s.substring(0, i), s.substring(i + 1));
		} else {
			return CtcpMessage(s);
		}
	}
}

/// Strip ANSI formatting as defined in:
/// https://modern.ircdocs.horse/formatting.html
String stripAnsiFormatting(String s) {
	var out = '';
	for (var i = 0; i < s.length; i++) {
		var ch = s[i];
		switch (ch) {
		case '\x02': // bold
		case '\x1D': // italic
		case '\x1F': // underline
		case '\x1E': // strike-through
		case '\x11': // monospace
		case '\x16': // reverse color
		case '\x0F': // reset
			break; // skip
		case '\x03': // color
			if (i + 1 >= s.length || !_isDigit(s[i + 1])) {
				break;
			}
			i++;
			if (i + 1 < s.length && _isDigit(s[i + 1])) {
				i++;
			}
			if (i + 2 < s.length && s[i + 1] == ',' && _isDigit(s[i + 2])) {
				i += 2;
				if (i + 1 < s.length && _isDigit(s[i + 1])) {
					i++;
				}
			}
			break;
		case '\x04': // hex color
			i += 6;
			break;
		default:
			out += ch;
		}
	}
	return out;
}

bool _isDigit(String ch) {
	return '0'.codeUnits.first <= ch.codeUnits.first && ch.codeUnits.first <= '9'.codeUnits.first;
}

final _alphaNumRegExp = RegExp(r'^[\p{L}0-9]$', unicode: true);

bool _isWordBoundary(String ch) {
	switch (ch) {
	case '-':
	case '_':
	case '|':
		return false;
	default:
		return !_alphaNumRegExp.hasMatch(ch);
	}
}

bool findTextHighlight(String text, String nick) {
	nick = nick.toLowerCase();
	text = text.toLowerCase();

	while (true) {
		var i = text.indexOf(nick);
		if (i < 0) {
			return false;
		}

		// TODO: proper unicode handling
		var left = '\x00';
		var right = '\x00';
		if (i > 0) {
			left = text[i - 1];
		}
		if (i + nick.length < text.length) {
			right = text[i + nick.length];
		}
		if (_isWordBoundary(left) && _isWordBoundary(right)) {
			return true;
		}

		text = text.substring(i + nick.length);
	}
}

class Whois {
	final String nickname;
	final bool loggedIn;
	final IrcSource? source;
	final String? realname;
	final String? server;
	final bool op;
	final Map<String, String> channels;
	final String? account;
	final bool secureConnection;

	Whois({
		required this.nickname,
		this.loggedIn = false,
		this.source,
		this.realname,
		this.server,
		this.op = false,
		this.channels = const {},
		this.account,
		this.secureConnection = false,
	});

	factory Whois.parse(String nickname, List<IrcMessage> replies, String prefixes) {
		var loggedIn = false;
		IrcSource? source;
		String? realname;
		String? server;
		bool op = false;
		Map<String, String> channels = {};
		String? account;
		bool secureConnection = false;

		for (var msg in replies) {
			switch (msg.cmd) {
			case RPL_WHOISREGNICK:
				loggedIn = true;
				break;
			case RPL_WHOISUSER:
				source = IrcSource(nickname, user: msg.params[2], host: msg.params[3]);
				realname = msg.params[5];
				break;
			case RPL_WHOISSERVER:
				server = msg.params[2];
				break;
			case RPL_WHOISOPERATOR:
				op = true;
				break;
			case RPL_WHOISCHANNELS:
				for (var raw in msg.params[2].split(' ')) {
					if (raw == '') {
						continue;
					}
					var i = 0;
					while (i < raw.length && prefixes.contains(raw[i])) {
						i++;
					}
					var prefix = raw.substring(0, i);
					var channel = raw.substring(i);
					channels[channel] = prefix;
				}
				break;
			case RPL_WHOISACCOUNT:
				account = msg.params[2];
				break;
			case RPL_WHOISSECURE:
				secureConnection = true;
				break;
			case RPL_WHOISCERTFP:
			case RPL_WHOISIDLE:
			case RPL_WHOISSPECIAL:
			case RPL_WHOISACTUALLY:
			case RPL_WHOISHOST:
			case RPL_WHOISMODES:
				break; // not yet implemented
			case RPL_ENDOFWHOIS:
				break;
			default:
				throw Exception('Not a WHOIS reply: ${msg.cmd}');
			}
		}

		return Whois(
			nickname: nickname,
			loggedIn: loggedIn,
			source: source,
			realname: realname,
			server: server,
			op: op,
			channels: channels,
			account: account,
			secureConnection: secureConnection,
		);
	}
}

class WhoReply {
	final String nickname;
	final bool away;
	final bool op;
	final String realname;

	WhoReply({
		required this.nickname,
		this.away = false,
		this.op = false,
		required this.realname,
	});

	factory WhoReply.parse(IrcMessage msg) {
		if (msg.cmd != RPL_WHOREPLY) {
			throw Exception('Not a WHO reply: ${msg.cmd}');
		}

		var nickname = msg.params[5];
		var flags = msg.params[6];
		var trailing = msg.params[7];

		var away = flags.indexOf('G') >= 0;
		var op = flags.indexOf('*') >= 0;

		var i = trailing.indexOf(' ');
		if (i < 0) {
			throw FormatException('RPL_WHOREPLY trailing parameter must contain a space');
		}
		var realname = trailing.substring(i + 1);

		return WhoReply(
			nickname: nickname,
			away: away,
			op: op,
			realname: realname,
		);
	}
}
