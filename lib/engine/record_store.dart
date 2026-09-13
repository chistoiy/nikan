import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一条下载记录。
class RecEntry {
  RecEntry({
    required this.name,
    required this.size,
    this.variant = 'original',
    this.uri,
    this.path,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final String name;
  final int size;
  final String variant; // original / 8M / 2M
  final String? uri; // 本地 content uri（用于缩略图/删除/打开）
  final String? path; // 展示用路径
  final DateTime time;

  String get key => '$name:${variant == 'original' ? size : '$size#$variant'}';

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'variant': variant,
        'uri': uri,
        'path': path,
        'time': time.millisecondsSinceEpoch,
      };

  static RecEntry fromJson(Map<String, dynamic> j) => RecEntry(
        name: j['name'] as String,
        size: (j['size'] as num).toInt(),
        variant: (j['variant'] as String?) ?? 'original',
        uri: j['uri'] as String?,
        path: j['path'] as String?,
        time: DateTime.fromMillisecondsSinceEpoch((j['time'] as num?)?.toInt() ?? 0),
      );
}

/// 已下载记录（含本地 uri），用于去重、手机相册页展示与批量删除。
class RecordStore {
  final Map<String, RecEntry> _entries = {};
  File? _file;
  bool _loaded = false;
  bool _dirty = false;

  bool get loaded => _loaded;

  List<RecEntry> get all {
    final list = _entries.values.toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  bool contains(String? name, int? size, [String variant = 'original']) {
    if (name == null || size == null) return false;
    return _entries.containsKey(RecEntry(name: name, size: size, variant: variant).key);
  }

  int get length => _entries.length;

  void add(RecEntry e) {
    _entries[e.key] = e;
    _scheduleSave();
  }

  void removeKey(String key) {
    _entries.remove(key);
    _scheduleSave();
  }

  /// 修补旧记录缺失的本地 uri
  void updateUri(String key, String uri) {
    final e = _entries[key];
    if (e == null || e.uri != null) return;
    _entries[key] = RecEntry(
      name: e.name, size: e.size, variant: e.variant, uri: uri, path: e.path, time: e.time,
    );
    _scheduleSave();
  }

  void clear() {
    _entries.clear();
    _scheduleSave();
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}${Platform.pathSeparator}nikonsync_downloads.json');
      _file = f;
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is List) {
          for (final item in raw) {
            if (item is Map) {
              _entries[RecEntry.fromJson(item.cast<String, dynamic>()).key] =
                  RecEntry.fromJson(item.cast<String, dynamic>());
            } else if (item is String) {
              // 旧版格式 "name:size" 或 "name#variant:size"
              final i = item.lastIndexOf(':');
              if (i <= 0) continue;
              final left = item.substring(0, i);
              final size = int.tryParse(item.substring(i + 1)) ?? 0;
              var name = left;
              var variant = 'original';
              final h = left.indexOf('#');
              if (h > 0) {
                name = left.substring(0, h);
                variant = left.substring(h + 1);
              }
              final e = RecEntry(name: name, size: size, variant: variant);
              _entries[e.key] = e;
            }
          }
        }
      }
    } catch (_) {
      _entries.clear();
    }
  }

  Future<void> _scheduleSave() async {
    _dirty = true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!_dirty) return;
    _dirty = false;
    try {
      final f = _file ??
          File('${(await getApplicationDocumentsDirectory()).path}'
              '${Platform.pathSeparator}nikonsync_downloads.json');
      _file = f;
      await f.writeAsString(jsonEncode(all.map((e) => e.toJson()).toList()), flush: true);
    } catch (_) {}
  }
}
