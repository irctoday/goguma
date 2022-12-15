import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'irc.dart';

class ServerEntry {
	int? id;
	String host;
	int? port;
	bool tls;
	String? nick;
	String? pass;
	String? saslPlainUsername;
	String? saslPlainPassword;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'host': host,
			'port': port,
			'tls': tls ? 1 : 0,
			'nick': nick,
			'pass': pass,
			'sasl_plain_username': saslPlainUsername,
			'sasl_plain_password': saslPlainPassword,
		};
	}

	ServerEntry({
		required this.host,
		this.port,
		this.tls = true,
		this.nick,
		this.pass,
		this.saslPlainUsername,
		this.saslPlainPassword,
	});

	ServerEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		host = m['host'] as String,
		port = m['port'] as int?,
		tls = m['tls'] != 0,
		nick = m['nick'] as String?,
		pass = m['pass'] as String?,
		saslPlainUsername = m['sasl_plain_username'] as String?,
		saslPlainPassword = m['sasl_plain_password'] as String?;
}

class NetworkEntry {
	int? id;
	final int server;
	String? bouncerId;
	String? bouncerName;
	String? _rawBouncerUri;
	String? _rawIsupport;
	String? _rawCaps;

	IrcUri? _bouncerUri;
	IrcIsupportRegistry? _isupport;
	IrcAvailableCapRegistry? _caps;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'server': server,
			'bouncer_id': bouncerId,
			'bouncer_name': bouncerName,
			'bouncer_uri': _rawBouncerUri,
			'isupport': _rawIsupport,
			'caps': _rawCaps,
		};
	}

	NetworkEntry({ required this.server, this.bouncerId, IrcUri? bouncerUri }) {
		this.bouncerUri = bouncerUri;
	}

	NetworkEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		server = m['server'] as int,
		bouncerId = m['bouncer_id'] as String?,
		bouncerName = m['bouncer_name'] as String?,
		_rawBouncerUri = m['bouncer_uri'] as String?,
		_rawIsupport = m['isupport'] as String?,
		_rawCaps = m['caps'] as String?;

	IrcIsupportRegistry get isupport {
		if (_rawIsupport != null && _isupport == null) {
			_isupport = IrcIsupportRegistry();
			_isupport!.parse(_rawIsupport!.split(' '));
		}
		return _isupport ?? IrcIsupportRegistry();
	}

	set isupport(IrcIsupportRegistry isupport) {
		_isupport = isupport;
		_rawIsupport = isupport.format().join(' ');
	}

	IrcAvailableCapRegistry get caps {
		if (_rawCaps != null && _caps == null) {
			_caps = IrcAvailableCapRegistry();
			_caps!.parse(_rawCaps!);
		}
		return _caps ?? IrcAvailableCapRegistry();
	}

	set caps(IrcAvailableCapRegistry caps) {
		_caps = caps;
		_rawCaps = caps.toString();
	}

	IrcUri? get bouncerUri {
		if (_rawBouncerUri != null && _bouncerUri == null) {
			_bouncerUri = IrcUri.parse(_rawBouncerUri!);
		}
		return _bouncerUri;
	}

	set bouncerUri(IrcUri? uri) {
		_bouncerUri = uri;
		_rawBouncerUri = uri?.toString();
	}
}

class BufferEntry {
	int? id;
	final String name;
	final int network;
	String? lastReadTime;
	bool pinned;
	bool muted;

	String? topic;
	String? realname;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'name': name,
			'network': network,
			'last_read_time': lastReadTime,
			'pinned': pinned ? 1 : 0,
			'muted': muted ? 1 : 0,
			'topic': topic,
			'realname': realname,
		};
	}

	BufferEntry({ required this.name, required this.network, this.pinned = false, this.muted = false });

	BufferEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		name = m['name'] as String,
		network = m['network'] as int,
		lastReadTime = m['last_read_time'] as String?,
		pinned = m['pinned'] == 1,
		muted = m['muted'] == 1,
		topic = m['topic'] as String?,
		realname = m['realname'] as String?;
}

class MessageEntry {
	int? id;
	final String time;
	final int buffer;
	final String raw;

	IrcMessage? _msg;
	DateTime? _dateTime;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'time': time,
			'buffer': buffer,
			'raw': raw,
		};
	}

	MessageEntry(IrcMessage msg, this.buffer) :
		time = msg.tags['time'] ?? formatIrcTime(DateTime.now()),
		raw = msg.toString(),
		_msg = msg;

	MessageEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		time = m['time'] as String,
		buffer = m['buffer'] as int,
		raw = m['raw'] as String;

	IrcMessage get msg {
		_msg ??= IrcMessage.parse(raw);
		return _msg!;
	}

	DateTime get dateTime {
		_dateTime ??= DateTime.parse(time);
		return _dateTime!;
	}
}

class WebPushSubscriptionEntry {
	int? id;
	final int network;
	final String endpoint;
	final String? tag;
	final String? vapidKey;
	final Uint8List p256dhPrivateKey;
	final Uint8List p256dhPublicKey;
	final Uint8List authKey;
	final DateTime createdAt;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'network': network,
			'endpoint': endpoint,
			'tag': tag,
			'vapid_key': vapidKey,
			'p256dh_private_key': p256dhPrivateKey,
			'p256dh_public_key': p256dhPublicKey,
			'auth_key': authKey,
			'created_at': formatIrcTime(createdAt),
		};
	}

	WebPushSubscriptionEntry({
		required this.network,
		required this.endpoint,
		this.tag,
		required this.p256dhPrivateKey,
		required this.p256dhPublicKey,
		required this.authKey,
		this.vapidKey,
	}) :
		createdAt = DateTime.now();

	WebPushSubscriptionEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		network = m['network'] as int,
		endpoint = m['endpoint'] as String,
		tag = m['tag'] as String?,
		vapidKey = m['vapid_key'] as String?,
		p256dhPrivateKey = m['p256dh_private_key'] as Uint8List,
		p256dhPublicKey = m['p256dh_public_key'] as Uint8List,
		authKey = m['auth_key'] as Uint8List,
		createdAt = DateTime.parse(m['created_at'] as String);

	Map<String, Uint8List> getPublicKeys() {
		return {
			'p256dh': p256dhPublicKey,
			'auth': authKey,
		};
	}
}

class LinkPreviewEntry {
	int? id;
	final String url;
	int? statusCode;
	String? mimeType;
	int? contentLength;
	DateTime updatedAt;

	LinkPreviewEntry({
		required this.url,
		this.statusCode,
		this.mimeType,
		this.contentLength,
	}) :
		updatedAt = DateTime.now();

	LinkPreviewEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		url = m['url'] as String,
		statusCode = m['status_code'] as int?,
		mimeType = m['mime_type'] as String?,
		contentLength = m['content_length'] as int?,
		updatedAt = DateTime.parse(m['updated_at'] as String);

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'url': url,
			'status_code': statusCode,
			'mime_type': mimeType,
			'content_length': contentLength,
			'updated_at': formatIrcTime(updatedAt),
		};
	}
}

// Note: because of limitations of the Android SQLite library, each statement
// must be in a separate string.

const _schema = [
	'''
		CREATE TABLE Server (
			id INTEGER PRIMARY KEY,
			host TEXT NOT NULL,
			port INTEGER,
			tls INTEGER NOT NULL DEFAULT 1,
			nick TEXT,
			pass TEXT,
			sasl_plain_username TEXT,
			sasl_plain_password TEXT
		)
	''',
	'''
		CREATE TABLE Network (
			id INTEGER PRIMARY KEY,
			server INTEGER NOT NULL,
			bouncer_id TEXT,
			bouncer_name TEXT,
			bouncer_uri TEXT,
			isupport TEXT,
			caps TEXT,
			FOREIGN KEY (server) REFERENCES Server(id) ON DELETE CASCADE,
			UNIQUE(server, bouncer_id)
		)
	''',
	'''
		CREATE TABLE Buffer (
			id INTEGER PRIMARY KEY,
			name TEXT NOT NULL,
			network INTEGER NOT NULL,
			last_read_time TEXT,
			pinned INTEGER NOT NULL DEFAULT 0,
			muted INTEGER NOT NULL DEFAULT 0,
			topic TEXT,
			realname TEXT,
			FOREIGN KEY (network) REFERENCES Network(id) ON DELETE CASCADE,
			UNIQUE(name, network)
		)
	''',
	'''
		CREATE TABLE Message (
			id INTEGER PRIMARY KEY,
			time TEXT NOT NULL,
			buffer INTEGER NOT NULL,
			raw TEXT NOT NULL,
			FOREIGN KEY (buffer) REFERENCES Buffer(id) ON DELETE CASCADE
		)
	''',
	'''
		CREATE INDEX index_message_buffer_time
		ON Message(buffer, time);
	''',
	'''
		CREATE TABLE WebPushSubscription (
			id INTEGER PRIMARY KEY,
			network INTEGER NOT NULL,
			endpoint TEXT NOT NULL,
			tag TEXT,
			vapid_key TEXT,
			p256dh_public_key BLOB,
			p256dh_private_key BLOB,
			auth_key BLOB,
			created_at TEXT NOT NULL,
			FOREIGN KEY (network) REFERENCES Network(id) ON DELETE CASCADE,
			UNIQUE(network, endpoint)
		);
	''',
	'''
		CREATE TABLE LinkPreview (
			id INTEGER PRIMARY KEY,
			url TEXT NOT NULL UNIQUE,
			status_code INTEGER,
			mime_type TEXT,
			content_length INTEGER,
			updated_at TEXT NOT NULL
		);
	''',
];

const _migrations = [
	'''
		CREATE INDEX index_message_buffer_time
		ON Message(buffer, time);
	''',
	'ALTER TABLE Buffer ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;',
	'ALTER TABLE Buffer ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;',
	'ALTER TABLE Buffer ADD COLUMN topic TEXT;',
	'ALTER TABLE Buffer ADD COLUMN realname TEXT;',
	'''
		CREATE TABLE WebPushSubscription (
			id INTEGER PRIMARY KEY,
			network INTEGER NOT NULL,
			endpoint TEXT NOT NULL,
			vapid_key TEXT,
			p256dh_public_key BLOB,
			p256dh_private_key BLOB,
			auth_key BLOB,
			created_at TEXT NOT NULL,
			FOREIGN KEY (network) REFERENCES Network(id) ON DELETE CASCADE,
			UNIQUE(network, endpoint)
		);
	''',
	'ALTER TABLE Network ADD COLUMN isupport TEXT;',
	'ALTER TABLE Network ADD COLUMN caps TEXT;',
	'ALTER TABLE Network ADD COLUMN bouncer_uri TEXT;',
	'ALTER TABLE Server ADD COLUMN sasl_plain_username TEXT;',
	'ALTER TABLE WebPushSubscription ADD COLUMN tag TEXT;',
	'''
		CREATE TABLE LinkPreview (
			id INTEGER PRIMARY KEY,
			url TEXT NOT NULL UNIQUE,
			status_code INTEGER,
			mime_type TEXT,
			content_length INTEGER,
			updated_at TEXT NOT NULL
		);
	''',
	'ALTER TABLE Network ADD COLUMN bouncer_name TEXT;',
];

class DB {
	final Database _db;

	DB._(this._db);

	static Future<DB> open() async {
		WidgetsFlutterBinding.ensureInitialized();

		if (Platform.isWindows || Platform.isLinux) {
			sqfliteFfiInit();
			databaseFactory = databaseFactoryFfi;
		}

		var basePath = await _getBasePath();
		var db = await openDatabase(
			join(basePath, 'main.db'),
			onConfigure: (db) async {
				// Enable support for ON DELETE CASCADE
				await db.execute('PRAGMA foreign_keys = ON');
			},
			onCreate: (db, version) async {
				print('Initializing database version $version');

				var batch = db.batch();
				for (var stmt in _schema) {
					batch.execute(stmt);
				}
				await batch.commit();
			},
			onUpgrade: (db, prevVersion, newVersion) async {
				print('Upgrading database from version $prevVersion to version $newVersion');

				var batch = db.batch();
				for (var ver = prevVersion; ver < newVersion; ver++) {
					batch.execute(_migrations[ver - 1]);
				}
				await batch.commit();
			},
			onDowngrade: (_, prevVersion, newVersion) async {
				throw Exception('Attempted to downgrade database from version $prevVersion to version $newVersion');
			},
			version: _migrations.length + 1,
		);
		return DB._(db);
	}

	static Future<String> _getBasePath() {
		if (Platform.isWindows) {
			return Future.value(join(Platform.environment['APPDATA']!, 'goguma'));
		}
		if (Platform.isLinux) {
			var xdgDataHome = Platform.environment['XDG_DATA_HOME'] ?? join(Platform.environment['HOME']!, '.local', 'share');
			return Future.value(join(xdgDataHome, 'goguma'));
		}
		return getDatabasesPath();
	}

	Future<void> close() {
		return _db.close();
	}

	Future<int> _updateById(String table, Map<String, Object?> values, { DatabaseExecutor? executor }) {
		int id = values['id']! as int;
		values.remove('id');
		return (executor ?? _db).update(
			table,
			values,
			where: 'id = ?',
			whereArgs: [id],
		);
	}

	Future<List<ServerEntry>> listServers() async {
		var entries = await _db.rawQuery('''
			SELECT id, host, port, tls, nick, pass, sasl_plain_username, sasl_plain_password
			FROM Server ORDER BY id
		''');
		return entries.map((m) => ServerEntry.fromMap(m)).toList();
	}

	Future<ServerEntry> storeServer(ServerEntry entry) async {
		if (entry.id == null) {
			var id = await _db.insert('Server', entry.toMap());
			entry.id = id;
		} else {
			await _updateById('Server', entry.toMap());
		}
		return entry;
	}

	Future<void> deleteServer(int id) async {
		await _db.rawDelete('DELETE FROM Server WHERE id = ?', [id]);
	}

	Future<List<NetworkEntry>> listNetworks() async {
		var entries = await _db.rawQuery('''
			SELECT id, server, bouncer_id, bouncer_name, bouncer_uri, isupport, caps
			FROM Network ORDER BY id
		''');
		return entries.map((m) => NetworkEntry.fromMap(m)).toList();
	}

	Future<NetworkEntry> storeNetwork(NetworkEntry entry) async {
		if (entry.id == null) {
			var id = await _db.insert('Network', entry.toMap());
			entry.id = id;
		} else {
			await _updateById('Network', entry.toMap());
		}
		return entry;
	}

	Future<void> deleteNetwork(int id) async {
		await _db.transaction((txn) async {
			var entries = await txn.rawQuery('''
				SELECT server, COUNT(id) AS n
				FROM Network
				WHERE server IN (
					SELECT server FROM Network WHERE id = ?
				)
			''', [id]);
			assert(entries.length == 1);
			var serverId = entries.first['server'] as int;
			var n = entries.first['n'] as int;
			assert(n > 0);

			if (n == 1) {
				// This is the last network using that server, we can
				// delete the server
				await txn.rawDelete('DELETE FROM Server WHERE id = ?', [serverId]);
			} else {
				await txn.rawDelete('DELETE FROM Network WHERE id = ?', [id]);
			}
		});
	}

	Future<List<BufferEntry>> listBuffers() async {
		var entries = await _db.rawQuery('''
			SELECT id, name, network, last_read_time, pinned, muted, topic, realname FROM Buffer ORDER BY id
		''');
		return entries.map((m) => BufferEntry.fromMap(m)).toList();
	}

	Future<BufferEntry> storeBuffer(BufferEntry entry) async {
		if (entry.id == null) {
			var id = await _db.insert('Buffer', entry.toMap());
			entry.id = id;
		} else {
			await _updateById('Buffer', entry.toMap());
		}
		return entry;
	}

	Future<void> deleteBuffer(int id) async {
		await _db.rawDelete('DELETE FROM Buffer WHERE id = ?', [id]);
	}

	Future<Map<int, int>> listBuffersUnreadCount() async {
		var entries = await _db.rawQuery('''
			SELECT id, (
				SELECT COUNT(id)
				FROM Message
				WHERE buffer = Buffer.id AND (
					Buffer.last_read_time IS NULL OR
					time > Buffer.last_read_time
				)
			) unread_count
			FROM Buffer
		''');
		return <int, int>{
			for (var m in entries)
				m['id'] as int: m['unread_count'] as int,
		};
	}

	Future<int> fetchBufferUnreadCount(int buffer) async {
		var entries = await _db.rawQuery('''
			WITH buf AS (SELECT last_read_time FROM Buffer WHERE id = ?)
			SELECT COUNT(id) AS unread_count
			FROM Message, buf
			WHERE buffer = ? AND (
				buf.last_read_time IS NULL OR
				time > buf.last_read_time
			)
		''', [buffer, buffer]);
		if (entries.isEmpty) {
			return 0;
		}
		return entries.first['unread_count'] as int;
	}

	Future<Map<int, String?>> listBuffersLastDeliveredTime() async {
		var entries = await _db.rawQuery('''
			SELECT id, (
				SELECT time
				FROM Message
				WHERE buffer = Buffer.id
				ORDER BY time DESC LIMIT 1
			) time
			FROM Buffer
		''');
		return <int, String?>{
			for (var m in entries)
				m['id'] as int: m['time'] as String?,
		};
	}

	Future<List<MessageEntry>> listMessagesBefore(int buffer, int? msg, int limit) async {
		var where = 'buffer = ?';
		var params = [buffer];
		if (msg != null) {
			where += ' AND id != ? AND time <= (SELECT time FROM Message WHERE id = ?)';
			params += [msg, msg];
		}
		var entries = await _db.rawQuery('''
			SELECT id, time, buffer, raw
			FROM Message
			WHERE $where
			ORDER BY time DESC LIMIT ?
		'''
		, [...params, limit]);
		var l = entries.map((m) => MessageEntry.fromMap(m)).toList();
		l.sort((a, b) {
			if (a.time != b.time) {
				return a.time.compareTo(b.time);
			}
			return a.id!.compareTo(b.id!);
		});
		return l;
	}

	Future<void> storeMessages(List<MessageEntry> entries) async {
		await _db.transaction((txn) async {
			await Future.wait(entries.map((entry) async {
				if (entry.id == null) {
					var id = await txn.insert('Message', entry.toMap());
					entry.id = id;
				} else {
					await _updateById('Message', entry.toMap(), executor: txn);
				}
			}));
		});
	}

	Future<List<WebPushSubscriptionEntry>> listWebPushSubscriptions() async {
		var entries = await _db.rawQuery('''
			SELECT id, network, endpoint, tag, vapid_key, p256dh_public_key,
				p256dh_private_key, auth_key, created_at
			FROM WebPushSubscription
		''');
		return entries.map((m) => WebPushSubscriptionEntry.fromMap(m)).toList();
	}

	Future<void> storeWebPushSubscription(WebPushSubscriptionEntry entry) async {
		if (entry.id == null) {
			entry.id = await _db.insert('WebPushSubscription', entry.toMap());
		} else {
			await _updateById('WebPushSubscription', entry.toMap());
		}
	}

	Future<void> deleteWebPushSubscription(int id) async {
		await _db.rawDelete('DELETE FROM WebPushSubscription WHERE id = ?', [id]);
	}

	Future<LinkPreviewEntry?> fetchLinkPreview(String url) async {
		var entries = await _db.rawQuery('''
			SELECT id, url, status_code, mime_type, content_length, updated_at
			FROM LinkPreview
			WHERE url = ?
		''', [url]);
		if (entries.isEmpty) {
			return null;
		}
		return LinkPreviewEntry.fromMap(entries.first);
	}

	Future<void> storeLinkPreview(LinkPreviewEntry entry) async {
		if (entry.id == null) {
			entry.id = await _db.insert('LinkPreview', entry.toMap());
		} else {
			await _updateById('LinkPreview', entry.toMap());
		}
	}
}
