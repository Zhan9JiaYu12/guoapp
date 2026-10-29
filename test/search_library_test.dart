import 'dart:convert';

import 'package:duanju_app/search_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('legacy index migrates once and batches merge without losing records', () async {
    final old = drama('1', source: 'huangdou', title: '旧剧');
    SharedPreferences.setMockInitialValues({
      'searchLibrary.v1.huangdou': jsonEncode([old.toJson()]),
    });
    final preferences = await SharedPreferences.getInstance();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: SearchLibrary.createSchema));
    addTearDown(db.close);
    final library = SearchLibrary(preferences, database: db);
    expect((await library.stats('huangdou')).count, 1);
    final checkpoint = {'page': 3, 'categories': [''], 'categoryIndex': 0};
    expect(await library.saveBatch('huangdou', [
      drama('1', source: 'huangdou', title: '新剧名'),
      drama('2', source: 'huangdou', title: '另一个剧'),
    ], checkpoint), 1);
    expect((await library.stats('huangdou')).count, 2);
    expect((await library.search('huangdou', '新剧名')).single.id, old.id);
    expect(await library.search('huangdou', '旧剧'), isEmpty);
    expect((await library.checkpoint('huangdou'))!['page'], 3);
    final reopened = SearchLibrary(preferences, database: db);
    expect((await reopened.stats('huangdou')).count, 2);
    // A quick refresh must not overwrite the full-scan checkpoint.
    await reopened.saveBatch('huangdou', [drama('3', source: 'huangdou')], null);
    expect((await reopened.checkpoint('huangdou'))!['page'], 3);
    await reopened.markUpdated('huangdou');
    expect(await reopened.checkpoint('huangdou'), isNull);
    expect((await reopened.stats('huangdou')).updated, isNotNull);
    await reopened.clear('huangdou');
    expect((await reopened.stats('huangdou')).count, 0);
  });

  test('batch and checkpoint roll back together on database failure', () async {
    SharedPreferences.setMockInitialValues({});
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: SearchLibrary.createSchema));
    addTearDown(db.close);
    final library = SearchLibrary(await SharedPreferences.getInstance(), database: db);
    await library.saveBatch('huangdou', [drama('1', source: 'huangdou')], {'page': 2});
    await db.execute("CREATE TRIGGER fail_insert BEFORE INSERT ON dramas WHEN NEW.id='huangdou:2' BEGIN SELECT RAISE(ABORT, 'fixture'); END");
    await expectLater(library.saveBatch('huangdou', [drama('2', source: 'huangdou')], {'page': 3}), throwsA(isA<DatabaseException>()));
    expect((await library.stats('huangdou')).count, 1);
    expect((await library.checkpoint('huangdou'))!['page'], 2);
  });
}
