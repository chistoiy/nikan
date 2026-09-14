
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../engine/record_store.dart';
import '../models/exif_summary.dart';
import '../util/format.dart';
import 'widgets/app_widgets.dart';
import 'widgets/zoom_image.dart';

/// 本地已下载照片查看器：翻页、缩放、EXIF、删除。
class LocalViewerPage extends StatefulWidget {
  const LocalViewerPage({
    super.key,
    required this.model,
    required this.entries,
    required this.initialIndex,
  });

  final AppModel model;
  final List<RecEntry> entries;
  final int initialIndex;

  @override
  State<LocalViewerPage> createState() => _LocalViewerPageState();
}

class _LocalViewerPageState extends State<LocalViewerPage> {
  static const yellow = kAccent;

  late final PageController _ctrl;
  final Map<String, Uint8List> _bytes = {};
  final Map<String, ExifSummary> _exif = {};  final Set<String> _deletedKeys = {};
  bool _showInfo = true;

  AppModel get model => widget.model;

  /// 本页当前可见条目。翻页、标题计数、删除必须全部基于同一份列表，
  /// 此前 PageView 用过滤后的列表而删除用 widget.entries 的索引，
  /// 一旦错位就会删掉相邻的照片。
  List<RecEntry> get _visible =>
      widget.entries.where((e) => !_deletedKeys.contains(e.key)).toList();

  @override
  void initState() {
    super.initState();
    _ctrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _ensureBytes(RecEntry e) async {
    if (_bytes.containsKey(e.key) || e.uri == null) return;
    try {
      final b = await NikonEngine.mediaBytes(e.uri!);
      if (!mounted) return;
      setState(() => _bytes[e.key] = b);
      _parseExif(e.key, b);
    } catch (_) {}
  }

  Future<void> _parseExif(String key, Uint8List bytes) async {
    final info = await ExifSummary.parse(bytes);
    if (mounted) setState(() => _exif[key] = info);
  }

  /// 删除当前页照片。入参就是当前显示的那一条，不再按索引二次查找。
  Future<void> _deleteCurrent(RecEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('删除这张照片？', style: TextStyle(fontSize: 16)),
        content: Text(e.name, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40), backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || e.uri == null) return;
    final deleted = await NikonEngine.mediaDelete(e.uri!);
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除失败，文件仍在本机')));
      return;
    }
    model.gateway.records.removeKey(e.key);
    setState(() => _deletedKeys.add(e.key));
    if (_visible.isEmpty) {
      Navigator.pop(context);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visible;
    final rawIndex =
        _ctrl.hasClients ? (_ctrl.page?.round() ?? widget.initialIndex) : widget.initialIndex;
    final index = entries.isEmpty ? 0 : rawIndex.clamp(0, entries.length - 1).toInt();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${entries.isEmpty ? 0 : index + 1} / ${entries.length}',
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: '信息',
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: entries.isEmpty ? null : () => _deleteCurrent(entries[index]),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _ctrl,
        itemCount: entries.length,
        onPageChanged: (_) => setState(() {}),
        itemBuilder: (context, i) {
          final e = entries[i];
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureBytes(e));
          final bytes = _bytes[e.key];
          final exifInfo = _exif[e.key];
          return Column(
            children: [
              Expanded(
                child: bytes == null
                    ? const Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : ZoomableImage(bytes: bytes),
              ),
              if (_showInfo)
                Container(
                  width: double.infinity,
                  color: const Color(0xFF141414),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(e.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        [
                          formatBytes(e.size),
                          if (e.variant != 'original') e.variant,
                          e.time.toString().substring(0, 16),
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55)),
                      ),
                      const SizedBox(height: 4),
                      if (exifInfo != null && !exifInfo.isEmpty)
                        Text(
                          exifInfo.text,
                          style: const TextStyle(fontSize: 12.5, color: yellow),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
