import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/camera_file.dart';
import 'app_widgets.dart';

/// 相册网格单元格：缩略图 + 类型角标 + 已下载标记 + 右下角勾选热区。
///
/// 只负责呈现与手势转发；缩略图的按需加载由页面决定（涉及引擎调度）。
class GalleryCell extends StatelessWidget {
  const GalleryCell({
    super.key,
    required this.file,
    required this.thumb,
    required this.selected,
    required this.downloaded,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  final CameraFile file;
  final Uint8List? thumb;
  final bool selected;
  final bool downloaded;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final isRaw = file.kind == 'raw';
    final isVideo = file.kind == 'video';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: (_) => onLongPress(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFF161616),
            alignment: Alignment.center,
            child: thumb == null
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
                  )
                : null,
          ),
          if (thumb != null)
            Image.memory(thumb!, fit: BoxFit.cover, gaplessPlayback: true),
          if (isRaw)
            _Badge(file.ext ?? 'RAW')
          else if (isVideo)
            const _Badge('视频'),
          if (downloaded)
            const Positioned(
              left: 5,
              bottom: 5,
              child: Icon(Icons.check_circle, size: 15, color: Color(0xFF4CD964)),
            ),
          // 22×22 的隐形勾选热区：不遮挡缩略图，点它直接进入选择模式
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                onToggleSelect();
              },
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 22, height: 22),
              ),
            ),
          ),
          if (selected)
            const Positioned(
              right: 8,
              bottom: 8,
              child: IgnorePointer(child: Icon(Icons.check_circle, size: 22, color: kAccent)),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Positioned(
        top: 4,
        left: 4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
          child: Text(
            text,
            style: const TextStyle(
                fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      );
}
