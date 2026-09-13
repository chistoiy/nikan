import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 支持双击放大/还原的图片（配合双指缩放）。
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({super.key, required this.bytes, this.fit = BoxFit.contain});

  final Uint8List bytes;
  final BoxFit fit;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  final TransformationController _tc = TransformationController();
  Offset? _doubleTapPos;

  @override
  void dispose() {
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
        child: Center(child: Image.memory(widget.bytes, fit: widget.fit, gaplessPlayback: true)),
      ),
    );
  }
}
