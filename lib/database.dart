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
		id = m['id'],
		host = m['host'],
		port = m['port'],
		tls = m['tls'] != 0,
		nick = m['nick'],
		pass = m['pass'],
		saslPlainPassword = m['sasl_plain_password'];
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
		id = m['id'],
		server = m['server'],
		bouncerId = m['bouncer_id'];
}

class BufferEntry {
	int? id;
	final String name;
	final int network;
	String? lastReadTime;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'name': name,
			'network': network,
			'last_read_time': lastReadTime,
		};
	}

	BufferEntry({ required this.name, required this.network });

	BufferEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'],
		name = m['name'],
		network = m['network'],
		lastReadTime = m['last_read_time'];
}

class MessageEntry {
	int? id;
	final String time;
	final int buffer;
	final String raw;
	int flags;

	IRCMessage? _msg;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'time': time,
			'buffer': buffer,
			'raw': raw,
			'flags': flags,
		};
	}

	MessageEntry(IRCMessage msg, this.buffer) :
		time = msg.tags['time'] ?? formatIRCTime(DateTime.now()),
		raw = msg.toString(),
		flags = 0,
		_msg = msg;

	MessageEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'],
		time = m['time'],
		buffer = m['buffer'],
		raw = m['raw'],
		flags = m['flags'];

	IRCMessage get msg {
		return _msg ?? IRCMessage.parse(raw);
	}
}

class DB {
	final Database _db;

	DB._(Database this._db);

	static Future<DB> open() {
		WidgetsFlutterBinding.ensureInitialized();

		if (Platform.isLinux) {
			sqfliteFfiInit();
			databaseFactory = databaseFactoryFfi;
		}

		return _getBasePath().then((basePath) {
			return openDatabase(
				join(basePath, 'main.db'),
				onConfigure: (db) {
					// Enable support for ON DELETE CASCADE
					return db.execute('PRAGMA foreign_keys = ON');
				},
				onCreate: (db, version) {
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
							flags INTEGER NOT NULL DEFAULT 0,
							FOREIGN KEY (buffer) REFERENCES Buffer(id) ON DELETE CASCADE
						)
					''');
					return batch.commit();
				},
				onUpgrade: (db, prevVersion, newVersion) {
					print('Upgrading database from version $prevVersion to version $newVersion');

					var batch = db.batch();
					// TODO: add upgrades here
					// if (prevVersion <= 1) /* upgrade to v2 */
					return batch.commit();
				},
				onDowngrade: (_, prevVersion, newVersion) {
					throw Exception('Attempted to downgrade database from version $prevVersion to version $newVersion');
				},
				version: 1,
			);
		}).then((db) {
			return DB._(db);
		});
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

	Future<int> _updateById(String table, Map<String, Object?> values) {
		int id = values['id']! as int;
		values.remove('id');
		return _db.update(
			table,
			values,
			where: 'id = ?',
			whereArgs: [id],
		);
	}

	Future<List<ServerEntry>> listServers() {
		return _db.rawQuery('''
			SELECT id, host, port, tls, nick, pass, sasl_plain_password
			FROM Server ORDER BY id
		''').then((entries) => entries.map((m) => ServerEntry.fromMap(m)).toList());
	}

	Future<ServerEntry> storeServer(ServerEntry entry) {
		if (entry.id == null) {
			return _db.insert('Server', entry.toMap()).then((id) {
				entry.id = id;
				return entry;
			});
		} else {
			return _updateById('Server', entry.toMap()).then((_) => entry);
		}
	}

	Future<void> deleteServer(int id) {
		return _db.rawDelete('DELETE FROM Server WHERE id = ?', [id]);
	}

	Future<List<NetworkEntry>> listNetworks() {
		return _db.rawQuery('''
			SELECT id, server, bouncer_id FROM Network ORDER BY id
		''').then((entries) => entries.map((m) => NetworkEntry.fromMap(m)).toList());
	}

	Future<NetworkEntry> storeNetwork(NetworkEntry entry) {
		if (entry.id == null) {
			return _db.insert('Network', entry.toMap()).then((id) {
				entry.id = id;
				return entry;
			});
		} else {
			return _updateById('Network', entry.toMap()).then((_) => entry);
		}
	}

	Future<void> deleteNetwork(int id) {
		// TODO: garbage collect orphan servers
		return _db.rawDelete('DELETE FROM Network WHERE id = ?', [id]);
	}

	Future<List<BufferEntry>> listBuffers() {
		return _db.rawQuery('''
			SELECT id, name, network, last_read_time FROM Buffer ORDER BY id
		''').then((entries) => entries.map((m) => BufferEntry.fromMap(m)).toList());
	}

	Future<BufferEntry> storeBuffer(BufferEntry entry) {
		if (entry.id == null) {
			return _db.insert('Buffer', entry.toMap()).then((id) {
				entry.id = id;
				return entry;
			});
		} else {
			return _updateById('Buffer', entry.toMap()).then((_) => entry);
		}
	}

	Future<void> deleteBuffer(int id) {
		return _db.rawDelete('DELETE FROM Buffer WHERE id = ?', [id]);
	}

	Future<Map<int, int>> fetchBuffersUnreadCount() {
		return _db.rawQuery('''
			SELECT
				Message.buffer, COUNT(Message.id) AS unread_count
			FROM Message
			LEFT JOIN Buffer ON Message.buffer = Buffer.id
			WHERE Message.time > Buffer.last_read_time
			GROUP BY Message.buffer
		''').then((entries) {
			return Map<int, int>.fromIterable(
				entries,
				key: (m) => m['buffer'],
				value: (m) => m['unread_count'],
			);
		});
	}

	Future<Map<int, String>> fetchBuffersLastDeliveredTime() {
		return _db.rawQuery('''
			SELECT buffer, time
			FROM Message t1
			WHERE id IN (
				SELECT t2.id
				FROM Message t2
				WHERE t1.buffer = t2.buffer
				ORDER BY t2.time DESC LIMIT 1
			)
		''').then((entries) {
			return Map<int, String>.fromIterable(
				entries,
				key: (m) => m['buffer'],
				value: (m) => m['time'],
			);
		});
	}

	Future<List<MessageEntry>> listMessages(int buffer) {
		return _db.rawQuery('''
			SELECT id, time, buffer, raw, flags FROM Message WHERE buffer = ? ORDER BY time
		''', [buffer]).then((entries) {
			return entries.map((m) => MessageEntry.fromMap(m)).toList();
		});
	}

	Future<MessageEntry> storeMessage(MessageEntry entry) {
		if (entry.id == null) {
			return _db.insert('Message', entry.toMap()).then((id) {
				entry.id = id;
				return entry;
			});
		} else {
			return _updateById('Message', entry.toMap()).then((_) => entry);
		}
	}
}
