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
const RPL_AWAY = '301';
const RPL_UNAWAY = '305';
const RPL_NOWAWAY = '306';
const RPL_WHOISREGNICK = '307';
const RPL_WHOISUSER = '311';
const RPL_WHOISSERVER = '312';
const RPL_WHOISOPERATOR = '313';
const RPL_ENDOFWHO = '315';
const RPL_WHOISIDLE = '317';
const RPL_ENDOFWHOIS = '318';
const RPL_WHOISCHANNELS = '319';
const RPL_WHOISSPECIAL = '320';
const RPL_LIST = '322';
const RPL_LISTEND = '323';
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
const RPL_MOTD = '372';
const RPL_MOTDSTART = '375';
const RPL_ENDOFMOTD = '376';
const RPL_WHOISHOST = '378';
const RPL_WHOISMODES = '379';
const ERR_UNKNOWNERROR = '400';
const ERR_NOSUCHNICK = '401';
const ERR_NOSUCHCHANNEL = '403';
const ERR_CANNOTSENDTOCHAN = '404';
const ERR_TOOMANYCHANNELS = '405';
const ERR_NOTEXTTOSEND = '412';
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
const ERR_BADCHANMASK = '476';
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

class IrcParamList extends UnmodifiableListView<String> {
	final String _cmd;

	IrcParamList._(Iterable<String> source, this._cmd) : super(source);

	@override
	String operator [](int index) {
		try {
			return super[index];
		} on RangeError {
			throw FormatException('Invalid $_cmd message: missing parameter at index $index');
		}
	}
}

class IrcMessage {
	final UnmodifiableMapView<String, String?> tags;
	final IrcSource? source;
	final String cmd;
	final IrcParamList params;

	IrcMessage(this.cmd, List<String> params, {
		Map<String, String?> tags = const {},
		this.source,
	}) :
		tags = UnmodifiableMapView(tags),
		params = IrcParamList._(params, cmd);

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

	IrcMessage copyWith({
		IrcSource? source,
		Map<String, String?>? tags,
	}) {
		return IrcMessage(
			cmd,
			params,
			source: source ?? this.source,
			tags: tags ?? this.tags,
		);
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

String _unescapeTag(String s) {
	var chars = s.split('');
	StringBuffer out = StringBuffer();
	for (var i = 0; i < chars.length; i++) {
		var ch = chars[i];
		if (ch != '\\' || i + 1 >= chars.length) {
			out.write(ch);
			continue;
		}

		i++;
		ch = chars[i];
		out.write(_unescapeChar(ch));
	}
	return out.toString();
}

String _unescapeChar(String ch) {
	switch (ch) {
	case ':':
		return ';';
	case 's':
		return ' ';
	case 'r':
		return '\r';
	case 'n':
		return '\n';
	default:
		return ch;
	}
}

enum IrcUriEntityType { user, channel }

class IrcUriEntity {
	final String name;
	final IrcUriEntityType type;

	const IrcUriEntity(this.name, this.type);
}

class IrcUriAuth {
	final String username;
	final String? password;

	const IrcUriAuth(this.username, [this.password]);
}

/// An IRC URI.
///
/// IRC URIs are defined in:
/// https://datatracker.ietf.org/doc/html/draft-butcher-irc-url-04
class IrcUri {
	final String? host;
	final int? port;
	final IrcUriAuth? auth;
	final IrcUriEntity? entity;

	const IrcUri({ this.host, this.port, this.auth, this.entity });

	static IrcUri parse(String s) {
		if (!s.startsWith('irc://') && !s.startsWith('ircs://')) {
			throw FormatException('Invalid IRC URI "$s": unsupported scheme');
		}
		s = s.substring(s.indexOf(':') + '://'.length);

		String loc;
		var i = s.indexOf('/');
		if (i >= 0) {
			loc = s.substring(0, i);
			s = s.substring(i + 1);
		} else {
			loc = s;
			s = '';
		}

		var host = loc;
		IrcUriAuth? auth;
		i = loc.indexOf('@');
		if (i >= 0) {
			var rawAuth = loc.substring(0, i);
			host = loc.substring(i + 1);

			var username = rawAuth;
			String? password;
			i = rawAuth.indexOf(':');
			if (i >= 0) {
				username = rawAuth.substring(0, i);
				password = Uri.decodeComponent(rawAuth.substring(i + 1));
			}

			username = Uri.decodeComponent(username);
			auth = IrcUriAuth(username, password);
		}

		int? port;
		i = host.indexOf(':');
		if (i >= 0) {
			port = int.parse(host.substring(i + 1));
			host = host.substring(0, i);
		}

		i = s.indexOf('?');
		if (i >= 0) {
			s = s.substring(0, i);
			// TODO: parse options
		}

		IrcUriEntityType? type;
		i = s.indexOf(',');
		if (i >= 0) {
			var flags = s.substring(i + 1).split(',');
			s = s.substring(0, i);

			if (flags.contains('isuser')) {
				type = IrcUriEntityType.user;
			} else if (flags.contains('ischannel')) {
				type = IrcUriEntityType.channel;
			}

			// TODO: parse hosttype
		}

		IrcUriEntity? entity;
		if (s != '') {
			// TODO: consider using PREFIX ISUPPORT here, if available
			var name = Uri.decodeComponent(s);
			type ??= name.startsWith('#') ? IrcUriEntityType.channel : IrcUriEntityType.user;
			entity = IrcUriEntity(name, type);
		}

		return IrcUri(
			host: host,
			port: port,
			auth: auth,
			entity: entity,
		);
	}

	@override
	String toString() {
		var s = 'ircs://';
		if (auth != null) {
			s += Uri.encodeComponent(auth!.username);
			if (auth!.password != null) {
				s += ':' + Uri.encodeComponent(auth!.password!);
			}
			s += '@';
		}
		if (host != null) {
			s += host!;
		}
		s += '/';
		if (port != null && port != 6697) {
			s += ':$port';
		}
		if (entity != null) {
			s += Uri.encodeComponent(entity!.name);
			if (entity!.type == IrcUriEntityType.user) {
				s += ',isuser';
			}
		}
		return s;
	}
}

Uri parseServerUri(String rawUri) {
	if (!rawUri.contains('://')) {
		rawUri = 'ircs://' + rawUri;
	}

	var uri = Uri.parse(rawUri);
	if (uri.host == '') {
		throw FormatException('Host is required in URI');
	}
	switch (uri.scheme) {
	case 'ircs':
	case 'irc+insecure':
		break; // supported
	default:
		throw FormatException('Unsupported URI scheme: ' + uri.scheme);
	}

	return uri;
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

class IrcAvailableCapRegistry {
	final Map<String, String?> _raw = {};

	void parse(String caps) {
		if (caps == '') {
			return;
		}
		for (var s in caps.split(' ')) {
			var i = s.indexOf('=');
			String k = s;
			String? v;
			if (i >= 0) {
				k = s.substring(0, i);
				v = s.substring(i + 1);
			}
			_raw[k.toLowerCase()] = v;
		}
	}

	@override
	String toString() {
		return _raw.entries.map((entry) {
			if (entry.value == null) {
				return entry.key;
			}
			return '${entry.key}=${entry.value}';
		}).join(' ');
	}

	void clear() {
		_raw.clear();
	}

	bool containsKey(String name) {
		return _raw.containsKey(name);
	}

	int? get chatHistory {
		if (!_raw.containsKey('draft/chathistory')) {
			return null;
		}
		var v = _raw['draft/chathistory'] ?? '0';
		return int.parse(v);
	}

	bool containsSasl(String mech) {
		if (!_raw.containsKey('sasl')) {
			return false;
		}
		var v = _raw['sasl'];
		if (v == null) {
			// SASL is supported, but we don't know which mechanisms are
			// supported
			return true;
		}
		return v.toUpperCase().split(',').contains(mech.toUpperCase());
	}

	bool get accountRequired => containsKey('soju.im/account-required');
}

class IrcCapRegistry {
	final IrcAvailableCapRegistry available = IrcAvailableCapRegistry();
	final Set<String> _enabled = {};

	UnmodifiableSetView<String> get enabled => UnmodifiableSetView(_enabled);

	void parse(IrcMessage msg) {
		assert(msg.cmd == 'CAP');

		var subcommand = msg.params[1].toUpperCase();
		var params = msg.params.sublist(2);
		switch (subcommand) {
		case 'LS':
			available.parse(params[params.length - 1]);
			break;
		case 'NEW':
			available.parse(params[0]);
			break;
		case 'DEL':
			for (var cap in params[0].split(' ')) {
				cap = cap.toLowerCase();
				available._raw.remove(cap);
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

	void clear() {
		available.clear();
	}
}

final defaultCaseMapping = _caseMappingByName('rfc1459')!;

final _defaultMemberships = [
	IrcIsupportMembership('q', '~'),
	IrcIsupportMembership('a', '&'),
	IrcIsupportMembership('o', '@'),
	IrcIsupportMembership('h', '%'),
	IrcIsupportMembership('v', '+'),
];

final _defaultChanModes = ['beI', 'k', 'l', 'imnst'];

// TODO: don't return these when the server indicates no limit
const _defaultUsernameLen = 20;
const _defaultHostnameLen = 63;
const _defaultLineLen = 512;

class IrcIsupportRegistry {
	Map<String, String?> _raw = {};
	CaseMapping? _caseMapping;
	List<IrcIsupportMembership>? _memberships;
	int? _monitor;
	int? _topicLen, _nickLen, _realnameLen, _usernameLen, _hostnameLen, _lineLen;
	List<String>? _chanModes;
	IrcIsupportElist? _elist;

	String? get network => _raw['NETWORK'];
	String get chanTypes => _raw['CHANTYPES'] ?? '#&+!';
	CaseMapping get caseMapping => _caseMapping ?? defaultCaseMapping;
	String? get bouncerNetId => _raw['BOUNCER_NETID'];
	UnmodifiableListView<IrcIsupportMembership> get memberships => UnmodifiableListView(_memberships ?? _defaultMemberships);
	int? get monitor => _monitor;
	String? get botMode => _raw['BOT'];
	bool get whox => _raw.containsKey('WHOX');
	int? get topicLen => _topicLen;
	int? get nickLen => _nickLen;
	int? get realnameLen => _realnameLen;
	int get usernameLen => _usernameLen ?? _defaultUsernameLen;
	int get hostnameLen => _hostnameLen ?? _defaultHostnameLen;
	int get lineLen => _lineLen ?? _defaultLineLen;
	List<String> get chanModes => UnmodifiableListView(_chanModes ?? _defaultChanModes);
	IrcIsupportElist? get elist => _elist;
	String? get vapid => _raw['VAPID'];

	void parse(List<String> tokens) {
		for (var tok in tokens) {
			if (tok.startsWith('-')) {
				var k = tok.substring(1).toUpperCase();
				_raw.remove(k);
				switch (k) {
				case 'CASEMAPPING':
					_caseMapping = null;
					break;
				case 'CHANMODES':
					_chanModes = null;
					break;
				case 'ELIST':
					_elist = null;
					break;
				case 'HOSTLEN':
					_hostnameLen = null;
					break;
				case 'LINELEN':
					_lineLen = null;
					break;
				case 'MONITOR':
					_monitor = null;
					break;
				case 'NAMELEN':
					_realnameLen = null;
					break;
				case 'NICKLEN':
					_nickLen = null;
					break;
				case 'PREFIX':
					_memberships = null;
					break;
				case 'TOPIC':
					_topicLen = null;
					break;
				case 'USERLEN':
					_usernameLen = null;
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
				v = v.replaceAll('\\x20', ' ').replaceAll('\\x5C', '\\').replaceAll('\\x3D', '=');
			}

			_raw[k] = v;

			switch (k.toUpperCase()) {
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
			case 'ELIST':
				_elist = IrcIsupportElist.parse(v ?? '');
				break;
			case 'HOSTLEN':
				if (v == null || v == '') {
					_hostnameLen = null;
				} else {
					_hostnameLen = int.parse(v);
				}
				break;
			case 'LINELEN':
				if (v == null) {
					throw FormatException('Malformed ISUPPORT LINELEN: no value');
				}
				_lineLen = int.parse(v);
				break;
			case 'MONITOR':
				_monitor = int.parse(v ?? '0');
				break;
			case 'NAMELEN':
				if (v == null || v == '') {
					_realnameLen = null;
				} else {
					_realnameLen = int.parse(v);
				}
				break;
			case 'NICKLEN':
				if (v == null || v == '') {
					_nickLen = null;
				} else {
					_nickLen = int.parse(v);
				}
				break;
			case 'PREFIX':
				if (v == null || v == '') {
					_memberships = null;
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
				List<IrcIsupportMembership> memberships = [];
				for (var i = 0; i < modes.length; i++) {
					memberships.add(IrcIsupportMembership(modes[i], prefixes[i]));
				}
				_memberships = memberships;
				break;
			case 'TOPICLEN':
				if (v == null || v == '') {
					_topicLen = null;
				} else {
					_topicLen = int.parse(v);
				}
				break;
			case 'USERLEN':
				if (v == null || v == '') {
					_usernameLen = null;
				} else {
					_usernameLen = int.parse(v);
				}
				break;
			}
		}
	}

	void clear() {
		_raw = {};
		_caseMapping = null;
		_memberships = null;
		_monitor = null;
		_topicLen = null;
		_nickLen = null;
		_realnameLen = null;
		_usernameLen = null;
		_hostnameLen = null;
		_lineLen = null;
		_elist = null;
	}

	List<String> format() {
		List<String> l = [];
		for (var entry in _raw.entries) {
			if (entry.value == null) {
				l.add(entry.key);
			} else {
				// Note, clients are expected to handle '=' correctly
				var v = entry.value!.replaceAll(' ', '\\x20').replaceAll('\\', '\\x5C');
				l.add('${entry.key}=$v');
			}
		}
		return l;
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

	@override
	bool containsKey(Object? key) {
		return _m.containsKey(_cm(key as String));
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
		cmd = cmd.toUpperCase();

	String format() {
		var s = '\x01$cmd';
		if (param != null) {
			s += ' $param';
		}
		s += '\x01';
		return s;
	}

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
	final String? away;
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
		this.away,
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
		String? away;
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
			case RPL_AWAY:
				away = msg.params[2];
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
			away: away,
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
	if (realname.toLowerCase() == nickname.toLowerCase()) {
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

class ListReply {
	final String channel;
	final int clients;
	final String topic;

	const ListReply({ required this.channel, required this.clients, required this.topic });

	factory ListReply.parse(IrcMessage msg) {
		assert(msg.cmd == RPL_LIST);

		return ListReply(
			channel: msg.params[1],
			clients: int.parse(msg.params[2]),
			topic: msg.params[3],
		);
	}
}

enum ChannelStatus { public, secret, private }

class NamesReply {
	final String channel;
	final ChannelStatus status;
	final UnmodifiableListView<NamesReplyMember> members;

	NamesReply({ required this.channel, required this.status, required List<NamesReplyMember> members }) :
		members = UnmodifiableListView(members);

	factory NamesReply.parse(List<IrcMessage> replies, IrcIsupportRegistry isupport) {
		assert(replies.first.cmd == RPL_NAMREPLY);
		var symbol = replies.first.params[1];
		var channel = replies.first.params[2];

		ChannelStatus status;
		switch (symbol) {
		case '=':
			status = ChannelStatus.public;
			break;
		case '@':
			status = ChannelStatus.secret;
			break;
		case '*':
			status = ChannelStatus.private;
			break;
		default:
			throw FormatException('Unknown channel status symbol: $symbol');
		}

		var allPrefixes = isupport.memberships.map((m) => m.prefix).join('');
		List<NamesReplyMember> members = [];
		for (var reply in replies) {
			assert(reply.cmd == RPL_NAMREPLY);
			for (var raw in reply.params[3].split(' ')) {
				if (raw == '') {
					continue;
				}
				var i = 0;
				while (i < raw.length && allPrefixes.contains(raw[i])) {
					i++;
				}
				var prefix = raw.substring(0, i);
				var nickname = raw.substring(i);
				members.add(NamesReplyMember(nickname: nickname, prefix: prefix));
			}
		}

		return NamesReply(
			channel: channel,
			status: status,
			members: members,
		);
	}
}

class NamesReplyMember {
	final String prefix;
	final String nickname;

	const NamesReplyMember({ required this.nickname, this.prefix = '' });
}

// See https://modern.ircdocs.horse/#clients
String? validateNickname(String nickname, IrcIsupportRegistry isupport) {
	if (nickname.isEmpty) {
		return 'Cannot be empty';
	}
	for (var ch in const [' ', ',', '*', '?', '!', '@']) {
		if (nickname.contains(ch)) {
			return 'Cannot contain "$ch"';
		}
	}
	for (var ch in ['\$', ':', ...isupport.chanTypes.split('')]) {
		if (nickname.startsWith(ch)) {
			return 'Cannot start with "$ch"';
		}
	}
	return null;
}

// See https://modern.ircdocs.horse/#channels
String? validateChannel(String channel, IrcIsupportRegistry isupport) {
	if (isupport.chanTypes.isEmpty) {
		return 'Channels are disabled on this server';
	}

	for (var ch in const [' ', ',', '\x07']) {
		if (channel.contains(ch)) {
			return 'Cannot contain "$ch"';
		}
	}

	var chanTypes = isupport.chanTypes.split('');
	bool found = false;
	for (var ch in chanTypes) {
		if (channel.startsWith(ch)) {
			found = true;
			break;
		}
	}
	if (!found) {
		return 'Must start with any of "${chanTypes.join('", "')}"';
	}

	return null;
}
