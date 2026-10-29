import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_catalog.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../widgets/drama_grid.dart';
import '../widgets/focus_ring.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.store,
    required this.source,
    this.query = '',
  });
  final LocalStore store;
  final SourceSite source;
  final String query;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _controller = TextEditingController(text: widget.query);
  final _focus = FocusNode();
  late AppRepository _repository;
  final Map<String, DramaFeed> _results = {};
  List<SourceSite> _sources = [];
  String _submitted = '';
  List<String> _suggestions = const [];
  Timer? _debounce;
  int _suggestion = 0;
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _sources = widget.store.searchSources(widget.source.id);
    if (widget.query.trim().isNotEmpty) _submit(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestion++;
    unawaited(_repository.cancelSuggestions());
    for (final feed in _results.values) {
      feed.dispose();
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    _controller.text = query;
    _focus.unfocus();
    _debounce?.cancel();
    _suggestion++;
    unawaited(widget.store.rememberSearch(query).catchError((Object _) {}));
    for (final feed in _results.values) {
      feed.dispose();
    }
    _results.clear();
    for (final source in _sources) {
      if (!widget.store.allowsSource(source.id)) continue;
      final catalog = SourceCatalog(_repository, source);
      final feed = DramaFeed(
        load: (page, _) => catalog.search(query, page: page),
      )..addListener(_refresh);
      _results[source.id] = feed;
      unawaited(feed.reload());
    }
    setState(() {
      _submitted = query;
      _suggestions = const [];
    });
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    final generation = ++_suggestion;
    if (!(_sources.length == 1 && _sources.single.searchSuggestions) || query.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await _repository.suggestions(query);
        if (mounted && generation == _suggestion) {
          setState(() => _suggestions = items);
        }
      } catch (_) {}
    });
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) {
    final field = SearchField(
      hint: '搜索已选的 ${_sources.length} 个站源',
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.query.isEmpty,
      onChanged: _changed,
      onSubmitted: _submit,
    );
    if (AppScope.of(context).television) {
      return Scaffold(
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                televisionInset,
                27,
                televisionInset,
                0,
              ),
              child: field,
            ),
            _sourceSelector(),
            Expanded(child: _body(context)),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(padding: const EdgeInsets.only(right: 16), child: field),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(children: [
          _sourceSelector(),
          Expanded(child: _body(context)),
        ]),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final television = AppScope.of(context).television;
    if (_suggestions.isNotEmpty && _controller.text.trim() != _submitted) {
      return ListView(
        padding: television
            ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
            : const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final item in _suggestions)
            TileFocus(
              builder: (focusNode) => ListTile(
                focusNode: focusNode,
                leading: const Icon(Icons.search_rounded),
                title: Text(item),
                onTap: () => _submit(item),
              ),
            ),
        ],
      );
    }
    if (_submitted.isEmpty) return _recent(context);
    if (_results.isEmpty) {
      return const StatusView(
        title: '请选择搜索站源',
        message: '点击上方站源按钮，选择要搜索的站源',
        icon: Icons.manage_search_rounded,
      );
    }
    final inset = television ? televisionInset : 16.0;
    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        slivers: [
          for (final source in _sources)
            if (_results[source.id] case final feed?) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(inset, 16, inset, 8),
                  child: Text(
                    '${source.name} · ${feed.items.length} 个结果${source.onlineSearch ? '' : '（本地缓存）'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              if (feed.loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (feed.items.isEmpty && feed.error.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: inset, vertical: 12),
                    child: const Text('没有找到相关结果'),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: DramaSliverGrid(
                  width: constraints.maxWidth - inset * 2,
                  items: feed.items,
                  onOpen: _open,
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 8, inset, 16),
                sliver: SliverToBoxAdapter(
                  child: Column(children: [
                    if (feed.canLoadMore)
                      TextButton(
                        onPressed: feed.loadMore,
                        child: Text('加载更多${source.name}结果'),
                      ),
                    if (!feed.loading) FeedFooter(feed: feed),
                  ]),
                ),
              ),
            ],
        ],
      ),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Widget _sourceSelector() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(children: [
      Expanded(
        child: Text(
          _sources.isEmpty
              ? '尚未选择站源'
              : _sources.map((site) => site.name).join('、'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      TextButton.icon(
        onPressed: _pickSources,
        icon: const Icon(Icons.tune_rounded),
        label: const Text('选择站源'),
      ),
    ]),
  );

  Future<void> _pickSources() async {
    final selected = _sources.map((site) => site.id).toSet();
    final available = widget.store.sources;
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('选择搜索站源'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final source in available)
                    CheckboxListTile(
                      title: Text(source.name),
                      subtitle: Text(source.onlineSearch ? '在线搜索' : '搜索本地已缓存内容'),
                      value: selected.contains(source.id),
                      onChanged: (checked) => update(() {
                        if (checked == true) {
                          selected.add(source.id);
                        } else {
                          selected.remove(source.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: selected.isEmpty ? null : () => Navigator.pop(context, selected),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await widget.store.setSearchSources(result);
      if (!mounted) return;
      setState(() => _sources = widget.store.sources.where((site) => result.contains(site.id)).toList());
      _changed(_controller.text);
      if (_submitted.isNotEmpty) _submit(_controller.text);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('搜索站源未能保存，请重试')),
        );
      }
    }
  }

  Widget _recent(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final recent = widget.store.recentSearches;
      if (recent.isEmpty) {
        return StatusView(
          title: '搜索已选的 ${_sources.length} 个站源',
          message: '输入剧名或关键词',
          icon: Icons.search_rounded,
        );
      }
      final theme = Theme.of(context);
      return ListView(
        padding: AppScope.of(context).television
            ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
            : const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '最近搜索',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              FocusRing(
                radius: 999,
                child: TextButton(
                  onPressed: () => widget.store
                      .clearRecentSearches()
                      .catchError((Object _) {}),
                  child: const Text('清空'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in recent)
                FocusRing(
                  radius: 8,
                  child: ActionChip(
                    avatar: const Icon(Icons.history_rounded, size: 16),
                    label: Text(query),
                    onPressed: () => _submit(query),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}
