import 'dart:io';
import 'dart:async';

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
	String? saslPlainPassword;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'host': host,
			'port': port,
			'tls': tls ? 1 : 0,
			'nick': nick,
			'pass': pass,
			'sasl_plain_password': saslPlainPassword,
		};
	}

	ServerEntry({ required this.host, this.port, this.tls = true, this.nick, this.pass, this.saslPlainPassword });

	ServerEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		host = m['host'] as String,
		port = m['port'] as int?,
		tls = m['tls'] != 0,
		nick = m['nick'] as String?,
		pass = m['pass'] as String?,
		saslPlainPassword = m['sasl_plain_password'] as String?;
}

class NetworkEntry {
	int? id;
	final int server;
	String? bouncerId;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'server': server,
			'bouncer_id': bouncerId,
		};
	}

	NetworkEntry({ required this.server, this.bouncerId });

	NetworkEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		server = m['server'] as int,
		bouncerId = m['bouncer_id'] as String?;
}

class BufferEntry {
	int? id;
	final String name;
	final int network;
	String? lastReadTime;
	bool pinned;
	bool muted;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'name': name,
			'network': network,
			'last_read_time': lastReadTime,
			'pinned': pinned ? 1 : 0,
			'muted': muted ? 1 : 0,
		};
	}

	BufferEntry({ required this.name, required this.network, this.pinned = false, this.muted = false });

	BufferEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'] as int,
		name = m['name'] as String,
		network = m['network'] as int,
		lastReadTime = m['last_read_time'] as String?,
		pinned = m['pinned'] == 1,
		muted = m['muted'] == 1;
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

class DB {
	final Database _db;

	DB._(this._db);

	static Future<DB> open() async {
		WidgetsFlutterBinding.ensureInitialized();

		if (Platform.isLinux) {
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
				batch.execute('''
					CREATE TABLE Server (
						id INTEGER PRIMARY KEY,
						host TEXT NOT NULL,
						port INTEGER,
						tls INTEGER NOT NULL DEFAULT 1,
						nick TEXT,
						pass TEXT,
						sasl_plain_password TEXT
					)
				''');
				batch.execute('''
					CREATE TABLE Network (
						id INTEGER PRIMARY KEY,
						server INTEGER NOT NULL,
						bouncer_id TEXT,
						FOREIGN KEY (server) REFERENCES Server(id) ON DELETE CASCADE,
						UNIQUE(server, bouncer_id)
					)
				''');
				batch.execute('''
					CREATE TABLE Buffer (
						id INTEGER PRIMARY KEY,
						name TEXT NOT NULL,
						network INTEGER NOT NULL,
						last_read_time TEXT,
						pinned INTEGER NOT NULL DEFAULT 0,
						muted INTEGER NOT NULL DEFAULT 0,
						FOREIGN KEY (network) REFERENCES Network(id) ON DELETE CASCADE,
						UNIQUE(name, network)
					)
				''');
				batch.execute('''
					CREATE TABLE Message (
						id INTEGER PRIMARY KEY,
						time TEXT NOT NULL,
						buffer INTEGER NOT NULL,
						raw TEXT NOT NULL,
						FOREIGN KEY (buffer) REFERENCES Buffer(id) ON DELETE CASCADE
					)
				''');
				batch.execute('''
					CREATE INDEX index_message_buffer_time
					ON Message(buffer, time);
				''');
				await batch.commit();
			},
			onUpgrade: (db, prevVersion, newVersion) async {
				print('Upgrading database from version $prevVersion to version $newVersion');

				var batch = db.batch();
				if (prevVersion < 2) {
					batch.execute('''
						CREATE INDEX index_message_buffer_time
						ON Message(buffer, time);
					''');
				}
				if (prevVersion < 3) {
					batch.execute('''
						ALTER TABLE Buffer ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
					''');
				}
				if (prevVersion < 4) {
					batch.execute('''
						ALTER TABLE Buffer ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;
					''');
				}
				await batch.commit();
			},
			onDowngrade: (_, prevVersion, newVersion) async {
				throw Exception('Attempted to downgrade database from version $prevVersion to version $newVersion');
			},
			version: 4,
		);
		return DB._(db);
	}

	static Future<String> _getBasePath() {
		if (!Platform.isLinux) {
			return getDatabasesPath();
		}

		var xdgDataHome = Platform.environment['XDG_DATA_HOME'] ?? join(Platform.environment['HOME']!, '.local', 'share');
		return Future.value(join(xdgDataHome, 'goguma'));
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
			SELECT id, host, port, tls, nick, pass, sasl_plain_password
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
			SELECT id, server, bouncer_id FROM Network ORDER BY id
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
			SELECT id, name, network, last_read_time, pinned, muted FROM Buffer ORDER BY id
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

	Future<Map<int, int>> fetchBuffersUnreadCount() async {
		var entries = await _db.rawQuery('''
			SELECT
				Message.buffer, COUNT(Message.id) AS unread_count
			FROM Message
			LEFT JOIN Buffer ON Message.buffer = Buffer.id
			WHERE Message.time > Buffer.last_read_time
			GROUP BY Message.buffer
		''');
		return <int, int>{
			for (var m in entries)
				m['buffer'] as int: m['unread_count'] as int,
		};
	}

	Future<Map<int, String>> fetchBuffersLastDeliveredTime() async {
		var entries = await _db.rawQuery('''
			SELECT buffer, MAX(time) AS time
			FROM Message
			GROUP BY buffer
		''');
		return <int, String>{
			for (var m in entries)
				m['buffer'] as int: m['time'] as String,
		};
	}

	Future<List<MessageEntry>> listMessages(int buffer) async {
		var entries = await _db.rawQuery('''
			SELECT id, time, buffer, raw
			FROM Message
			WHERE buffer = ?
			ORDER BY time
		''', [buffer]);
		return entries.map((m) => MessageEntry.fromMap(m)).toList();
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

	Future<List<MessageEntry>> listUnreadMessages(int buffer) async {
		var entries = await _db.rawQuery('''
			SELECT Message.id, Message.time, Message.buffer, Message.raw
			FROM Message
			LEFT JOIN Buffer ON Message.buffer = Buffer.id
			WHERE buffer = ? AND Message.time > Buffer.last_read_time
			ORDER BY time
		''', [buffer]);
		return entries.map((m) => MessageEntry.fromMap(m)).toList();
	}
}
