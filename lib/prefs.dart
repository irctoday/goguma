import 'package:shared_preferences/shared_preferences.dart';

const _bufferCompactKey = 'buffer_compact';
const _typingIndicatorKey = 'typing_indicator';
const _nicknameKey = 'nickname';
const _realnameKey = 'realname';

class Prefs {
	final SharedPreferences _prefs;

	Prefs._(this._prefs);

	static Future<Prefs> load() async {
		return Prefs._(await SharedPreferences.getInstance());
	}

	bool get bufferCompact => _prefs.getBool(_bufferCompactKey) ?? false;
	bool get typingIndicator => _prefs.getBool(_typingIndicatorKey) ?? false;
	String get nickname => _prefs.getString(_nicknameKey) ?? 'user';
	String? get realname => _prefs.getString(_realnameKey);

	set bufferCompact(bool enabled) {
		_prefs.setBool(_bufferCompactKey, enabled);
	}

	set typingIndicator(bool enabled) {
		_prefs.setBool(_typingIndicatorKey, enabled);
	}

	set nickname(String nickname) {
		_prefs.setString(_nicknameKey, nickname);
	}

	set realname(String? realname) {
		if (realname != null) {
			_prefs.setString(_realnameKey, realname);
		} else {
			_prefs.remove(_realnameKey);
		}
	}
}
