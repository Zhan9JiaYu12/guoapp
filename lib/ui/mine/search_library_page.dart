import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../search_library.dart';
import '../app_scope.dart';

class SearchLibraryPage extends StatefulWidget {
  const SearchLibraryPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<SearchLibraryPage> createState() => _SearchLibraryPageState();
}

class _SearchLibraryPageState extends State<SearchLibraryPage> {
  late final _library = SearchLibrary(widget.store.preferences);
  final _selected = <String>{};
  final _messages = <String, String>{};
  bool _running = false;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.store.sources
        .where((site) => SearchLibrary.sources.contains(site.id))
        .map((site) => site.id));
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  void _message(String source, String message) {
    if (mounted) setState(() => _messages[source] = message);
  }

  Future<void> _update() async {
    final repository = AppScope.of(context).repository;
    final epoch = widget.store.profileEpoch;
    final selected = widget.store.sources
        .where((site) => _selected.contains(site.id)).toList();
    setState(() { _running = true; _cancel = false; });
    for (final source in selected) {
      bool allowed() => mounted && !_cancel &&
          epoch == widget.store.profileEpoch && widget.store.allowsSource(source.id);
      if (!allowed()) break;
      try {
        final items = {for (final item in _library.read(source.id)) item.id: item};
        final before = items.keys.toSet();
        final categories = <String>{''};
        String categoryWarning = '';
        _message(source.id, '正在获取分类');
        try {
          categories.addAll((await repository.categories(source.id, force: true))
              .where((category) => !category.local).map((category) => category.id));
        } catch (_) {
          categoryWarning = '分类获取失败，仅扫描全部目录；请重试以补齐分类';
        }
        for (final category in categories) {
          final seenPages = <String>{};
          for (var page = 1; ; page++) {
            if (!allowed()) break;
            if (page > 10000) throw StateError('分页超过上限，未确认扫描完成');
            _message(source.id, '分类 ${categories.toList().indexOf(category) + 1}/${categories.length} · 第 $page 页 · ${items.length} 部');
            final result = await repository.catalog(
              source.id, category: category, page: page, force: true,
            );
            if (!allowed()) break;
            for (final item in result.items) {
              if (item.source == source.id) {
                items[item.id] = items[item.id]?.merge(item) ?? item;
              }
            }
            // Save each successful page, so cancellation/errors retain progress.
            await _library.save(source.id, items.values);
            if (result.warning.isNotEmpty) throw StateError(result.warning);
            final signature = result.items.map((item) => item.id).join('|');
            if (result.hasMore &&
                (signature.isEmpty || !seenPages.add(signature))) {
              throw StateError('站源重复返回目录或空页，已暂停，请稍后重试');
            }
            if (!result.hasMore) break;
          }
          if (!allowed()) break;
        }
        if (!allowed()) {
          _message(source.id, '已停止，已保存的目录可用于搜索');
          break;
        }
        final added = items.keys.where((id) => !before.contains(id)).length;
        if (categoryWarning.isEmpty) await _library.markUpdated(source.id);
        _message(source.id, '共 ${items.length} 部，新增 $added 部。${categoryWarning.isEmpty ? '已扫描当前接口可访问目录' : categoryWarning}');
      } catch (error) {
        _message(source.id, '更新未完成，已保留缓存：$error');
      }
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _clear(SourceSite source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清理${source.name}搜索索引？'),
        content: const Text('之后可重新更新索引。发现页已有的浏览缓存仍可能出现在搜索结果中。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('清理')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _library.clear(source.id);
      _message(source.id, '搜索索引已清理');
    } catch (error) { _message(source.id, '$error'); }
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.store.sources
        .where((site) => SearchLibrary.sources.contains(site.id)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('搜索剧库缓存')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('只缓存剧目资料，不下载视频或封面图片。首次扫描可获取的目录；以后按剧目 ID 合并新增和更新资料，保留旧记录。接口未开放的内容无法收录。'),
        const SizedBox(height: 16),
        for (final source in sources) Card(
          child: Column(children: [
            CheckboxListTile(
              title: Text(source.name),
              value: _selected.contains(source.id),
              onChanged: _running ? null : (value) => setState(() {
                if (value == true) { _selected.add(source.id); }
                else { _selected.remove(source.id); }
              }),
              subtitle: Text(_status(source)),
            ),
            if (_messages[source.id] case final message?)
              Padding(padding: const EdgeInsets.all(12), child: Text(message)),
            TextButton(onPressed: _running ? null : () => _clear(source), child: const Text('清理搜索索引')),
          ]),
        ),
        if (sources.isEmpty) const Text('请先在站源设置中启用黄豆或黄果站源'),
        if (_running) ...[
          const LinearProgressIndicator(),
          TextButton(
            onPressed: _cancel ? null : () => setState(() => _cancel = true),
            child: Text(_cancel ? '正在等待当前请求结束' : '停止更新'),
          ),
        ] else FilledButton(
          onPressed: _selected.any((id) => sources.any((site) => site.id == id)) ? _update : null,
          child: const Text('缓存 / 增量更新所选站源'),
        ),
        const SizedBox(height: 12),
        const Text('更新时请保持此页面和 App 在前台。离开页面会停止后续请求；再次更新会从首页重新扫描并合并，不会清空已有索引。'),
      ]),
    );
  }

  String _status(SourceSite source) {
    try {
      final count = _library.read(source.id).length;
      final time = _library.updated(source.id)?.toLocal().toString().split('.').first;
      return '已缓存 $count 部\n${time == null ? '尚未完成目录更新' : '上次完成：$time'}';
    } catch (_) { return '索引读取失败，请清理后重新缓存'; }
  }
}
