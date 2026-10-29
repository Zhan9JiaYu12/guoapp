import 'dart:async';

import 'package:flutter/widgets.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'search_library.dart';

class SearchLibraryUpdater extends ChangeNotifier with WidgetsBindingObserver {
  SearchLibraryUpdater._(this.repository, this.store, SearchLibrary? index)
      : library = index ?? SearchLibrary(store.preferences) {
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_accessChanged);
  }

  static SearchLibraryUpdater? _current;
  static void releaseStore(LocalStore store) {
    final current = _current;
    if (current != null && identical(current.store, store)) {
      if (!current._disposed) current.dispose();
      _current = null;
    }
  }
  static SearchLibraryUpdater obtain(AppRepository repository, LocalStore store, {SearchLibrary? library}) {
    final current = _current;
    if (current != null && !current._disposed && identical(current.store, store)) {
      return current;
    }
    if (current != null && !current._disposed) current.dispose();
    return _current = SearchLibraryUpdater._(repository, store, library);
  }

  final AppRepository repository;
  final LocalStore store;
  final SearchLibrary library;
  final messages = <String, String>{};
  final statistics = <String, SearchLibraryStats>{};
  bool running = false;
  bool stopping = false;
  bool paused = false;
  bool _disposed = false;
  int _epoch = 0;
  Timer? _refresh;
  Completer<void>? _foreground;

  void _notify({bool immediate = false}) {
    if (_disposed) return;
    if (immediate) {
      _refresh?.cancel();
      _refresh = null;
      notifyListeners();
    } else {
      _refresh ??= Timer(const Duration(milliseconds: 500), () {
        _refresh = null;
        if (!_disposed) notifyListeners();
      });
    }
  }

  Future<void> loadStats() async {
    for (final source in store.sources) {
      if (!SearchLibrary.sources.contains(source.id)) continue;
      try { statistics[source.id] = await library.stats(source.id); }
      catch (error) { messages[source.id] = '索引读取失败：$error'; }
    }
    _notify(immediate: true);
  }

  void _accessChanged() {
    if (running && (store.profileEpoch != _epoch || store.locked)) stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      paused = true;
      _foreground ??= Completer<void>();
    } else if (state == AppLifecycleState.resumed) {
      paused = false;
      _foreground?.complete();
      _foreground = null;
    }
    _notify(immediate: true);
  }

  void stop() {
    stopping = true;
    _foreground?.complete();
    _foreground = null;
    _notify(immediate: true);
  }

  bool _allowed(String source) => !_disposed && !stopping &&
      store.profileEpoch == _epoch && store.allowsSource(source);

  Future<bool> _ready(String source) async {
    if (!_allowed(source)) return false;
    if (paused) {
      _foreground ??= Completer<void>();
      await _foreground!.future;
    }
    return _allowed(source);
  }

  Future<void> start(Set<String> sources, {bool quick = false}) async {
    if (running || _disposed) return;
    final pending = store.sources.where((site) =>
      sources.contains(site.id) && SearchLibrary.sources.contains(site.id)).toList();
    if (pending.isEmpty) return;
    running = true;
    stopping = false;
    _epoch = store.profileEpoch;
    _notify(immediate: true);
    var next = 0;
    Future<void> worker() async {
      while (!stopping && !_disposed && next < pending.length) {
        final source = pending[next++];
        await _scan(source, quick: quick);
      }
    }
    try {
      // At most two sources, two pages per source; native limiter remains active.
      await Future.wait([worker(), worker()]);
    } finally {
      running = false;
      _notify(immediate: true);
    }
  }

  Future<({CatalogPage? result, Object? error})> _fetch(String source, String category, int page) async {
    try {
      return (result: await repository.scanCatalog(source, category: category, page: page), error: null);
    } catch (error) { return (result: null, error: error); }
  }

  Future<void> _scan(SourceSite source, {required bool quick}) async {
    var added = 0;
    var parallel = 2;
    try {
      final checkpoint = quick ? null : await library.checkpoint(source.id);
      List<String> categories;
      if (checkpoint != null) {
        categories = (checkpoint['categories'] as List).cast<String>();
      } else {
        if (!await _ready(source.id)) return;
        messages[source.id] = '正在获取分类';
        _notify();
        // A category failure leaves the run incomplete; don't mark it complete.
        final remote = await repository.categories(source.id, force: true);
        categories = <String>{'', ...remote.where((item) => !item.local).map((item) => item.id)}.toList();
      }
      var categoryIndex = checkpoint?['categoryIndex'] as int? ?? 0;
      var page = checkpoint?['page'] as int? ?? 1;
      String? lastSignature = checkpoint?['signature'] as String?;
      for (; categoryIndex < categories.length; categoryIndex++) {
        final category = categories[categoryIndex];
        while (await _ready(source.id)) {
          if (page > 10000) throw StateError('分页超过上限，已保留断点');
          messages[source.id] = '${quick ? '快速更新' : '目录扫描'} ${categoryIndex + 1}/${categories.length} · 第 $page 页 · 本次新增 $added 部';
          _notify();
          final width = quick ? (4 - page).clamp(1, parallel) : parallel;
          final results = await Future.wait([
            for (var offset = 0; offset < width; offset++)
              _fetch(source.id, category, page + offset),
          ]);
          final buffer = <Drama>[];
          var nextPage = page;
          bool ended = false;
          Object? failure;
          for (final response in results) {
            if (response.error != null) { failure = response.error; break; }
            final result = response.result!;
            if (result.page != nextPage) {
              failure = StateError('站源返回页码与请求不符'); break;
            }
            final signature = result.items.map((item) => item.id).join('|');
            if (result.hasMore && (signature.isEmpty || signature == lastSignature)) {
              failure = StateError('站源重复返回目录或空页'); break;
            }
            buffer.addAll(result.items);
            if (result.warning.isNotEmpty) { failure = StateError(result.warning); break; }
            lastSignature = signature;
            nextPage++;
            if (!result.hasMore) { ended = true; break; }
          }
          // Persist the batch even on stop/background; never advance beyond a failed page.
          final state = {
            'categories': categories,
            'categoryIndex': ended ? categoryIndex + 1 : categoryIndex,
            'page': ended ? 1 : nextPage,
            'signature': ended ? null : lastSignature,
          };
          if (_disposed || store.profileEpoch != _epoch) return;
          added += await library.saveBatch(source.id, buffer, quick ? null : state);
          statistics[source.id] = await library.stats(source.id);
          _notify();
          page = nextPage;
          if (failure != null) {
            if (parallel > 1 && _allowed(source.id)) {
              parallel = 1;
              messages[source.id] = '请求失败，降为单页重试';
              _notify();
              await Future<void>.delayed(const Duration(seconds: 2));
              continue;
            }
            throw failure;
          }
          if (ended || (quick && page > 3)) break;
        }
        if (!_allowed(source.id)) break;
        page = 1;
        lastSignature = null;
      }
      if (!_allowed(source.id)) {
        messages[source.id] = '已停止，完整扫描可从断点继续';
      } else if (quick) {
        messages[source.id] = '快速更新完成，新增 $added 部；仅扫描各目录前 3 页，完整扫描可补漏';
      } else {
        await library.markUpdated(source.id);
        messages[source.id] = '目录扫描完成，新增 $added 部';
      }
      statistics[source.id] = await library.stats(source.id);
    } catch (error) {
      messages[source.id] = '未完成，缓存和断点已保留：$error';
    }
    _notify(immediate: true);
  }

  Future<void> clear(String source) async {
    if (running) return;
    await library.clear(source);
    statistics[source] = await library.stats(source);
    messages[source] = '搜索索引已清理';
    _notify(immediate: true);
  }

  @override
  void dispose() {
    stopping = true;
    _disposed = true;
    _foreground?.complete();
    _foreground = null;
    _refresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_accessChanged);
    super.dispose();
  }
}
