import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 支持双击放大/还原的图片（配合双指缩放）。
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.bytes,
    this.fit = BoxFit.contain,
    this.quarterTurns = 0,
  });

  final Uint8List bytes;
  final BoxFit fit;

  /// 顺时针 90° 的次数。旋转放在 InteractiveViewer 内层，
  /// 这样缩放/拖拽的坐标系仍与屏幕一致，手感不会跟着转。
  final int quarterTurns;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  final TransformationController _tc = TransformationController();
  Offset? _doubleTapPos;

  /// 解码档位：1 = 按显示尺寸，2 = 放大后提分辨率。
  ///
  /// 为什么要分档而不是直接全分辨率解码：Z50 II 的 JPEG L 是 5568×3712，
  /// 全解码成 RGBA 约 **82MB/张**，连翻几张就会在中低端机上 OOM。
  /// 分档后常态只解到"屏幕实际用得到的像素"，放大看细节时再提升一级。
  int _zoomTier = 1;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  /// 只在跨越档位时重建：解码分辨率一变就要重新解码，绝不能跟着缩放的每一帧走。
  void _onTransform() {
    final tier = _tc.value.getMaxScaleOnAxis() > 2.0 ? 2 : 1;
    if (tier != _zoomTier) setState(() => _zoomTier = tier);
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransform);
    _tc.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    const scale = 2.5;
    if (_tc.value.getMaxScaleOnAxis() > 1.05) {
      _tc.value = Matrix4.identity();
      return;
    }
    final pos = _doubleTapPos;
    if (pos == null) {
      _tc.value = Matrix4.identity()..scaleByDouble(scale, scale, 1, 1);
      return;
    }
    final x = -pos.dx * (scale - 1);
    final y = -pos.dy * (scale - 1);
    _tc.value = Matrix4(scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1, 0, x, y, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        maxScale: 6,
        panEnabled: true,
        child: Center(
          child: RotatedBox(
            quarterTurns: widget.quarterTurns,
            child: LayoutBuilder(
              builder: (ctx, box) {
                // 取显示区域的**长边**作基准：竖图占满高度、横图占满宽度，
                // 用长边才能保证两种朝向都清晰（用宽度会让竖图糊掉）。
                final dpr = MediaQuery.devicePixelRatioOf(ctx);
                final basis = (box.maxWidth.isFinite && box.maxHeight.isFinite)
                    ? (box.maxWidth > box.maxHeight ? box.maxWidth : box.maxHeight)
                    : 1080.0;
                var target = basis * dpr * (_zoomTier == 2 ? 2.0 : 1.0);
                // 硬上限：即使放大档也不让单张位图超过约 4K 宽（≈30MB）
                if (target > 4096) target = 4096;
                return Image(
                  image: ResizeImage(
                    MemoryImage(widget.bytes),
                    width: target.round().clamp(1, 8192),
                    // fit = 只缩不放：小图（缩略图/低画质档）绝不能被这里放大解码
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: widget.fit,
                  gaplessPlayback: true,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
