import 'dart:async';

import 'package:flutter/foundation.dart';

/// 全局协议日志缓冲：App 启动即开始记录（原生事件 → AppModel 转发到这里），
/// 任何页面打开调试面板时都能看到历史日志。
///
/// 性能约束：
/// - 日志突发（探针/重试/事件排水）通过 300ms 节流合并通知，避免 UI 重建风暴；
/// - 错误上报（reportError）带防递归与频率限制，防止"错误→记日志→重建→再错误"死循环。
class AppLog {
  AppLog._();

  static final List<({String time, String text})> lines = [];
  static final ValueNotifier<int> version = ValueNotifier(0);
  static const int _max = 300;

  /// UI 显示窗口：只渲染最近 N 条（SelectionArea 渲染成本高），复制仍是全量
  static const int displayWindow = 120;

  static Timer? _flushTimer;
  static DateTime? _lastErrorLog;
  static bool _reporting = false;

  static void add(String text) => _push(text);

  /// 错误堆栈上报：防递归 + 500ms 频率限制
  static void reportError(String text) {
    if (_reporting) return;
    final now = DateTime.now();
    if (_lastErrorLog != null && now.difference(_lastErrorLog!) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastErrorLog = now;
    _reporting = true;
    try {
      _push(text);
    } finally {
      _reporting = false;
    }
  }

  static void _push(String text) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    lines.add((time: ts, text: text));
    if (lines.length > _max) lines.removeRange(0, lines.length - _max);
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 300), () {
      _flushTimer = null;
      version.value++;
    });
  }

  static void clear() {
    lines.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    version.value++;
  }
}
