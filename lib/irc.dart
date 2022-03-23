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
const RPL_CHANNELMODEIS = '324';
const RPL_WHOISACCOUNT = '330';
const RPL_NOTOPIC = '331';
const RPL_TOPIC = '332';
const RPL_TOPICWHOTIME = '333';
const RPL_WHOISBOT = '335';
const RPL_WHOISACTUALLY = '338';
const RPL_WHOREPLY = '352';
const RPL_NAMREPLY = '353';
const RPL_WHOSPCRPL = '354';
const RPL_ENDOFNAMES = '366';
const RPL_ENDOFMOTD = '376';
const RPL_WHOISHOST = '378';
const RPL_WHOISMODES = '379';
const ERR_UNKNOWNERROR = '400';
const ERR_NOSUCHNICK = '401';
const ERR_NOSUCHCHANNEL = '403';
const ERR_TOOMANYCHANNELS = '405';
const ERR_UNKNOWNCOMMAND = '421';
const ERR_NOMOTD = '422';
const ERR_ERRONEUSNICKNAME = '432';
const ERR_NICKNAMEINUSE = '433';
const ERR_NOTONCHANNEL = '442';
const ERR_NICKCOLLISION = '436';
const ERR_NEEDMOREPARAMS = '461';
const ERR_NOPERMFORHOST = '463';
const ERR_PASSWDMISMATCH = '464';
const ERR_YOUREBANNEDCREEP = '465';
const ERR_CHANNELISFULL = '471';
const ERR_INVITEONLYCHAN = '473';
const ERR_BANNEDFROMCHAN = '474';
const ERR_BADCHANNELKEY = '475';
const ERR_CHANOPRIVSNEEDED = '482';
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
		while (s.endsWith('\n') || s.endsWith('\r')) {
			s = s.substring(0, s.length - 1);
		}

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

		IrcSource? source;
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

	@override
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

			if (params.last.length == 0 || params.last.startsWith(':') || params.last.contains(' ')) {
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

	const IrcSource(this.name, { this.user, this.host });

	static IrcSource parse(String s) {
		String? user, host;

		var i = s.indexOf('@');
		if (i >= 0) {
			host = s.substring(i + 1);
			s = s.substring(0, i);
		}

		i = s.indexOf('!');
		if (i >= 0) {
			user = s.substring(i + 1);
			s = s.substring(0, i);
		}

		return IrcSource(s, user: user, host: host);
	}

	@override
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
	final Map<String, String?> _available = {};
	final Set<String> _enabled = {};

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
			String? v;
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
	String? _botMode;
	bool _whox = false;
	int? _topicLen;
	List<String>? _chanModes;
	IrcIsupportElist? _elist;

	String? get network => _network;
	String get chanTypes => _chanTypes ?? '';
	CaseMapping get caseMapping => _caseMapping ?? defaultCaseMapping;
	String? get bouncerNetId => _bouncerNetId;
	UnmodifiableListView<IrcIsupportMembership> get memberships => UnmodifiableListView(_memberships);
	int? get monitor => _monitor;
	String? get botMode => _botMode;
	bool get whox => _whox;
	int? get topicLen => _topicLen;
	List<String> get chanModes => UnmodifiableListView(_chanModes ?? ['beI', 'k', 'l', 'imnst']);
	IrcIsupportElist? get elist => _elist;

	void parse(List<String> tokens) {
		for (var tok in tokens) {
			if (tok.startsWith('-')) {
				var k = tok.substring(1).toUpperCase();
				switch (k) {
				case 'BOUNCER_NETID':
					_bouncerNetId = null;
					break;
				case 'BOT':
					_botMode = null;
					break;
				case 'CASEMAPPING':
					_caseMapping = null;
					break;
				case 'CHANMODES':
					_chanModes = null;
					break;
				case 'CHANTYPES':
					_chanTypes = null;
					break;
				case 'ELIST':
					_elist = null;
					break;
				case 'MONITOR':
					_monitor = null;
					break;
				case 'NETWORK':
					_network = null;
					break;
				case 'PREFIX':
					_memberships.clear();
					break;
				case 'TOPIC':
					_topicLen = null;
					break;
				case 'WHOX':
					_whox = false;
					break;
				}
				continue;
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
			case 'BOT':
				_botMode = v;
				break;
			case 'CASEMAPPING':
				_caseMapping = _caseMappingByName(v ?? '');
				break;
			case 'CHANMODES':
				var l = (v ?? '').split(',');
				if (l.length < 4) {
					throw FormatException('Malformed ISUPPORT CHANMODES value: $v');
				}
				_chanModes = l;
				break;
			case 'CHANTYPES':
				_chanTypes = v ?? '';
				break;
			case 'ELIST':
				_elist = IrcIsupportElist.parse(v ?? '');
				break;
			case 'MONITOR':
				_monitor = int.parse(v ?? '0');
				break;
			case 'NETWORK':
				_network = v;
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
			case 'TOPICLEN':
				if (v == null) {
					throw FormatException('Malformed ISUPPORT TOPICLEN: no value');
				}
				_topicLen = int.parse(v);
				break;
			case 'WHOX':
				_whox = true;
				break;
			}
		}
	}

	void clear() {
		_network = null;
		_caseMapping = null;
		_chanTypes = null;
		_bouncerNetId = null;
		_memberships.clear();
		_monitor = null;
		_botMode = null;
		_whox = false;
		_topicLen = null;
		_elist = null;
	}
}

class IrcIsupportMembership {
	final String mode;
	final String prefix;

	const IrcIsupportMembership(this.mode, this.prefix);

	static const founder = IrcIsupportMembership('q', '~');
	static const protected = IrcIsupportMembership('a', '&');
	static const op = IrcIsupportMembership('o', '@');
	static const halfop = IrcIsupportMembership('h', '%');
	static const voice = IrcIsupportMembership('v', '+');
}

class IrcIsupportElist {
	final bool creationTime;
	final bool mask;
	final bool negativeMask;
	final bool topicTime;
	final bool userCount;

	const IrcIsupportElist({
		this.creationTime = false,
		this.mask = false,
		this.negativeMask = false,
		this.topicTime = false,
		this.userCount = false,
	});

	factory IrcIsupportElist.parse(String str) {
		str = str.toUpperCase();
		return IrcIsupportElist(
			creationTime: str.contains('C'),
			mask: str.contains('M'),
			negativeMask: str.contains('N'),
			topicTime: str.contains('T'),
			userCount: str.contains('U'),
		);
	}
}

typedef CaseMapping = String Function(String s);

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
	Map<String, _IrcNameMapEntry<V>> _m = {};

	IrcNameMap(CaseMapping cm) : _cm = cm;

	@override
	V? operator [](Object? key) {
		return _m[_cm(key as String)]?.value;
	}

	@override
	void operator []=(String key, V value) {
		_m[_cm(key)] = _IrcNameMapEntry(key, value);
	}

	@override
	void clear() {
		_m.clear();
	}

	@override
	Iterable<String> get keys {
		return _m.values.map((entry) => entry.name);
	}

	@override
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
	final bool bot;

	const Whois({
		required this.nickname,
		this.loggedIn = false,
		this.source,
		this.realname,
		this.server,
		this.op = false,
		this.channels = const {},
		this.account,
		this.secureConnection = false,
		this.bot = false,
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
		bool bot = false;

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
			case RPL_WHOISBOT:
				bot = true;
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
			bot: bot,
		);
	}
}

class WhoReply {
	final String nickname;
	final bool away;
	final bool op;
	final String realname;
	final String? channel;
	final String? membershipPrefix;
	final String? account;

	const WhoReply({
		required this.nickname,
		this.away = false,
		this.op = false,
		required this.realname,
		this.channel,
		this.membershipPrefix,
		this.account,
	});

	factory WhoReply.parse(IrcMessage msg, IrcIsupportRegistry isupport) {
		if (msg.cmd != RPL_WHOREPLY) {
			throw Exception('Not a WHO reply: ${msg.cmd}');
		}

		var channel = msg.params[1];
		var nickname = msg.params[5];
		var rawFlags = msg.params[6];
		var trailing = msg.params[7];

		var flags = _WhoFlags.parse(rawFlags, isupport);

		var i = trailing.indexOf(' ');
		if (i < 0) {
			throw FormatException('RPL_WHOREPLY trailing parameter must contain a space');
		}
		var realname = trailing.substring(i + 1);

		return WhoReply(
			nickname: nickname,
			away: flags.away,
			op: flags.op,
			realname: realname,
			channel: channel != '*' ? channel : null,
			membershipPrefix: channel != '*' ? flags.membershipPrefix : null,
		);
	}

	factory WhoReply.parseWhox(IrcMessage msg, Set<WhoxField> fields, IrcIsupportRegistry isupport) {
		assert(msg.cmd == RPL_WHOSPCRPL);

		String? channel, nickname, account, realname;
		_WhoFlags? flags;
		var i = 1;
		for (var field in _whoxFields) {
			if (!fields.contains(field)) {
				continue;
			}

			var v = msg.params[i];
			i++;

			switch (field) {
			case WhoxField.channel:
				channel = v;
				break;
			case WhoxField.nickname:
				nickname = v;
				break;
			case WhoxField.flags:
				flags = _WhoFlags.parse(v, isupport);
				break;
			case WhoxField.account:
				if (v != '0') {
					account = v;
				}
				break;
			case WhoxField.realname:
				realname = v;
				break;
			}
		}

		return WhoReply(
			nickname: nickname!,
			away: flags!.away,
			op: flags.op,
			realname: realname!,
			channel: channel,
			membershipPrefix: channel != null ? flags.membershipPrefix : null,
			account: account,
		);
	}
}

class _WhoFlags {
	final bool away;
	final bool op;
	final String membershipPrefix;

	const _WhoFlags({
		this.away = false,
		this.op = false,
		this.membershipPrefix = '',
	});

	factory _WhoFlags.parse(String flags, IrcIsupportRegistry isupport) {
		var away = flags.contains('G');
		var op = flags.contains('*');

		var prefixes = isupport.memberships.map((m) => m.prefix).join('');
		var membershipPrefix = flags.split('').where((flag) => prefixes.contains(flag)).join('');

		return _WhoFlags(
			away: away,
			op: op,
			membershipPrefix: membershipPrefix,
		);
	}
}

const _whoxFields = [
	WhoxField.channel,
	WhoxField.nickname,
	WhoxField.flags,
	WhoxField.account,
	WhoxField.realname,
];

class WhoxField {
	final String _letter;

	const WhoxField._(this._letter);

	@override
	String toString() {
		return _letter;
	}

	static const channel = WhoxField._('c');
	static const nickname = WhoxField._('n');
	static const flags = WhoxField._('f');
	static const account = WhoxField._('a');
	static const realname = WhoxField._('r');
}

String formatWhoxParam(Set<WhoxField> fields) {
	return '%' + fields.toList().map((field) => field._letter).join('');
}

enum ChanModeUpdateKind { add, remove }

enum _ChanModeType { a, b, c, d }

class ChanModeUpdate {
	final String mode;
	final ChanModeUpdateKind kind;
	final String? arg;

	const ChanModeUpdate({ required this.mode, required this.kind, this.arg });

	static List<ChanModeUpdate> parse(IrcMessage msg, IrcIsupportRegistry isupport) {
		Map<String, _ChanModeType> typeByMode = {};

		for (var i = 0; i < _ChanModeType.values.length; i++) {
			var type = _ChanModeType.values[i];
			for (var mode in isupport.chanModes[i].split('')) {
				typeByMode[mode] = type;
			}
		}

		for (var membership in isupport.memberships) {
			typeByMode[membership.mode] = _ChanModeType.b;
		}

		assert(msg.cmd == 'MODE');
		var change = msg.params[1];
		var args = msg.params.sublist(2);

		List<ChanModeUpdate> updates = [];
		ChanModeUpdateKind? kind;
		var j = 0;
		for (var i = 0; i < change.length; i++) {
			if (change[i] == '+') {
				kind = ChanModeUpdateKind.add;
				continue;
			} else if (change[i] == '-') {
				kind = ChanModeUpdateKind.remove;
				continue;
			} else if (kind == null) {
				throw FormatException('Malformed MODE string: missing plus/minus');
			}

			var mode = change[i];
			var type = typeByMode[mode];
			if (type == null) {
				throw FormatException('Malformed MODE string: mode "$mode" missing from CHANMODES and PREFIX');
			}

			String? arg;
			if (_chanModeTypeHasArg(type, kind)) {
				arg = args[j];
				j++;
			}

			updates.add(ChanModeUpdate(mode: mode, kind: kind, arg: arg));
		}

		return updates;
	}
}

bool _chanModeTypeHasArg(_ChanModeType type, ChanModeUpdateKind kind) {
	switch (type) {
	case _ChanModeType.a:
	case _ChanModeType.b:
		return true;
	case _ChanModeType.c:
		return kind == ChanModeUpdateKind.add;
	case _ChanModeType.d:
		return false;
	}
}

String updateIrcMembership(String str, ChanModeUpdate update, IrcIsupportRegistry isupport) {
	var memberships = isupport.memberships.where((m) => m.mode == update.mode).toList();
	if (memberships.length != 1) {
		return str;
	}
	var membership = memberships[0];

	switch (update.kind) {
	case ChanModeUpdateKind.add:
		if (str.contains(membership.prefix)) {
			return str;
		}
		str = str + membership.prefix;
		var l = str.split('');
		l.sort((a, b) {
			var i = _membershipIndexByPrefix(memberships, a);
			var j = _membershipIndexByPrefix(memberships, b);
			return i - j;
		});
		return l.join('');
	case ChanModeUpdateKind.remove:
		return str.replaceAll(membership.prefix, '');
	}
}

int _membershipIndexByPrefix(List<IrcIsupportMembership> memberships, String prefix) {
	for (var i = 0; i < memberships.length; i++) {
		if (memberships[i].prefix == prefix) {
			return i;
		}
	}
	throw Exception('Unknown membership prefix "$prefix"');
}

abstract class UserMode {
	static const invisible = 'i';
	static const op = 'o';
	static const localOp = 'O';
}

abstract class ChannelMode {
	static const ban = 'b';
	static const clientLimit = 'l';
	static const inviteOnly = 'i';
	static const key = 'k';
	static const moderated = 'm';
	static const secret = 's';
	static const protectedTopic = 't';
	static const noExternalMessages = 'n';
}

/// Checks whether a realname is worth displaying.
bool isStubRealname(String realname, String nickname) {
	if (realname == nickname) {
		return true;
	}

	// Since the realname is mandatory, many clients set a meaningless one.
	switch (realname.toLowerCase()) {
	case 'realname':
	case 'unknown':
	case 'fullname':
		return true;
	}

	return false;
}
