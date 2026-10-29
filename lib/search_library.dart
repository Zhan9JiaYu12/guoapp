import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// A separate metadata index: browsing-cache eviction must not remove search data.
class SearchLibrary {
  SearchLibrary(this.preferences);
  final SharedPreferences preferences;
  static const sources = {
    'huangdou', 'huangguo-video', 'huangguoai', 'cloudfront',
  };

  String _key(String source) => 'searchLibrary.v1.$source';

  List<Drama> read(String source) {
    final raw = preferences.getString(_key(source));
    if (raw == null) return [];
    final rows = jsonDecode(raw) as List;
    return rows.map((row) => Drama.fromJson(
      Map<String, dynamic>.from(row as Map),
    )).where((drama) => drama.source == source).toList();
  }

  DateTime? updated(String source) => DateTime.tryParse(
    preferences.getString('${_key(source)}.updated') ?? '',
  );

  Future<void> save(String source, Iterable<Drama> items) async {
    final content = jsonEncode(items.map((item) => item.toJson()).toList());
    if (utf8.encode(content).length > 32 * 1024 * 1024) {
      throw StateError('索引超过 32 MB，已保留上一次保存的数据');
    }
    if (!await preferences.setString(_key(source), content)) {
      throw StateError('搜索索引保存失败');
    }
  }

  Future<void> markUpdated(String source) async {
    if (!await preferences.setString(
      '${_key(source)}.updated', DateTime.now().toIso8601String(),
    )) throw StateError('更新时间保存失败');
  }

  Future<void> clear(String source) async {
    if (!await preferences.remove(_key(source))) {
      throw StateError('清理索引失败');
    }
    await preferences.remove('${_key(source)}.updated');
  }

  List<Drama> search(String source, String query) {
    final words = query.toLowerCase().trim().split(RegExp(r'\s+'));
    return read(source).where((drama) {
      final text = '${drama.title} ${drama.description} ${drama.tags.join(' ')}'
          .toLowerCase();
      return words.every(text.contains);
    }).toList();
  }
}
