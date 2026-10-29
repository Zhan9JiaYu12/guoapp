import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../search_library.dart';
import '../../search_library_updater.dart';
import '../app_scope.dart';

class SearchLibraryPage extends StatefulWidget {
  const SearchLibraryPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<SearchLibraryPage> createState() => _SearchLibraryPageState();
}

class _SearchLibraryPageState extends State<SearchLibraryPage> {
  late SearchLibraryUpdater _updater;
  final _selected = <String>{};
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _updater = SearchLibraryUpdater.obtain(
      AppScope.of(context).repository,
      widget.store,
    );
    _selected.addAll(
      widget.store.sources
          .where((site) => SearchLibrary.sources.contains(site.id))
          .map((site) => site.id),
    );
    _updater.loadStats();
  }

  Future<void> _clear(SourceSite source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清理${source.name}搜索索引？'),
        content: const Text('之后可重新更新索引。发现页已有的浏览缓存仍可能出现在搜索结果中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _updater.clear(source.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_updater, widget.store]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final sources = widget.store.sources
        .where((site) => SearchLibrary.sources.contains(site.id))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('搜索剧库缓存')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '只缓存剧目资料，不下载视频或封面图片。首次扫描可获取的目录；以后按剧目 ID 合并新增和更新资料，保留旧记录。接口未开放的内容无法收录。',
          ),
          const SizedBox(height: 16),
          for (final source in sources)
            Card(
              child: Column(
                children: [
                  CheckboxListTile(
                    title: Text(source.name),
                    value: _selected.contains(source.id),
                    onChanged: _updater.running
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              _selected.add(source.id);
                            } else {
                              _selected.remove(source.id);
                            }
                          }),
                    subtitle: Text(_status(source)),
                  ),
                  if (_updater.messages[source.id] case final message?)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(message),
                    ),
                  TextButton(
                    onPressed: _updater.running ? null : () => _clear(source),
                    child: const Text('清理搜索索引'),
                  ),
                ],
              ),
            ),
          if (sources.isEmpty) const Text('请先在站源设置中启用黄豆或黄果站源'),
          if (_updater.running) ...[
            const LinearProgressIndicator(),
            Text(_updater.paused ? '已暂停发起新请求，回到前台继续' : '更新中，可以离开此页面'),
            TextButton(
              onPressed: _updater.stopping ? null : _updater.stop,
              child: Text(_updater.stopping ? '正在保存当前进度' : '停止更新'),
            ),
          ] else ...[
            FilledButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => _updater.start(_selected, quick: true),
              child: const Text('快速更新（各目录前 3 页）'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => _updater.start(_selected),
              child: const Text('完整扫描 / 从断点继续'),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            '无需停留此页面，App 内切换页面时继续更新。切到其他 App 或锁屏后暂停新请求，返回前台继续。完整扫描中断后会从已保存断点继续；快速更新可能遗漏旧目录中的内容，可用完整扫描补漏。',
          ),
        ],
      ),
    );
  }

  String _status(SourceSite source) {
    final stats = _updater.statistics[source.id];
    if (stats == null) return '正在读取索引信息';
    final time = stats.updated?.toLocal().toString().split('.').first;
    return '已缓存 ${stats.count} 部\n${time == null ? '尚未完成目录扫描' : '上次完整扫描：$time'}';
  }
}
