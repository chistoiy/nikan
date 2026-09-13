
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../engine/record_store.dart';
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
  static const yellow = Color(0xFFFFE100);

  late final PageController _ctrl;
  final Map<String, Uint8List> _bytes = {};
  final Map<String, Map<String, String>> _exif = {};
  bool _showInfo = true;
  bool _deleted = false;

  AppModel get model => widget.model;

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
    try {
      final tags = await readExifFromBytes(bytes);
      final info = <String, String>{
        if (tags['EXIF ISOSpeedRatings']?.printable != null) 'iso': 'ISO ${tags['EXIF ISOSpeedRatings']!.printable}',
        if (tags['EXIF FNumber']?.printable != null) 'f': 'f/${tags['EXIF FNumber']!.printable}',
        if (tags['EXIF ExposureTime']?.printable != null) 's': '${tags['EXIF ExposureTime']!.printable}s',
      };
      if (mounted) setState(() => _exif[key] = info);
    } catch (_) {}
  }

  Future<void> _deleteCurrent(int index) async {
    final e = widget.entries[index];
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
    await NikonEngine.mediaDelete(e.uri!);
    model.gateway.records.removeKey(e.key);
    if (!mounted) return;
    final remain = widget.entries.length - 1;
    if (remain == 0) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)));
      setState(() => _deleted = true);
    }
  }

  String _fmtSize(num? b) {
    if (b == null || b <= 0) return '';
    if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)}MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)}KB';
    return '${b}B';
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries.where((e) => model.gateway.records.contains(e.name, e.size, e.variant) || !_deleted).toList();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${(_ctrl.hasClients ? _ctrl.page?.round() ?? widget.initialIndex : widget.initialIndex) + 1}'
            ' / ${entries.length}', style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: '信息',
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteCurrent(_ctrl.hasClients ? (_ctrl.page?.round() ?? 0) : widget.initialIndex),
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
                          _fmtSize(e.size.toDouble()),
                          if (e.variant != 'original') e.variant,
                          e.time.toString().substring(0, 16),
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55)),
                      ),
                      const SizedBox(height: 4),
                      if (exifInfo != null && exifInfo.isNotEmpty)
                        Text(
                          exifInfo.values.join('   '),
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
