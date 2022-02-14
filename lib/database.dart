import 'dart:io';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ServerEntry {
	int? id;
	String host;
	int? port;
	bool tls;
	String? nick;
	String? pass;

	Map<String, Object?> toMap() {
		return <String, Object?>{
			'id': id,
			'host': host,
			'port': port,
			'tls': tls ? 1 : 0,
			'nick': nick,
			'pass': pass,
		};
	}

	ServerEntry({ required this.host, this.port, this.tls = true, this.nick, this.pass });

	ServerEntry.fromMap(Map<String, dynamic> m) :
		id = m['id'],
		host = m['host'],
		port = m['port'],
		tls = m['tls'] != 0,
		nick = m['nick'],
		pass = m['pass'];
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
				join(basePath, 'goguma', 'main.db'),
				onCreate: (db, version) {
					return db.execute('''
						CREATE TABLE Server(
							id INTEGER PRIMARY KEY,
							host TEXT NOT NULL,
							port INTEGER,
							tls INTEGER NOT NULL DEFAULT 1,
							nick TEXT,
							pass TEXT
						);

						CREATE TABLE Buffer(
							id INTEGER PRIMARY KEY,
							name TEXT NOT NULL,
							server INTEGER NOT NULL,
							FOREIGN KEY (server) REFERENCES Server(id),
							UNIQUE(name, server)
						);

						CREATE TABLE Message(
							id INTEGER PRIMARY KEY,
							time TEXT NOT NULL,
							buffer INTEGER NOT NULL,
							raw TEXT NOT NULL,
							flags INTEGER NOT NULL DEFAULT 0,
							FOREIGN KEY (buffer) REFERENCES Buffer(id)
						);
					''');
				},
				onUpgrade: (db, prevVersion, newVersion) {
					return Future.value();
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
		return Future.value(xdgDataHome);
	}

	Future<void> close() {
		return _db.close();
	}

	Future<List<ServerEntry>> listServers() {
		return _db.rawQuery('''
			SELECT id, host, port, tls, nick, pass FROM Server ORDER BY id
		''').then((entries) => entries.map((m) => ServerEntry.fromMap(m)).toList());
	}

	Future<ServerEntry> storeServer(ServerEntry entry) {
		if (entry.id == null) {
			return _db.insert('Server', entry.toMap()).then((id) {
				entry.id = id;
				return entry;
			});
		} else {
			return _db.update('Server', entry.toMap()).then((_) => entry);
		}
	}

	Future<void> deleteServer(int id) {
		return _db.rawDelete('DELETE FROM Server WHERE id = ?', [id]);
	}
}
