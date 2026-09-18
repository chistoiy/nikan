import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/camera_file.dart';
import 'app_widgets.dart';

/// 相册网格单元格：缩略图 + 类型角标 + RAW+JPEG 成对标记 + 已下载标记 + 勾选热区。
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
    this.onLongPress,
    this.onToggleSelect,
    this.pairDownloaded = false,
    this.inSelectMode = false,
  });

  final CameraFile file;
  final Uint8List? thumb;
  final bool selected;
  final bool downloaded;

  /// 配对（RAW↔JPEG）的另一半是否已下载。成对照片最需要看见的就是这个：
  /// "我收了 JPEG，但 RAW 还没收"。
  final bool pairDownloaded;
  final VoidCallback onTap;

  /// 长按起选。传 null 表示当前**不允许改选择集**（例如下载进行中：
  /// 此刻改选择不会影响已经在传的清单，只会让用户以为"取消掉了"，所以直接禁用）。
  final VoidCallback? onLongPress;

  /// 右下角勾选热区。为 null 时整个热区不渲染（例如下载进行中不允许改选择集）。
  final VoidCallback? onToggleSelect;

  /// 是否处于选择模式。
  ///
  /// 为 true 时右下角**常驻一个可见的勾选圈**：因为此时"点缩略图"是打开大图
  /// （挑选时总要看清楚才敢下手），勾选就得有一个明确、看得见的落点，
  /// 不能还靠一块隐形热区——那样用户根本不知道该点哪儿。
  final bool inSelectMode;

  @override
  Widget build(BuildContext context) {
    final isRaw = file.kind == 'raw';
    final isVideo = file.kind == 'video';
    final paired = file.isPaired;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: onLongPress == null ? null : (_) => onLongPress!(),
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
          // 成对标记：右上角，一眼看出这张照片在相机上是"JPG + RAW"两个文件
          if (paired)
            const Positioned(top: 4, right: 4, child: _Badge('R+J')),
          // 下载状态：成对时分列显示 J / R，避免"以为整张都收了"
          Positioned(
            left: 5,
            bottom: 5,
            child: paired
                ? _PairTicks(
                    selfRaw: isRaw,
                    selfDone: downloaded,
                    pairDone: pairDownloaded,
                  )
                : (downloaded
                    ? const Icon(Icons.check_circle, size: 15, color: Color(0xFF4CD964))
                    : const SizedBox.shrink()),
          ),
          // 右下角：
          // - 选择模式下常驻一个**可见的勾选圈**（点它切换选中）——此时点缩略图是"看大图"，
          //   勾选必须有个看得见的落点，不能还靠隐形热区；
          // - 非选择模式保留隐形热区，点它进入选择模式并选中该张。
          if (onToggleSelect != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onToggleSelect!();
                },
                child: Padding(
                  padding: EdgeInsets.all(inSelectMode ? 2 : 8),
                  child: SizedBox(
                    width: inSelectMode ? 34 : 22,
                    height: inSelectMode ? 34 : 22,
                    child: inSelectMode
                        ? Center(
                            child: Icon(
                              selected ? Icons.check_circle : Icons.circle_outlined,
                              size: 22,
                              color: selected ? kAccent : Colors.white,
                              shadows: const [Shadow(color: Colors.black87, blurRadius: 5)],
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          // 已选但当前没有勾选入口时（例如下载进行中：选择被锁定）仍要能看出选了什么
          if (selected && onToggleSelect == null)
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

/// J / R 两枚下载状态标记（成对照片用）。
///
/// 左边是 JPEG 的状态、右边是 RAW 的状态：实心绿勾 = 已下载，空心灰圈 = 未下载。
class _PairTicks extends StatelessWidget {
  const _PairTicks({required this.selfRaw, required this.selfDone, required this.pairDone});

  /// 当前这个格子本身是不是 RAW（决定 J/R 哪个用 selfDone）
  final bool selfRaw;
  final bool selfDone;
  final bool pairDone;

  @override
  Widget build(BuildContext context) {
    final jDone = selfRaw ? pairDone : selfDone;
    final rDone = selfRaw ? selfDone : pairDone;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tick('J', jDone),
          const SizedBox(width: 3),
          _tick('R', rDone),
        ],
      ),
    );
  }

  Widget _tick(String label, bool done) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: done ? const Color(0xFF4CD964) : Colors.white38,
              )),
          Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            size: 9,
            color: done ? const Color(0xFF4CD964) : Colors.white38,
          ),
        ],
      );
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
