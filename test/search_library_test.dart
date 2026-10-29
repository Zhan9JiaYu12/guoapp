import 'dart:convert';
import 'dart:async';

import 'package:duanju_app/search_library.dart';
import 'package:duanju_app/search_library_updater.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

class ScanRepository extends FakeRepository {
  final requests = <int>[];
  final started = Completer<void>();
  final responseReady = Completer<void>();
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [];

  @override
  Future<CatalogPage> scanCatalog(
    String source, {
    int page = 1,
    String category = '',
  }) async {
    requests.add(page);
    if (!started.isCompleted) started.complete();
    await responseReady.future;
    return CatalogPage(
      [drama('$page', source: source)],
      page: page,
      hasMore: page < 3,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'legacy index migrates once and batches merge without losing records',
    () async {
      final old = drama('1', source: 'huangdou', title: '旧剧');
      SharedPreferences.setMockInitialValues({
        'searchLibrary.v1.huangdou': jsonEncode([old.toJson()]),
      });
      final preferences = await SharedPreferences.getInstance();
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: SearchLibrary.createSchema,
        ),
      );
      addTearDown(db.close);
      final library = SearchLibrary(preferences, database: db);
      expect((await library.stats('huangdou')).count, 1);
      final checkpoint = {
        'page': 3,
        'categories': [''],
        'categoryIndex': 0,
      };
      expect(
        await library.saveBatch('huangdou', [
          drama('1', source: 'huangdou', title: '新剧名'),
          drama('2', source: 'huangdou', title: '另一个剧'),
        ], checkpoint),
        1,
      );
      expect((await library.stats('huangdou')).count, 2);
      expect((await library.search('huangdou', '新剧名')).single.id, old.id);
      expect(await library.search('huangdou', '旧剧'), isEmpty);
      expect((await library.checkpoint('huangdou'))!['page'], 3);
      final reopened = SearchLibrary(preferences, database: db);
      expect((await reopened.stats('huangdou')).count, 2);
      // A quick refresh must not overwrite the full-scan checkpoint.
      await reopened.saveBatch('huangdou', [
        drama('3', source: 'huangdou'),
      ], null);
      expect((await reopened.checkpoint('huangdou'))!['page'], 3);
      await reopened.markUpdated('huangdou');
      expect(await reopened.checkpoint('huangdou'), isNull);
      expect((await reopened.stats('huangdou')).updated, isNotNull);
      await reopened.clear('huangdou');
      expect((await reopened.stats('huangdou')).count, 0);
    },
  );

  test('batch and checkpoint roll back together on database failure', () async {
    SharedPreferences.setMockInitialValues({});
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: SearchLibrary.createSchema,
      ),
    );
    addTearDown(db.close);
    final library = SearchLibrary(
      await SharedPreferences.getInstance(),
      database: db,
    );
    await library.saveBatch(
      'huangdou',
      [drama('1', source: 'huangdou')],
      {'page': 2},
    );
    await db.execute(
      "CREATE TRIGGER fail_insert BEFORE INSERT ON dramas WHEN NEW.id='huangdou:2' BEGIN SELECT RAISE(ABORT, 'fixture'); END",
    );
    await expectLater(
      library.saveBatch(
        'huangdou',
        [drama('2', source: 'huangdou')],
        {'page': 3},
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect((await library.stats('huangdou')).count, 1);
    expect((await library.checkpoint('huangdou'))!['page'], 2);
  });

  test(
    'updater survives page reattachment, pauses and resumes at checkpoint',
    () async {
      final store = await openStore();
      await store.setSourceEnabled('huangdou', true);
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: SearchLibrary.createSchema,
        ),
      );
      addTearDown(db.close);
      final library = SearchLibrary(store.preferences, database: db);
      final repository = ScanRepository();
      final updater = SearchLibraryUpdater.obtain(
        repository,
        store,
        library: library,
      );
      addTearDown(updater.dispose);
      final task = updater.start({'huangdou'});
      await repository.started.future;
      expect(SearchLibraryUpdater.obtain(repository, store), same(updater));
      updater.didChangeAppLifecycleState(AppLifecycleState.paused);
      repository.responseReady.complete();
      // Current batch can persist, but page 3 must wait for foreground.
      for (var attempts = 0; attempts < 100; attempts++) {
        if ((await library.checkpoint('huangdou'))?['page'] == 3) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(repository.requests, [1, 2]);
      expect((await library.checkpoint('huangdou'))!['page'], 3);
      updater.stop();
      await task;
      updater.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await updater.start({'huangdou'});
      expect(repository.requests, [1, 2, 3, 4]);
      expect((await library.stats('huangdou')).count, 3);
      expect(await library.checkpoint('huangdou'), isNull);
    },
  );
}
