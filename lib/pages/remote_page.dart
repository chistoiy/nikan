import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../models/camera_file.dart';
import 'widgets/app_widgets.dart';

/// 遥控拍摄页：盲拍 / 实时取景 双模式。
///
/// - 盲拍：0x100E 快门（拍到卡）
/// - 实时取景：0x9201 启动 → 0x9203 轮询帧（40~73KB JPEG）→ 0x9405 取景中拍摄
///   （对焦优先：先 0x90C3 AF；未对焦返回 0xA004 会明确提示）
/// - 拍后自动预览/下载：监听 ObjectAdded
class RemotePage extends StatefulWidget {
  const RemotePage({super.key, required this.model});

  final AppModel model;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

enum _RemoteMode { blind, liveView }

class _RemotePageState extends State<RemotePage> {
  static const yellow = kAccent;

  StreamSubscription<dynamic>? _events;
  Timer? _frameTimer;
  bool _fetchingFrame = false;
  int _notLvCount = 0;
  bool _lvStarting = false;

  Uint8List? _frame;
  Uint8List? _latestThumb;
  int _shotCount = 0;
  bool _shooting = false;
  bool _autoDownload = false;
  final Set<int> _seenHandles = {};

  Map<String, dynamic>? _params;

  _RemoteMode _mode = _RemoteMode.blind;

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _events = model.events.listen(_onEvent);
    _loadParams();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    if (_mode == _RemoteMode.liveView) {
      NikonEngine.liveViewStop().catchError((_) {});
    }
    _events?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ 事件

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final map = e.cast<String, dynamic>();
    if (map['type'] == 'objectAdded') {
      final handle = (map['handle'] as num).toInt();
      _onNewPhoto(handle);
    }
  }

  Future<void> _onNewPhoto(int handle) async {
    if (!_seenHandles.add(handle)) return;
    final f = CameraFile(handle: handle, folder: '');
    try {
      final m = await NikonEngine.fileView(handle);
      f.applyInfo(m);
      final t = m['thumb'] as Uint8List?;
      if (!mounted) return;
      setState(() {
        _latestThumb = (t != null && t.isNotEmpty) ? t : null;
        _shotCount++;
      });
      // 取走新照片，避免相机因待传输队列而拒绝下一次快门
      if (f.kind != 'video' && (f.size ?? 0) > 0 && (f.size ?? 0) <= 40 * 1024 * 1024) {
        try {
          final full = await model.gateway.viewBytes(f);
          if (mounted && full.isNotEmpty) {
            setState(() => _latestThumb = full);
          }
        } catch (_) {}
      }
      if (_autoDownload && f.isJpeg == true && f.size != null) {
        await model.download([f]);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ 动作

  Future<void> _loadParams() async {
    try {
      final p = await NikonEngine.shotParams();
      if (mounted) setState(() => _params = p);
    } catch (_) {}
  }

  Future<void> _switchMode(_RemoteMode m) async {
    if (m == _mode) return;
    if (m == _RemoteMode.liveView) {
      setState(() => _lvStarting = true);
      try {
        await NikonEngine.liveViewStart();
        if (!mounted) return;
        setState(() {
          _mode = m;
          _notLvCount = 0;
        });
        _frameTimer?.cancel();
        _frameTimer = Timer.periodic(const Duration(milliseconds: 60), (_) => _grabFrame());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('实时取景启动失败：$e')));
        }
      } finally {
        if (mounted) setState(() => _lvStarting = false);
      }
    } else {
      _frameTimer?.cancel();
      await NikonEngine.liveViewStop().catchError((_) {});
      if (mounted) setState(() => _mode = m);
    }
  }

  Future<void> _grabFrame() async {
    if (_fetchingFrame || !mounted) return;
    _fetchingFrame = true;
    try {
      final f = await NikonEngine.liveViewFrame();
      if (f.length > 2 && mounted) {
        setState(() {
          _frame = f;
          _notLvCount = 0;
        });
      }
    } on PlatformException {
      _notLvCount++;
      if (_notLvCount == 5) {
        // 取景可能掉线：自动重启一次
        NikonEngine.liveViewStart().catchError((_) {});
      }
    } catch (_) {
    } finally {
      _fetchingFrame = false;
    }
  }

  Future<void> _shoot() async {
    if (_shooting) return;
    setState(() => _shooting = true);
    try {
      if (_mode == _RemoteMode.liveView) {
        await NikonEngine.lvCapture();
      } else {
        await NikonEngine.capture();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已拍摄'), duration: Duration(seconds: 1)),
        );
      }
      _loadParams();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拍摄失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<void> _focus() async {
    try {
      final ok = await NikonEngine.afDrive();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? '对焦完成' : '对焦失败或不支持'), duration: const Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('对焦失败：$e')));
      }
    }
  }

  String _fNumberText() {
    final v = (_params?['fNumber'] as num?)?.toDouble();
    if (v == null || v <= 0) return '—';
    final f = v / 100;
    return 'f/${f == f.roundToDouble() ? f.toStringAsFixed(0) : f.toStringAsFixed(1)}';
  }

  String _exposureText() {
    final v = (_params?['exposureTime'] as num?)?.toDouble();
    if (v == null || v <= 0) return '—';
    final s = v / 10000;
    if (s >= 1) return '${s.toStringAsFixed(s >= 10 ? 0 : 1)}s';
    return '1/${(10000 / v).round()}s';
  }

  String _isoText() {
    final v = (_params?['iso'] as num?)?.toInt();
    return v == null || v <= 0 ? '—' : 'ISO $v';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final disconnected = model.connState != 'connected';
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(title: const Text('遥控拍摄')),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _viewArea(disconnected)),
                _controlBar(disconnected),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _viewArea(bool disconnected) {
    if (disconnected) {
      return const DisconnectedView(message: '连接已断开');
    }
    if (_mode == _RemoteMode.liveView) {
      if (_frame != null) {
        return Center(
          child: Image.memory(_frame!, fit: BoxFit.contain, gaplessPlayback: true),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 12),
            Text(
              _lvStarting ? '正在启动实时取景…' : '等待取景画面…',
              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
    }
    // 盲拍模式
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_latestThumb != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(_latestThumb!, width: 260, fit: BoxFit.contain, gaplessPlayback: true),
              ),
            )
          else ...[
            const Icon(Icons.camera_alt_outlined, size: 72, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              _shotCount == 0 ? '按下快门开始拍摄' : '等待照片…',
              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
          if (_shotCount > 0)
            Text('已拍摄 $_shotCount 张',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5))),
        ],
      ),
    );
  }

  Widget _controlBar(bool disconnected) {
    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<_RemoteMode>(
            segments: const [
              ButtonSegment(value: _RemoteMode.blind, label: Text('盲拍')),
              ButtonSegment(value: _RemoteMode.liveView, label: Text('实时取景')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => _switchMode(s.first),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity(horizontal: -2, vertical: -2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _param(_fNumberText()),
                const SizedBox(width: 18),
                _param(_exposureText()),
                const SizedBox(width: 18),
                _param(_isoText()),
                const SizedBox(width: 18),
                _param(model.battery >= 0 ? '${model.battery}%' : '—'),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: disconnected ? null : _focus,
                icon: const Icon(Icons.center_focus_strong, size: 18),
                label: const Text('对焦', style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 16),
              TextButton.icon(
                onPressed: () => setState(() => _autoDownload = !_autoDownload),
                icon: Icon(
                  _autoDownload ? Icons.download_done : Icons.download_outlined,
                  size: 18,
                  color: _autoDownload ? yellow : Colors.white54,
                ),
                label: Text(
                  _autoDownload ? '拍后自动下载' : '拍后不自动下载',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: (disconnected || _shooting) ? null : _shoot,
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: disconnected ? Colors.white24 : yellow, width: 4),
              ),
              child: Center(
                child: _shooting
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: disconnected ? Colors.white12 : yellow,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _mode == _RemoteMode.liveView ? '实时取景 · 照片将拍摄到存储卡' : '盲拍模式 · 照片将拍摄到存储卡',
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _param(String text) => Text(
        text,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white70),
      );
}
