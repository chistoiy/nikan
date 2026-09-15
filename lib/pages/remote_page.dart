import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/app_log.dart';
import '../engine/nikon_engine.dart';
import '../models/camera_file.dart';
import '../util/format.dart';
import '../util/jpeg_exif.dart';
import 'widgets/app_widgets.dart';
import 'widgets/zoom_image.dart';

/// 遥控拍摄页：盲拍 / 实时取景 双模式。
///
/// - 盲拍：0x100E 快门（拍到卡），拍后拉回照片直接在页内回看
/// - 实时取景：0x9201 启动 → 0x9203 轮询帧 → 0x9405 取景中拍摄
///   （对焦优先：先 0x90C3 AF；未对焦返回 0xA004 会明确提示）
///
/// 两个与显示相关的坑：
/// - 取景帧是横向出片，竖持手机时若不做方向处理，相机横放会让画面转 90°。
///   Flutter 的图片解码不处理 EXIF Orientation，所以这里自己读、自己转。
/// - 取景帧每帧都是新数据，必然重新解码；按显示尺寸解码并隔离重建范围，
///   否则解码与整页重建会吃掉相当一部分帧预算。
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
  bool _lvStarting = false;
  int _notLvCount = 0;
  int _lastLvRestartMs = 0;

  /// 取景帧与回看照片各自用 ValueNotifier 驱动，只重建画面区域：
  /// 此前每来一帧就 setState 整页重建（连控制条一起），10fps 下纯属浪费。
  final ValueNotifier<Uint8List?> _frame = ValueNotifier(null);
  final ValueNotifier<Uint8List?> _preview = ValueNotifier(null);

  CameraFile? _lastShot;
  int _shotCount = 0;
  bool _shooting = false;
  bool _downloadingLast = false;
  bool _autoDownload = false;
  bool _immersive = false;
  final Set<int> _seenHandles = {};

  /// 取景画面旋转（顺时针 90° 的次数）。相机横放时取景 JPEG 带 EXIF Orientation
  /// 标记，相机会按标记显示，而 Flutter 解码不处理，需要自己转。
  int _rotation = 0;

  /// 用户手动转过之后，不再被自动识别覆盖
  bool _rotationManual = false;

  /// 回看照片自己的方向（与取景画面各自独立）
  int _previewRotation = 0;

  /// 滑动平均后的实测帧率，显示在取景画面上
  int _fps = 0;
  final List<int> _frameGaps = [];

  /// 首帧只诊断一次：把方向与色彩特征写进日志，作为"画面方向/色彩不一致"的证据。
  /// 放在正常使用路径里，不需要用户进调试面板点探针。
  bool _loggedFrameDiagnostics = false;
  bool _loggedShotDiagnostics = false;

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
    _stopFrameLoop();
    if (_mode == _RemoteMode.liveView) {
      NikonEngine.liveViewStop().catchError((_) {});
    }
    _events?.cancel();
    _frame.dispose();
    _preview.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 事件

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final map = e.cast<String, dynamic>();
    switch (map['type']) {
      case 'objectAdded':
        _onNewPhoto((map['handle'] as num).toInt());
      case 'devicePropChanged':
        _onPropChanged((map['code'] as num).toInt());
      case 'capturePhase':
        // 原生上报的拍摄阶段（对焦 → 快门）：对焦优先机型按下快门后要等合焦，
        // 这段等待必须有解释，否则用户只看到一个转圈，以为卡死
        _capturePhase = map['phase']?.toString() ?? '';
        if (mounted) setState(() {});
    }
  }

  String _capturePhase = '';

  static String _phaseLabel(String phase) => switch (phase) {
        'af' => '正在对焦…（对焦优先机型需合焦才会释放快门）',
        'shutter' => '正在触发快门…',
        'done' => '已触发快门',
        _ => '正在拍摄…',
      };

  /// 相机主动推送的属性变化 → 节流刷新参数显示。
  ///
  /// 相机在拨轮/曝光变化时会推 DevicePropChanged（0x500D 光圈 / 0x500E 快门 / 0x500F ISO）。
  /// 此前参数只在本页 initState 与每次拍摄后各取一次，所以相机端改了设置 App 上毫无反应。
  ///
  /// 必须节流：`shotParams()` 一次要 4 个 PTP 事务，而取景帧循环与它共用同一条串行通道，
  /// 高频刷新会直接压低帧率。其余属性码（焦距等）界面不显示，忽略。
  void _onPropChanged(int code) {
    if (code != 0x500D && code != 0x500E && code != 0x500F) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastParamsAt < _paramsRefreshMs) return;
    _lastParamsAt = now;
    _loadParams();
  }

  static const int _paramsRefreshMs = 1500;
  int _lastParamsAt = 0;

  Future<void> _onNewPhoto(int handle) async {
    if (!_seenHandles.add(handle)) return;
    final f = CameraFile(handle: handle, folder: '');
    try {
      final m = await NikonEngine.fileView(handle);
      f.applyInfo(m);
      final t = m['thumb'] as Uint8List?;
      if (!mounted) return;
      _lastShot = f;
      if (t != null && t.isNotEmpty) {
        if (!_loggedShotDiagnostics) {
          _loggedShotDiagnostics = true;
          AppLog.add('回看照片诊断：${describeJpegFrame(t)}');
        }
        _previewRotation = _quarterFromExif(readExifOrientation(t));
        _preview.value = t;
      }
      setState(() => _shotCount++);

      // 取走新照片：它既是高清回看，也是解锁下一次快门的前提（交接文档 §7.1）。
      // 调整回看的展示方式时不要省掉这次读取，否则遥控连拍会退回卡忙。
      if (f.kind != 'video' && (f.size ?? 0) > 0 && (f.size ?? 0) <= 40 * 1024 * 1024) {
        try {
          final full = await model.gateway.viewBytes(f);
          if (mounted && full.isNotEmpty) {
            _previewRotation = _quarterFromExif(readExifOrientation(full));
            _preview.value = full;
          }
        } catch (_) {}
      }
      if (_autoDownload && f.isJpeg == true && f.size != null) {
        await model.download([f]);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ 取景帧循环

  bool _frameLoopOn = false;

  void _startFrameLoop() {
    if (_frameLoopOn) return;
    _frameLoopOn = true;
    unawaited(_frameLoop());
  }

  void _stopFrameLoop() => _frameLoopOn = false;

  /// 两次取帧之间的最小间隔。
  ///
  /// 自调度循环本身没有空转，但请求速率会完全跟着响应走；若相机产出速率跟不上，
  /// 请求就会排队直到超时——而**一次超时会让命令流永久错位**（见 PtpIpClient），
  /// 之后保活探针读到 30 秒超时即判定断线，相机侧也随之关闭热点。
  /// 保留这个下限，避免把相机逼到超时。
  static const int _minFrameGapMs = 20;

  /// 自调度取帧：一帧拉完立刻请求下一帧（受 [_minFrameGapMs] 约束）。
  ///
  /// 此前是 `Timer.periodic(60ms)` + `_fetchingFrame` 丢弃重入：相机 150ms 才回一帧时
  /// 中间两次触发纯属空转，而且实际节奏被量化到 60ms 网格上。
  Future<void> _frameLoop() async {
    while (_frameLoopOn && mounted && _mode == _RemoteMode.liveView) {
      // 连接失效立刻退出：否则 liveViewFrame 每次都立即抛异常，循环变成空转
      if (model.connState != 'connected') {
        AppLog.add('取景循环停止：连接已断开');
        return;
      }
      final sw = Stopwatch()..start();
      try {
        final f = await NikonEngine.liveViewFrame();
        if (!_frameLoopOn || !mounted) return;
        _notLvCount = 0;
        if (f.length > 2) {
          if (!_loggedFrameDiagnostics) {
            _loggedFrameDiagnostics = true;
            AppLog.add('取景帧诊断：${describeJpegFrame(f)}');
          }
          _applyAutoRotation(f);
          _frame.value = f;
          _recordGap(sw.elapsedMilliseconds);
        }
      } on PlatformException {
        _notLvCount++;
        if (_notLvCount >= 5) _restartLiveView();
      } catch (_) {
        // 单帧失败不中断循环
      }
      final spent = sw.elapsedMilliseconds;
      await Future<void>.delayed(
        Duration(milliseconds: spent < _minFrameGapMs ? _minFrameGapMs - spent : 0),
      );
    }
  }

  void _recordGap(int ms) {
    if (ms <= 0) return;
    _frameGaps.add(ms);
    if (_frameGaps.length > 12) _frameGaps.removeAt(0);
    if (_frameGaps.length < 4) return;
    final avg = _frameGaps.reduce((a, b) => a + b) / _frameGaps.length;
    _fps = avg > 0 ? (1000 / avg).round() : 0;
  }

  /// 取景掉线时重启一次。计数归零 + 3 秒节流：既能自愈，也不会对着死链路死命重试。
  void _restartLiveView() {
    _notLvCount = 0;
    // 已经断开时不要再往空连接上发取景指令：真机日志里出现过掉线期间
    // 连续发 0x9201 把 liveViewOn 又置回 true，导致断开时多打一次"已关闭"。
    if (model.connState != 'connected') return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLvRestartMs < 3000) return;
    _lastLvRestartMs = now;
    NikonEngine.liveViewStart().catchError((_) {});
  }

  // ------------------------------------------------------------ 画面方向

  static int _quarterFromExif(int? orientation) => switch (orientation) {
        3 => 2, // 180°
        6 => 1, // 顺时针 90°
        8 => 3, // 顺时针 270°
        _ => 0, // 1（正常）或没有标记
      };

  void _applyAutoRotation(Uint8List jpeg) {
    if (_rotationManual) return;
    final o = readExifOrientation(jpeg);
    final q = _quarterFromExif(o);
    if (q == _rotation || !mounted) return;
    AppLog.add('取景画面方向：EXIF orientation=${o ?? '无标记'} → 旋转 ${q * 90}°');
    setState(() => _rotation = q);
  }

  void _rotateManual() {
    setState(() {
      _rotation = (_rotation + 1) % 4;
      _rotationManual = true;
    });
  }

  void _rotationAuto() {
    setState(() {
      _rotationManual = false;
      _rotation = 0;
    });
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
        _startFrameLoop();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('实时取景启动失败：$e')));
        }
      } finally {
        if (mounted) setState(() => _lvStarting = false);
      }
    } else {
      _stopFrameLoop();
      await NikonEngine.liveViewStop().catchError((_) {});
      if (mounted) setState(() => _mode = m);
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
        // 对焦优先的说明含相机菜单路径，需要更长的展示时间才看得完
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('拍摄失败：$e'), duration: const Duration(seconds: 8)),
        );
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

  Future<void> _downloadLast() async {
    final f = _lastShot;
    if (f == null) return;
    setState(() => _downloadingLast = true);
    try {
      final r = await model.download([f]);
      if (mounted && r.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r)));
      }
    } finally {
      if (mounted) setState(() => _downloadingLast = false);
    }
  }

  void _openFullPreview(Uint8List bytes) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(_lastShot?.name ?? '预览', style: const TextStyle(fontSize: 15)),
          ),
          body: ZoomableImage(bytes: bytes, quarterTurns: _previewRotation),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 参数文案
  //
  // 参数来自 shotParams 的描述符（value/values/range/writable）。
  // 相机返回的原始值未必可信（实测出现过 f/0.6 这种物理上不存在的光圈），
  // 越界一律显示 --：宁可缺，不可错。

  num? _descValue(String name) {
    final d = _params?[name];
    if (d is! Map) return null;
    final v = d['value'];
    return v is num ? v : null;
  }

  String _fNumberValueText(num? v) {
    if (v == null || v <= 0) return '--';
    final f = v.toDouble() / 100; // PTP 标准：FNumber = f 值 × 100
    if (f < 0.7 || f > 64) return '--';
    return 'f/${f == f.roundToDouble() ? f.toStringAsFixed(0) : f.toStringAsFixed(1)}';
  }

  String _exposureValueText(num? v) {
    if (v == null || v <= 0) return '--';
    final s = v.toDouble() / 10000; // PTP 标准：ExposureTime 单位为 1/10000 秒
    if (s <= 0 || s > 900) return '--';
    if (s >= 1) return '${s.toStringAsFixed(s >= 10 ? 0 : 1)}s';
    return '1/${(10000 / v.toDouble()).round()}s';
  }

  String _fNumberText() => _fNumberValueText(_descValue('fNumber'));

  String _exposureText() => _exposureValueText(_descValue('exposureTime'));

  String _isoValueText(num? v) {
    final i = v?.toInt();
    if (i == null || i < 25 || i > 409600) return '--';
    return 'ISO $i';
  }

  String _isoText() => _isoValueText(_descValue('iso'));

  // ------------------------------------------------------------ 档位与可编辑性
  //
  // ExposureProgramMode：1=M 2=P 3=A 4=S；其他值（如 AUTO 场景）原样显示数字。
  // 置灰规则只是引导，相机仍是最终裁判——被拒时 setShotParam 会把 PtpException 提出来。

  String? _modeName() {
    final m = _params?['mode'];
    if (m is! Map) return null;
    final v = (m['value'] as num?)?.toInt();
    return switch (v) { 1 => 'M', 2 => 'P', 3 => 'A', 4 => 'S', _ => v?.toString() };
  }

  bool _paramWritable(String name) {
    final d = _params?[name];
    return d is Map && d['writable'] == true;
  }

  bool _paramEditable(String name) {
    if (!_paramWritable(name)) return false;
    switch (_modeName()) {
      case 'M':
        return true; // M：光圈/快门/ISO 全部可改
      case 'A':
        return name == 'fNumber'; // A：只改光圈
      case 'S':
        return name == 'exposureTime'; // S：只改快门
      default:
        return false; // P / AUTO / 未知：只读
    }
  }

  Future<void> _applyParam(String name, int value) async {
    try {
      final r = await NikonEngine.setShotParam(name, value);
      if (!mounted) return;
      final desc = r['desc'];
      if (desc is Map) {
        setState(() => _params = {...?_params, name: desc});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('设置失败：$e')));
      }
    }
    _loadParams(); // 设置可能联动其他参数，统一后台刷新
  }

  Future<void> _showParamEditor(String name) async {
    final d = _params?[name];
    if (d is! Map) return;
    final current = (d['value'] as num?)?.toInt() ?? 0;
    final values = ((d['values'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList()
      ..sort();
    final range = (d['range'] as List?)?.whereType<num>().map((e) => e.toInt()).toList();
    String fmt(int v) => switch (name) {
      'fNumber' => _fNumberValueText(v),
      'exposureTime' => _exposureValueText(v),
      _ => _isoValueText(v),
    };

    int? picked;
    if (values.isNotEmpty) {
      picked = await showModalBottomSheet<int>(
        context: context,
        backgroundColor: const Color(0xFF1C1C1E),
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final v in values)
                ListTile(
                  dense: true,
                  title: Text(fmt(v), style: TextStyle(
                    color: v == current ? const Color(0xFF3D7BFF) : Colors.white,
                    fontWeight: v == current ? FontWeight.w700 : FontWeight.w400,
                  )),
                  trailing: v == current ? const Icon(Icons.check, size: 18, color: Color(0xFF3D7BFF)) : null,
                  onTap: () => Navigator.pop(ctx, v),
                ),
            ],
          ),
        ),
      );
    } else if (range != null && range.length == 3) {
      // 范围型（min/max/step）：步进编辑器
      final min = range[0], max = range[1];
      final step = (range[2] == 0 ? 1 : range[2]);
      final r = await showModalBottomSheet<int>(
        context: context,
        backgroundColor: const Color(0xFF1C1C1E),
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSheet) {
            var v = current.clamp(min, max);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: v - step >= min ? () => setSheet(() => v -= step) : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(fmt(v), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      onPressed: v + step <= max ? () => setSheet(() => v += step) : null,
                      icon: const Icon(Icons.add),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, v),
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      picked = r;
    } else {
      return; // 无表也无范围：相机没给编辑信息，放弃
    }
    if (picked != null && picked != current) {
      await _applyParam(name, picked);
    }
  }

  // ------------------------------------------------------------ 装配

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final disconnected = model.connState != 'connected';
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: _immersive
              ? null
              : AppBar(
                  title: const Text('遥控拍摄'),
                  actions: [
                    if (_mode == _RemoteMode.liveView)
                      IconButton(
                        tooltip: _immersive ? '退出全屏' : '全屏取景',
                        icon: Icon(_immersive ? Icons.fullscreen_exit : Icons.fullscreen),
                        onPressed: () => setState(() => _immersive = !_immersive),
                      ),
                  ],
                ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _viewArea(disconnected)),
                if (!_immersive) _controlBar(disconnected),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _viewArea(bool disconnected) {
    if (disconnected) return const DisconnectedView(message: '连接已断开');
    return _mode == _RemoteMode.liveView ? _liveViewArea() : _blindArea();
  }

  /// 按当前旋转显示图片。
  ///
  /// 用 LayoutBuilder 拿到实际显示尺寸后按显示尺寸解码：取景帧每帧都是新数据，
  /// 必然重新解码一次，按显示尺寸解码（JPEG 缩放解码）能省掉一大半开销。
  Widget _orientedImage(Uint8List bytes, int rotation, {bool gapless = false}) {
    return LayoutBuilder(
      builder: (context, c) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // 旋转 90°/270° 时，图片的"宽"对应容器的"高"
        final shown = (rotation.isOdd ? c.maxHeight : c.maxWidth) * dpr;
        return RotatedBox(
          quarterTurns: rotation,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: gapless,
            cacheWidth: shown.isFinite && shown > 0 ? shown.round() : null,
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------ 实时取景

  Widget _liveViewArea() {
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: _frame,
      builder: (context, frame, _) {
        if (frame == null) return _waitingFrame();
        // StackFit.expand 给出紧约束：画面铺满可用区，BoxFit.contain 只做等比内缩，
        // 不再像此前那样被 Center 居中出现大片留白
        return Stack(
          fit: StackFit.expand,
          children: [
            // 点画面任意位置 = 驱动相机 AF（取景窗对焦）
            GestureDetector(
              onTap: _focus,
              child: ColoredBox(color: Colors.black, child: _orientedImage(frame, _rotation, gapless: true)),
            ),
            Positioned(
              left: 10,
              top: 10,
              child: _overlayChip('● LIVE ${_fps}fps'),
            ),
            if (model.battery >= 0)
              Positioned(
                right: 10,
                top: 10,
                child: _overlayChip('${model.battery}%'),
              ),
            Positioned(
              left: 10,
              bottom: 10,
              child: _overlayChip(
                '⟳ 旋转 ${_rotation * 90}°',
                tooltip: '点击旋转画面，长按恢复自动',
                onTap: _rotateManual,
                onLongPress: _rotationAuto,
              ),
            ),
            if (_immersive)
              Positioned(
                right: 10,
                bottom: 10,
                child: _overlayChip(
                  '⛶ 退出全屏',
                  onTap: () => setState(() => _immersive = false),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _waitingFrame() => Center(
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

  Widget _overlayChip(
    String text, {
    String? tooltip,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10.5, color: Colors.white70)),
    );
    if (tooltip != null) chip = Tooltip(message: tooltip, child: chip);
    if (onTap == null && onLongPress == null) return chip;
    return Semantics(
      button: true,
      label: tooltip ?? text,
      child: GestureDetector(onTap: onTap, onLongPress: onLongPress, child: chip),
    );
  }

  // ------------------------------------------------------------ 盲拍回看

  Widget _blindArea() {
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: _preview,
      builder: (context, preview, _) {
        if (preview == null) return _blindPlaceholder();
        return Column(
          children: [
            // 去掉写死宽度，改为铺满可用区；点击可全屏放大确认对焦
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Semantics(
                  button: true,
                  label: '查看刚拍摄的照片',
                  child: GestureDetector(
                    onTap: () => _openFullPreview(preview),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _orientedImage(preview, _previewRotation),
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: _overlayChip('⛶ 点击全屏'),
                        ),
                        if (_shotCount > 0)
                          Positioned(
                            left: 8,
                            top: 8,
                            child: _overlayChip('$_shotCount 张'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _lastShotBar(),
          ],
        );
      },
    );
  }

  Widget _blindPlaceholder() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 72, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              _shotCount == 0 ? '按下快门开始拍摄' : '等待照片…',
              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5)),
            ),
            if (_shotCount > 0) ...[
              const SizedBox(height: 6),
              Text('已拍摄 $_shotCount 张',
                  style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5))),
            ],
          ],
        ),
      );

  Widget _lastShotBar() {
    final f = _lastShot;
    final size = f?.size;
    final w = f?.width;
    final h = f?.height;
    final bits = <String>[
      if (size != null) formatBytes(size),
      if (w != null && h != null && w > 0) '$w×$h',
      if (_fNumberText() != '--') _fNumberText(),
      if (_exposureText() != '--') _exposureText(),
      if (_isoText() != '--') _isoText(),
    ];
    return Container(
      color: const Color(0xFF141414),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f?.name ?? '已拍摄照片',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                if (bits.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    bits.join('  ·  '),
                    style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.55)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          TextButton.icon(
            onPressed: (_downloadingLast || model.connState != 'connected') ? null : _downloadLast,
            icon: _downloadingLast
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_outlined, size: 18),
            label: const Text('存到手机', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 控制条

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
                _modeChip(),
                const SizedBox(width: 12),
                _paramChip('fNumber', _fNumberText()),
                const SizedBox(width: 12),
                _paramChip('exposureTime', _exposureText()),
                const SizedBox(width: 12),
                _paramChip('iso', _isoText()),
                const SizedBox(width: 12),
                _param(model.battery >= 0 ? '${model.battery}%' : '--'),
              ],
            ),
          ),
          // 拍后自动下载是"设置"而非"动作"，改用开关；此前只靠图标与颜色区分状态
          Row(
            children: [
              TextButton.icon(
                onPressed: disconnected ? null : _focus,
                icon: const Icon(Icons.center_focus_strong, size: 18),
                label: const Text('对焦', style: TextStyle(fontSize: 13)),
              ),
              const Spacer(),
              const Text('拍后自动下载', style: TextStyle(fontSize: 12.5)),
              Switch(
                value: _autoDownload,
                activeThumbColor: yellow,
                onChanged: (v) => setState(() => _autoDownload = v),
              ),
              const Spacer(),
              // 与左侧"对焦"等宽，保证快门居中
              const SizedBox(width: 72),
            ],
          ),
          GestureDetector(
            onTap: (disconnected || _shooting) ? null : _shoot,
            child: Semantics(
              button: true,
              label: '拍摄',
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: disconnected ? Colors.white24 : yellow, width: 4),
                ),
                child: Center(
                  child: _shooting
                      ? const SizedBox(
                          width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: disconnected ? Colors.white12 : yellow,
                          ),
                          child: const Center(
                            child: Text(
                              '拍摄',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _shooting && _capturePhase.isNotEmpty
                ? _phaseLabel(_capturePhase)
                : (_mode == _RemoteMode.liveView
                    ? '实时取景 · 照片将拍摄到存储卡'
                    : '盲拍模式 · 照片将拍摄到存储卡'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: _shooting ? yellow : Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _param(String text) => Text(
        text,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white70),
      );

  /// 可点击的参数 chip：按档位可编辑性点亮/置灰，点开编辑面板
  Widget _paramChip(String name, String text) {
    final editable = _paramEditable(name);
    return GestureDetector(
      onTap: editable ? () => _showParamEditor(name) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: editable ? const Color(0xFF3D7BFF) : Colors.white24),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: editable ? Colors.white : Colors.white38,
          ),
        ),
      ),
    );
  }

  /// 档位 chip（M/A/S/P/数字），无数据时显示 --
  Widget _modeChip() {
    final m = _modeName();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.white10,
      ),
      child: Text(
        m ?? '--',
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white70),
      ),
    );
  }
}
