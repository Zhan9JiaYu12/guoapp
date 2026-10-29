import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class SearchLibraryStats {
  const SearchLibraryStats(this.count, this.updated);
  final int count;
  final DateTime? updated;
}

/// Shared metadata index. Each successful batch and checkpoint commit atomically.
class SearchLibrary {
  SearchLibrary(this.preferences, {Database? database}) : _injected = database;
  final SharedPreferences preferences;
  final Database? _injected;
  static Future<Database>? _opening;
  static const sources = {
    'huangdou', 'huangguo-video', 'huangguoai', 'cloudfront',
  };

  Future<Database> get _db async {
    if (_injected case final database?) return database;
    return _opening ??= _open().catchError((Object error) {
      _opening = null;
      throw error;
    });
  }

  static Future<Database> _open() async => openDatabase(
    path.join(await getDatabasesPath(), 'search_library_v2.db'),
    version: 1,
    onConfigure: (db) async { await db.execute('PRAGMA journal_mode=WAL'); },
    onCreate: createSchema,
  );

  static Future<void> createSchema(Database db, int version) async {
    await db.execute('CREATE TABLE dramas (source TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, search_text TEXT NOT NULL, PRIMARY KEY(source,id))');
    await db.execute('CREATE TABLE metadata (source TEXT PRIMARY KEY, migrated INTEGER NOT NULL DEFAULT 0, updated TEXT, checkpoint TEXT)');
  }

  Future<void> _migrate(String source) async {
    if (!sources.contains(source)) throw ArgumentError('无效的索引站源');
    final db = await _db;
    await db.transaction((txn) async {
      final state = await txn.query('metadata', where: 'source=?', whereArgs: [source]);
      if (state.isNotEmpty && state.single['migrated'] == 1) return;
      final raw = preferences.getString('searchLibrary.v1.$source');
      final items = raw == null ? <Drama>[] : (jsonDecode(raw) as List)
          .map((row) => Drama.fromJson(Map<String, dynamic>.from(row as Map)))
          .where((item) => item.source == source).toList();
      // Keep the original preference data until migration has committed.
      for (var offset = 0; offset < items.length; offset += 100) {
        await _upsert(txn, source, items.skip(offset).take(100));
      }
      await txn.insert('metadata', {
        'source': source, 'migrated': 1,
        'updated': preferences.getString('searchLibrary.v1.$source.updated'),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static Future<int> _upsert(Transaction txn, String source, Iterable<Drama> values) async {
    final incoming = {for (final item in values) if (item.source == source) item.id: item};
    if (incoming.isEmpty) return 0;
    final ids = incoming.keys.toList();
    final previous = await txn.query('dramas',
      where: 'source=? AND id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [source, ...ids]);
    final old = {for (final row in previous) row['id'] as String:
      Drama.fromJson(Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map))};
    final batch = txn.batch();
    for (final item in incoming.values) {
      final merged = old[item.id]?.merge(item) ?? item;
      batch.insert('dramas', {
        'source': source, 'id': item.id, 'data': jsonEncode(merged.toJson()),
        'search_text': '${merged.title} ${merged.description} ${merged.tags.join(' ')}'.toLowerCase(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    return incoming.length - old.length;
  }

  Future<int> saveBatch(String source, Iterable<Drama> items, Map<String, dynamic>? checkpoint) async {
    await _migrate(source);
    final values = items.toList();
    final db = await _db;
    return db.transaction((txn) async {
      var added = 0;
      for (var offset = 0; offset < values.length; offset += 100) {
        added += await _upsert(txn, source, values.skip(offset).take(100));
      }
      if (checkpoint != null) {
        await txn.update('metadata', {'checkpoint': jsonEncode(checkpoint)},
          where: 'source=?', whereArgs: [source]);
      }
      return added;
    });
  }

  Future<Map<String, dynamic>?> checkpoint(String source) async {
    await _migrate(source);
    final rows = await (await _db).query('metadata', where: 'source=?', whereArgs: [source]);
    final raw = rows.single['checkpoint'] as String?;
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<SearchLibraryStats> stats(String source) async {
    await _migrate(source);
    final db = await _db;
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM dramas WHERE source=?', [source])) ?? 0;
    final rows = await db.query('metadata', where: 'source=?', whereArgs: [source]);
    return SearchLibraryStats(count, DateTime.tryParse(rows.single['updated'] as String? ?? ''));
  }

  Future<void> markUpdated(String source) async {
    await _migrate(source);
    await (await _db).update('metadata', {
      'updated': DateTime.now().toIso8601String(), 'checkpoint': null,
    }, where: 'source=?', whereArgs: [source]);
  }

  Future<void> clear(String source) async {
    await _migrate(source);
    await (await _db).transaction((txn) async {
      await txn.delete('dramas', where: 'source=?', whereArgs: [source]);
      await txn.update('metadata', {'updated': null, 'checkpoint': null}, where: 'source=?', whereArgs: [source]);
    });
    await preferences.remove('searchLibrary.v1.$source');
    await preferences.remove('searchLibrary.v1.$source.updated');
  }

  Future<List<Drama>> search(String source, String query) async {
    await _migrate(source);
    final words = query.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final rows = await (await _db).query('dramas', columns: ['data'],
      where: ['source=?', for (final _ in words) 'instr(search_text, ?) > 0'].join(' AND '),
      whereArgs: [source, ...words], orderBy: 'id');
    return rows.map((row) => Drama.fromJson(Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map))).toList();
  }
}
