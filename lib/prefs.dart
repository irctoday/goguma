import 'package:shared_preferences/shared_preferences.dart';

const _bufferCompactKey = 'buffer_compact';
const _typingIndicatorKey = 'typing_indicator';
const _nicknameKey = 'nickname';
const _realnameKey = 'realname';
const _pushProviderKey = 'push_provider';
const _linkPreviewKey = 'link_preview';
const _linkExtAppKey = 'link_external_app';
const _recentReactionsKey = 'recent_reactions';
const _uploadErrorReportsKey = 'upload_error_reports';

const _maxRecentReactions = 14;

class Prefs {
	final SharedPreferences _prefs;

	Prefs._(this._prefs);

	static Future<Prefs> load() async {
		return Prefs._(await SharedPreferences.getInstance());
	}

	bool get bufferCompact => _prefs.getBool(_bufferCompactKey) ?? false;
	bool get typingIndicator => _prefs.getBool(_typingIndicatorKey) ?? true;
	String get nickname => _prefs.getString(_nicknameKey) ?? 'user';
	String? get realname => _prefs.getString(_realnameKey);
	String? get pushProvider => _prefs.getString(_pushProviderKey);
	bool get linkPreview => _prefs.getBool(_linkPreviewKey) ?? true;
	bool get linkExtApp => _prefs.getBool(_linkExtAppKey) ?? false;
	List<String> get recentReactions => _prefs.getStringList(_recentReactionsKey) ?? [];
	bool get uploadErrorReports => _prefs.getBool(_uploadErrorReportsKey) ?? true;

	set bufferCompact(bool enabled) {
		_prefs.setBool(_bufferCompactKey, enabled);
	}

	set typingIndicator(bool enabled) {
		_prefs.setBool(_typingIndicatorKey, enabled);
	}

	set nickname(String nickname) {
		_prefs.setString(_nicknameKey, nickname);
	}

	void _setOptionalString(String k, String? v) {
		if (v != null) {
			_prefs.setString(k, v);
		} else {
			_prefs.remove(k);
		}
	}

	set realname(String? realname) {
		_setOptionalString(_realnameKey, realname);
	}

	set pushProvider(String? provider) {
		_setOptionalString(_pushProviderKey, provider);
	}

	set linkPreview(bool enabled) {
		_prefs.setBool(_linkPreviewKey, enabled);
	}

	set linkExtApp(bool enabled) {
		_prefs.setBool(_linkExtAppKey, enabled);
	}

	void addRecentReaction(String reaction) {
		var reactions = [reaction, ...recentReactions.where((r) => r != reaction).take(_maxRecentReactions - 1)];
		_prefs.setStringList(_recentReactionsKey, reactions);
	}

	set uploadErrorReports(bool enabled) {
		_prefs.setBool(_uploadErrorReportsKey, enabled);
	}
}
