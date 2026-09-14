import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// 微信式滑动多选：长按进入选择模式，按住滑动按「锚点 → 当前」连续选中/取消
/// （跨行按路径整段覆盖），指针停在视口上下边缘时自动滚动以便继续向后选。
///
/// 相册页与手机页的差异只有两处——条目主键类型，以及"屏幕坐标 → 条目索引"
/// 的换算方式（网格是行列计算，列表是逐格命中测试）。这两点都作为参数注入，
/// 逻辑只此一份：此前两个页面各写一套，已经在坐标换算上分叉出一个 bug
/// （相册页把局部坐标当全局坐标用，边缘滚动时反复选中第 0 行）。
class DragSelection<T> {
  DragSelection({
    required this.keyAt,
    required this.itemCount,
    required this.indexAt,
    required this.scrollController,
    required this.viewportBox,
    required this.onChanged,
  });

  /// 索引 → 条目主键
  final T Function(int index) keyAt;

  /// 当前条目总数。每次操作时读取：列表可能已被刷新
  final int Function() itemCount;

  /// 全局坐标 → 条目索引；未命中返回 null
  final int? Function(Offset global) indexAt;

  final ScrollController scrollController;

  /// 边缘自动滚动的判定视口，返回 null 时跳过边缘判定
  final RenderBox? Function() viewportBox;

  /// 选择集或选择模式发生变化时回调，由页面决定如何重建
  final VoidCallback onChanged;

  final Set<T> selected = {};
  bool selectMode = false;
  bool dragSelecting = false;

  /// 当前滑动方向：true 选中 / false 取消
  bool dragAdd = true;

  /// 长按起点的索引
  int? anchorIdx;

  Offset? _lastGlobal;
  double _scrollDelta = 0;
  Timer? _timer;

  static const double _edge = 90;
  static const double _step = 7;

  // ------------------------------------------------------------ 基本操作

  void toggle(T key) {
    if (!selected.remove(key)) selected.add(key);
    if (selectMode && selected.isEmpty) selectMode = false;
    onChanged();
  }

  /// 从单元格右下角的勾选热区进入选择模式并切换该项
  void enterSelectAndToggle(T key) {
    selectMode = true;
    toggle(key);
  }

  void exitSelect() {
    selectMode = false;
    selected.clear();
    dragSelecting = false;
    anchorIdx = null;
    stopAutoScroll();
    onChanged();
  }

  /// 列表刷新后剔除已失效的主键，避免"已选 N"包含不在列表里的条目
  void prune(Set<T> valid) {
    if (selected.isEmpty) return;
    final before = selected.length;
    selected.removeWhere((k) => !valid.contains(k));
    if (selected.length == before) return;
    if (selected.isEmpty && selectMode) selectMode = false;
    onChanged();
  }

  // ------------------------------------------------------------ 全选

  bool allSelected(Iterable<T> all) {
    var any = false;
    for (final k in all) {
      any = true;
      if (!selected.contains(k)) return false;
    }
    return any;
  }

  /// 全选/取消全选。判定与切换必须基于同一个集合，否则只要选中集里含
  /// 有被筛掉的条目，文案与动作就会不一致（历史 bug）。
  void toggleAll(Iterable<T> all) {
    final keys = all.toSet();
    if (keys.isNotEmpty && keys.every(selected.contains)) {
      selected.removeAll(keys);
    } else {
      selected.addAll(keys);
    }
    if (selected.isEmpty && selectMode) selectMode = false;
    onChanged();
  }

  // ------------------------------------------------------------ 滑动选择

  /// 长按起点：进入选择模式，并把锚点整行加入/移出选择
  void beginDrag(int index) {
    selectMode = true;
    dragAdd = !selected.contains(keyAt(index));
    anchorIdx = index;
    dragSelecting = true;
    applyRange(index);
    onChanged();
  }

  void updateDrag(Offset global) {
    if (!dragSelecting) return;
    _lastGlobal = global;
    final idx = indexAt(global);
    if (idx != null) applyRange(idx);
    _updateAutoScroll(global);
  }

  void endDrag() {
    dragSelecting = false;
    anchorIdx = null;
    stopAutoScroll();
  }

  /// 锚点 → 当前索引的连续范围
  void applyRange(int cur) {
    final anchor = anchorIdx;
    if (anchor == null) return;
    final lo = min(anchor, cur), hi = max(anchor, cur);
    final n = itemCount();
    var changed = false;
    for (var i = lo; i <= hi && i < n; i++) {
      final k = keyAt(i);
      if (dragAdd) {
        changed |= selected.add(k);
      } else {
        changed |= selected.remove(k);
      }
    }
    if (changed) onChanged();
  }

  /// 指针停在视口上下边缘时慢速自动滚动。
  /// 滚动过程中用保存的**全局**坐标重新换算索引；方向每次跟随更新，
  /// 手指从下缘移回上缘时方向会立刻反转。
  void _updateAutoScroll(Offset global) {
    final box = viewportBox();
    if (box == null) return;
    final local = box.globalToLocal(global);
    double? delta;
    if (local.dy < _edge && local.dy > 0) delta = -_step;
    if (local.dy > box.size.height - _edge && local.dy < box.size.height) delta = _step;
    if (delta == null) {
      stopAutoScroll();
      return;
    }
    _scrollDelta = delta;
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!dragSelecting || !scrollController.hasClients) {
        stopAutoScroll();
        return;
      }
      final pos = scrollController.position;
      pos.jumpTo((pos.pixels + _scrollDelta).clamp(0.0, pos.maxScrollExtent));
      final g = _lastGlobal;
      if (g == null) return;
      final idx = indexAt(g);
      if (idx != null) applyRange(idx);
    });
  }

  void stopAutoScroll() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stopAutoScroll();
  }
}
