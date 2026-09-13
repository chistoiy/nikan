import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 缩略图两级缓存：内存 LRU + 磁盘目录。
/// 磁盘键为句柄（缩略图内容在卡内同一文件上不变；换卡场景由内存清空兜底）。
class ThumbCache {
  static const int _memMaxEntries = 400;
  static const int _diskMaxBytes = 300 << 20; // 300MB，超出时启动期清理最旧

  final LinkedHashMap<int, Uint8List> _mem = LinkedHashMap();
  Directory? _dir;
  bool _pruned = false;

  Future<Directory> _ensureDir() async {
    final d = _dir;
    if (d != null) return d;
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}${Platform.pathSeparator}nikothumbs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dir = dir;
    return dir;
  }

  Uint8List? memGet(int handle) {
    final v = _mem.remove(handle);
    if (v != null) _mem[handle] = v; // 触碰移到队尾
    return v;
  }

  Future<Uint8List?> get(int handle) async {
    final m = memGet(handle);
    if (m != null) return m;
    try {
      final dir = await _ensureDir();
      final f = File('${dir.path}${Platform.pathSeparator}h$handle.jpg');
      if (f.existsSync()) {
        final bytes = await f.readAsBytes();
        _memPut(handle, bytes);
        return bytes;
      }
    } catch (_) {}
    return null;
  }

  void put(int handle, Uint8List bytes) {
    _memPut(handle, bytes);
    _ensureDir().then((dir) {
      final f = File('${dir.path}${Platform.pathSeparator}h$handle.jpg');
      if (!f.existsSync()) f.writeAsBytes(bytes, flush: false).catchError((_) => f);
    }).catchError((_) {});
  }

  void _memPut(int handle, Uint8List bytes) {
    _mem.remove(handle);
    _mem[handle] = bytes;
    while (_mem.length > _memMaxEntries) {
      _mem.remove(_mem.keys.first);
    }
  }

  void clearMemory() => _mem.clear();

  /// 启动期磁盘超限清理（最旧的先删）
  Future<void> pruneDiskIfNeeded() async {
    if (_pruned) return;
    _pruned = true;
    try {
      final dir = await _ensureDir();
      final files = dir.existsSync() ? dir.listSync().whereType<File>().toList() : <File>[];
      int total = 0;
      for (final f in files) {
        total += f.lengthSync();
      }
      if (total <= _diskMaxBytes) return;
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      for (final f in files) {
        if (total <= _diskMaxBytes * 0.8) break;
        final len = f.lengthSync();
        f.deleteSync();
        total -= len;
      }
    } catch (_) {}
  }
}
