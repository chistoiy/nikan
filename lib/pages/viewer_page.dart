import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_model.dart';
import '../models/camera_file.dart';
import '../models/exif_summary.dart';
import '../util/format.dart';
import 'widgets/app_widgets.dart';
import 'widgets/zoom_image.dart';

/// 全屏大图查看器：左右翻页、双指缩放、原图拉取、EXIF 信息（ISO/光圈/快门）。
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.model,
    required this.files,
    required this.initialIndex,
  });

  final AppModel model;
  final List<CameraFile> files;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _ctrl;
  final Map<int, Uint8List> _full = {};
  final Map<int, ExifSummary> _exif = {};
  bool _showInfo = true;

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

  Future<void> _ensureFull(CameraFile f) async {
    if (_full.containsKey(f.handle)) return;
    try {
      final bytes = await model.gateway.viewBytes(f);
      if (!mounted) return;
      setState(() => _full[f.handle] = bytes);
      if (f.kind != 'video') _parseExif(f.handle, bytes);
    } catch (_) {
      // 拉取失败时保持缩略图显示
    }
  }

  Future<void> _parseExif(int handle, Uint8List bytes) async {
    final info = await ExifSummary.parse(bytes);
    if (mounted) setState(() => _exif[handle] = info);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          '${(_ctrl.hasClients ? _ctrl.page?.round() ?? widget.initialIndex : widget.initialIndex) + 1}'
          ' / ${widget.files.length}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: '信息',
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
          IconButton(
            tooltip: '下载原图',
            icon: const Icon(Icons.download_outlined),
            onPressed: () async {
              final i = _ctrl.hasClients ? (_ctrl.page?.round() ?? 0) : widget.initialIndex;
              final r = await model.download([widget.files[i]]);
              if (context.mounted && r.isNotEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r)));
              }
            },
          ),
        ],
      ),
      body: PageView.builder(
        controller: _ctrl,
        itemCount: widget.files.length,
        onPageChanged: (_) => setState(() {}),
        itemBuilder: (context, i) {
          final f = widget.files[i];
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFull(f));
          final bytes = _full[f.handle] ?? model.gateway.memThumb(f.handle);
          final exifInfo = _exif[f.handle];
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
                      Text(
                        f.name ?? '',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (f.dateText != null) f.dateText!,
                          if (f.width != null && f.height != null && f.width! > 0) '${f.width}×${f.height}',
                          formatBytes(f.size),
                          if (f.ext != null) f.ext!,
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        exifInfo == null
                            ? (f.kind == 'video' ? '' : 'EXIF 解析中…')
                            : exifInfo.text,
                        style: const TextStyle(fontSize: 12.5, color: kAccent),
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
