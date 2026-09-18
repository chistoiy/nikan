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
import 'widgets/link_status.dart';
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
  bool _focusing = false;
  String? _afNote;
  Timer? _afNoteTimer;

  /// 对焦目标框（屏幕坐标）。**常驻**：点哪儿留哪儿，直到下一次点击。
  /// 此前是 1.4 秒淡出，用户看到的就是"手机端不显示焦点位置"——相机上的
  /// 对焦框一直亮着，手机上却一闪而过，两边对不上。
  Offset? _afTarget;

  /// 对焦状态：focusing（指令在途）/ focused（已指定该点）/ fallback（相机未接受，
  /// 回退到当前 AF 区域）/ failed（相机拒绝且 AF 也没驱动成功）
  String _afState = 'idle';
  (int, int)? _afSent; // 实际发给相机的坐标（标定与排错用）

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

  // ------------------------------------------------------------ 对焦倍数（自动）

  /// 从取景帧头部解出的自动倍数（相机图像尺寸 ÷ 取景帧尺寸），x/y 各一个。
  ///
  /// 头部实测（384B，大端 u16）：
  /// `off 8/10 = 640×424`（取景帧）、`off 12/14 = 5568×3712`（相机图像）。
  /// 相机 `0x9205` 的坐标空间就是后者，所以倍数 ≈ ×8.70 / ×8.76——
  /// 与用户实测"×8 大致一致"吻合。**这是读出来的，不用再靠肉眼估。**
  (double, double)? _afAuto;

  /// 用户是否手工覆盖了自动值（在标定面板里动过滑杆/点选）
  bool _afManualOverride = false;

  Future<void> _loadAfAutoScale() async {
    if (_afAuto != null) return;
    try {
      final r = await NikonEngine.afScaleFromHeader();
      if (r['ok'] != true) return;
      final sx = (r['scaleX'] as num).toDouble();
      final sy = (r['scaleY'] as num).toDouble();
      if (sx <= 0 || sy <= 0) return;
      _afAuto = (sx, sy);
      AppLog.addKey('对焦倍数已自动解出：${r['info']} → ×${sx.toStringAsFixed(2)}(x) ×${sy.toStringAsFixed(2)}(y)');
      if (mounted) setState(() {});
    } catch (e) {
      AppLog.addKey('读取自动对焦倍数失败：$e');
    }
  }

  /// 当前生效的对焦倍数（自动优先，人工覆盖时用人工值）
  (double, double) get _afScale {
    final a = _afAuto;
    if (a != null && !_afManualOverride) return a;
    final k = model.afAreaScale;
    return (k, k);
  }

  bool get _afScaleIsAuto => _afAuto != null && !_afManualOverride;

  Map<String, dynamic>? _params;

  _RemoteMode _mode = _RemoteMode.blind;

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _events = model.events.listen(_onEvent);
    _loadParams();
    _startParamsWatch();
  }

  @override
  void dispose() {
    _stopFrameLoop();
    _afNoteTimer?.cancel();
    _paramsTimer?.cancel();
    // 还原相机自己的息屏设置：我们只是"借用"了它的常亮（本机其实不支持，会如实失败）
    if (_keepAwakeOn) {
      NikonEngine.keepAwake(false).catchError((_) => <String, dynamic>{});
    }
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
    // 0x5007 光圈 / 0x500D 快门 / 0x500E 档位 / 0x500F ISO：相机自己改的（例如
    // S 档的自动光圈、Auto ISO 的自动 ISO）也要反映到手机上，否则用户会以为
    // 界面坏了。焦距之类界面不显示的码忽略。
    const watched = {0x5007, 0x500D, 0x500E, 0x500F};
    if (!watched.contains(code)) return;
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
      if (_lvPaused) {
        // 已暂停：不再向相机刷请求（每个请求都会失败并写日志，实测会冲掉 logcat），
        // 只等用户点「重新进入取景」。
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      final sw = Stopwatch()..start();
      try {
        final f = await NikonEngine.liveViewFrame();
        if (!_frameLoopOn || !mounted) return;
        _onFrameOk();
        if (f.length > 2) {
          if (!_loggedFrameDiagnostics) {
            _loggedFrameDiagnostics = true;
            AppLog.add('取景帧诊断：${describeJpegFrame(f)}');
          }
          _applyAutoRotation(f);
          // 记一次帧原始尺寸：点击对焦要把屏幕点换算回相机帧坐标（只取一次）
          if (_frameW == 0) {
            final d = jpegDimensions(f);
            if (d != null) {
              _frameW = d.$1;
              _frameH = d.$2;
            }
          }
          _frame.value = f;
          _recordGap(sw.elapsedMilliseconds);
          // 头部里有相机图像尺寸 → 自动解出对焦倍数（一次就够）
          unawaited(_loadAfAutoScale());
        }
      } on PlatformException catch (e) {
        _onFrameFail(e.message ?? '');
      } catch (_) {
        // 单帧失败不中断循环
      }
      final spent = sw.elapsedMilliseconds;
      await Future<void>.delayed(
        Duration(milliseconds: spent < _minFrameGapMs ? _minFrameGapMs - spent : 0),
      );
    }
  }

  /// 取到帧 → 一切正常，清掉所有故障标记
  void _onFrameOk() {
    _notLvCount = 0;
    _lvRestartFails = 0;
    // 顺带清掉"已关闭"记录：下次再出故障要能重新提示
    _dismissedProblem = null;
    if (_lvProblem != null && mounted) {
      setState(() => _lvProblem = null);
    } else {
      _lvProblem = null;
    }
  }

  /// 取帧失败：区分"相机没进取景"（NotLiveView）与其他错误。
  ///
  /// 真机证据（2026-09-15 22:28~22:29 日志）：相机离开取景态后，`0x9203` 会持续
  /// 返回 NotLiveView，而 `0x9201` 单独重发仍返回"成功"却不出帧——旧代码就在这个
  /// 循环里每帧打一条错误日志、UI 一直转圈，用户既不知道发生了什么也没法恢复。
  void _onFrameFail(String msg) {
    final notLv = msg.contains('NotLiveView');
    _notLvCount++;
    if (_notLvCount == 5) {
      setState(() => _lvProblem = notLv ? '相机未处于取景状态，正在重新进入…' : '取景画面中断，正在重试…');
    }
    // 每 5 次失败尝试一次"真的结束再启动"（内部有 3 秒节流）
    if (_notLvCount >= 5 && _notLvCount % 5 == 0) _restartLiveView();
    // 连打 3 轮仍回不来：停下自动重试，把决定权交给用户（并说明可能的原因）
    if (_notLvCount >= 25) {
      _lvPaused = true;
      _lvProblem = notLv
          ? '相机没有提供取景画面。请确认：相机不在回放/菜单界面、屏幕亮着未休眠、'
              '且相机上显示的是拍摄画面。然后点「重新进入取景」。'
          : '取景链路多次中断，已暂停自动重试。可点「重新进入取景」再试。';
      if (mounted) setState(() {});
    }
  }

  /// 取景掉线时重启。计数归零 + 3 秒节流：既能自愈，也不会对着死链路死命重试。
  bool _lvRestartInFlight = false;
  int _lvRestartFails = 0;

  /// 面向用户的取景故障说明（null = 正常）
  String? _lvProblem;

  /// 用户手动关掉过的故障文案。
  ///
  /// 与 [_lvProblem] 文案相等时不再显示——这样"关掉"是有效的，
  /// 但一旦**换了一条故障**（或取景恢复正常后又出问题）会重新弹出，
  /// 不会因为关过一次就再也看不到警告。
  String? _dismissedProblem;

  /// 自动重试已放弃（连续失败太多次）
  bool _lvPaused = false;

  void _restartLiveView() {
    // 已经断开时不要再往空连接上发取景指令：真机日志里出现过掉线期间
    // 连续发 0x9201 把 liveViewOn 又置回 true，导致断开时多打一次"已关闭"。
    if (model.connState != 'connected') return;
    // 失败瞬间客户端立即抛错会让计数飞速攒满：没有在途守卫时
    // 2ms 内连续重启 5 次（实测），全部打在死连接上。
    if (_lvRestartInFlight) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLvRestartMs < 3000) return;
    _lastLvRestartMs = now;
    _lvRestartInFlight = true;
    // 用"先结束再启动"而不是只发 0x9201：真机上 0x9201 会返回成功但不出帧，
    // 只有先 0x9202 结束才能真正重进（见 CameraEngine.liveViewRestart）。
    NikonEngine.liveViewRestart().then((_) {
      _lvRestartFails = 0;
      if (_cameraMaybeAsleep) {
        _cameraMaybeAsleep = false;
        AppLog.addKey('取景已恢复：相机不再处于待机');
        if (mounted) setState(() {});
      }
    }).catchError((Object e) {
      _lvRestartFails++;
      // 重进取景失败（0x9201 超时）在真机上就等于"相机在待机"——这个信号比参数读取
      // 更快也更准，所以直接判定，让故障卡片换标题直接告诉用户"去按相机按钮"。
      if (!_cameraMaybeAsleep) {
        _cameraMaybeAsleep = true;
        AppLog.addKey('重进取景失败 → 判定相机可能已待机');
      }
      AppLog.addKey('重新进入取景失败（第 $_lvRestartFails 次）：$e');
      if (mounted && _lvRestartFails >= 3) {
        _lvPaused = true;
        setState(() {
          _lvProblem = '重新进入取景连续失败：$e\n'
              '请确认相机不在回放/菜单界面且屏幕未休眠，再点「重新进入取景」。';
        });
      }
    }).whenComplete(() {
      _lvRestartInFlight = false;
    });
  }

  /// 用户手动重试取景
  Future<void> _retryLiveView() async {
    setState(() {
      _lvPaused = false;
      _notLvCount = 0;
      _lvRestartFails = 0;
      _lvProblem = '正在重新进入取景…';
    });
    try {
      await NikonEngine.liveViewRestart();
      if (!mounted) return;
      setState(() {
        _lvProblem = null;
        _cameraMaybeAsleep = false;
      });
      if (!_frameLoopOn) _startFrameLoop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _lvProblem = '重新进入取景失败：$e';
          _cameraMaybeAsleep = true; // 0x9201 超时 = 相机在待机（真机规律）
        });
      }
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
    // 防重入：事件与轮询会同时触发，不设守卫时实测 300ms 内跑 8 次
    // （每次 4 个 PTP 事务），日志也会重复刷同一行。
    if (_paramsLoading) return;
    _paramsLoading = true;
    try {
      final was = _lastParamValues;
      final p = await NikonEngine.shotParams();
      if (!mounted) return;
      setState(() => _params = p);
      if (_paramsFailStreak > 0 || _cameraMaybeAsleep) {
        _paramsFailStreak = 0;
        _cameraMaybeAsleep = false;
        AppLog.addKey('相机恢复响应（参数读取正常）');
      }
      _noteParamChanges(was, p);
    } catch (e) {
      // 不再静默：取景期间参数读取与取帧共用同一条串行通道，失败时界面会停在
      // 旧值上，用户只会看到"ISO 不同步"却无从判断原因（本次反馈就是这一条）。
      _paramsFailStreak++;
      if (_paramsFailStreak >= 3 && !_cameraMaybeAsleep) {
        _cameraMaybeAsleep = true;
        AppLog.addKey('相机连续 $_paramsFailStreak 次读不到参数：判定为可能已待机');
        if (mounted) setState(() {});
      }
      AppLog.addKey('参数刷新失败（第 $_paramsFailStreak 次）：$e');
    } finally {
      _paramsLoading = false;
    }
  }

  bool _paramsLoading = false;

  /// 连续读参数失败次数 / "相机可能已待机"判定。
  ///
  /// 相机待机（屏幕灭）后取景与快门都会被拒，而表象与"未对焦"一样，
  /// 用户完全看不出区别。参数读取连读失败是一个足够可靠的旁证——
  /// 有了它就能在用户按快门**之前**提醒："先按一下相机按钮"。
  int _paramsFailStreak = 0;
  bool _cameraMaybeAsleep = false;

  /// 参数值的上一次快照，用于记录"相机自己改了什么"
  Map<String, String> _lastParamValues = {};

  static const List<String> _watchedParams = ['fNumber', 'exposureTime', 'iso', 'exposureBias', 'mode'];

  void _noteParamChanges(Map<String, dynamic> was, Map<String, dynamic> now) {
    final cur = <String, String>{};
    for (final k in _watchedParams) {
      final d = now[k];
      final v = d is Map ? d['value'] : null;
      if (v != null) cur[k] = v.toString();
    }
    final diffs = <String>[];
    for (final e in cur.entries) {
      final old = was[e.key];
      if (old != null && old != e.value) diffs.add('${_paramLabel(e.key)} $old→${e.value}');
    }
    _lastParamValues = cur;
    if (diffs.isNotEmpty) AppLog.addKey('参数同步：${diffs.join("，")}');
  }

  static String _paramLabel(String k) => switch (k) {
        'fNumber' => '光圈',
        'exposureTime' => '快门',
        'iso' => 'ISO',
        'exposureBias' => '曝光补偿',
        'mode' => '档位',
        _ => k,
      };

  /// 参数轮询：相机在自动档下会自行改动（S 档自动光圈、Auto ISO 等），
  /// 只靠 DevicePropChanged 事件不够——真机上出现过事件到了但界面没跟上的情况。
  /// 2.5 秒一次、`shotParams` 共 4 个事务，对取景帧率影响可忽略。
  void _startParamsWatch() {
    _paramsTimer?.cancel();
    _paramsTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!mounted || model.connState != 'connected' || _shooting) return;
      _loadParams();
    });
  }

  Timer? _paramsTimer;

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
        unawaited(_enableKeepAwake());
      } catch (e) {
        if (mounted) {
          showNotice(context, '实时取景启动失败：$e');
        }
      } finally {
        if (mounted) setState(() => _lvStarting = false);
      }
    } else {
      _stopFrameLoop();
      await NikonEngine.liveViewStop().catchError((_) {});
      unawaited(_disableKeepAwake());
      if (mounted) setState(() => _mode = m);
    }
  }

  // ------------------------------------------------------------ 保持相机清醒
  //
  // 真机现象（2026-09-15）：相机空闲十几秒就息屏，之后 0x9201 返回成功但 0x9203
  // 恒 NotLiveView、0x9205 被接受却不生效——**必须手动按相机快门才醒**，
  // 遥控拍摄因此完全不可用。
  // 做法：把相机的「LCD 关闭」与「测光关闭」时间临时写到它允许的最大值，
  // 记住原值，退出遥控时还原（不偷偷改用户设置）。

  bool _keepAwakeOn = false;
  bool _keepAwakeWarned = false;

  Future<void> _enableKeepAwake() async {
    if (_keepAwakeOn) return;
    try {
      final r = await NikonEngine.keepAwake(true);
      final changed = (r['changed'] as List?)?.cast<String>() ?? const [];
      final failed = (r['failed'] as List?)?.cast<String>() ?? const [];
      _keepAwakeOn = changed.isNotEmpty;
      if (changed.isNotEmpty) {
        AppLog.addKey('相机屏幕常亮已开启：${changed.join("，")}');
        _flashAfNote('已保持相机屏幕常亮');
      }
      if (failed.isNotEmpty) {
        AppLog.addKey('相机屏幕常亮未生效：${failed.join("，")}');
        // 只提示一次：本机（Z50 II · Wi-Fi）这组属性全部不支持，每次进取景都弹会烦
        if (mounted && !_keepAwakeWarned) {
          _keepAwakeWarned = true;
          showNotice(
            context,
            '本机不支持由 App 延长相机息屏时间（探针实测 0xD064/0xD062 等均"不支持"）。\n'
            '相机待机后遥控会失效，请在相机菜单把「电源关闭延迟」调长：\n'
            'MENU → ✏️自定义设定菜单 → c3 电源关闭延迟。',
            duration: const Duration(seconds: 12),
          );
        }
      }
    } catch (e) {
      AppLog.addKey('相机屏幕常亮请求失败：$e');
    }
  }

  Future<void> _disableKeepAwake() async {
    if (!_keepAwakeOn) return;
    _keepAwakeOn = false;
    try {
      await NikonEngine.keepAwake(false);
    } catch (_) {}
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
        // 对焦优先的说明含相机菜单路径，需要更长的展示时间才看得完。
        // 这类长文案尤其需要"点一下就能关"——否则它会在底部挡 8 秒。
        showNotice(context, '拍摄失败：$e', duration: const Duration(seconds: 8));
      }
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<void> _focus() async {
    if (_focusing) return;
    setState(() => _focusing = true);
    try {
      final r = await NikonEngine.afDrive();
      if (!mounted) return;
      if (r['ok'] == true) {
        // 成功也要有反馈：AUTO / 场景自动档下相机接管对焦，画面可能毫无变化，
        // 只静默返回会让用户以为"点了没反应"（这正是本次反馈的现象）。
        _flashAfNote('AF 指令已发送');
      } else {
        _flashAfNote('对焦失败');
        final mode = _modeName();
        showNotice(
          context,
          '对焦未能驱动：${r['reason'] ?? '相机未响应'}'
          '${mode != null ? '\n当前档位：$mode' : ''}\n$kAfHint',
          duration: const Duration(seconds: 8),
        );
      }
    } catch (e) {
      if (mounted) {
        _flashAfNote('对焦失败');
        showNotice(context, '对焦失败：$e');
      }
    } finally {
      if (mounted) setState(() => _focusing = false);
    }
  }

  /// 取景帧的原始像素尺寸（用于把屏幕点击点换算成相机坐标）
  int _frameW = 0;
  int _frameH = 0;

  /// 点击取景画面：指定该点为对焦点并驱动 AF。
  ///
  /// 三步换算：屏幕点 → 去掉 letterbox（BoxFit.contain）→ 反旋转回帧坐标，
  /// 再乘上 [AppModel.afAreaScale]（见下）。
  ///
  /// **坐标空间**：`0x9205 ChangeAfArea` 只写了"2 参数 x, y"，没有文档说坐标系。
  /// 我们按取景帧像素（实测 640×424）发送时相机**接受**了坐标，但对焦点落到别处
  /// ——典型的"同比例不同尺度"。因此这里乘一个可标定的系数（默认 1.0，
  /// 长按取景画面可实时标定），而不是继续猜。
  Future<void> _focusAt(Offset local, Size box) async {
    final pt = _framePointFor(local, box);
    if (pt == null) return;
    // 先落地"我点了这里"，再发指令：指令在途时也要能看到对焦框
    setState(() {
      _afTarget = local;
      _afState = 'focusing';
      _afSent = pt;
    });
    if (_focusing) return;
    setState(() => _focusing = true);
    try {
      final r = await NikonEngine.afArea(pt.$1, pt.$2);
      if (!mounted) return;
      if (r['ok'] == true && r['area'] == true) {
        setState(() => _afState = 'focused');
        _flashAfNote('已对焦该点 (${pt.$1},${pt.$2})');
      } else if (r['ok'] == true) {
        // 相机接受了指令但拒绝了坐标：如实标注，不要假装对焦框就是生效位置
        setState(() => _afState = 'fallback');
        _flashAfNote('相机未接受指定点，已按当前 AF 区域对焦');
      } else {
        setState(() => _afState = 'failed');
        _flashAfNote('对焦失败');
        showNotice(
          context,
          '对焦未能驱动：${r['reason'] ?? '相机未响应'}\n$kAfHint',
          duration: const Duration(seconds: 8),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _afState = 'failed');
        _flashAfNote('对焦失败');
      }
    } finally {
      if (mounted) setState(() => _focusing = false);
    }
  }

  /// 屏幕坐标 → 相机坐标；点在黑边上返回 null。
  (int, int)? _framePointFor(Offset local, Size box) {
    final fw = _frameW, fh = _frameH;
    if (fw <= 0 || fh <= 0 || box.width <= 0 || box.height <= 0) return null;
    // 旋转奇数次时，显示出来的宽高是帧的高宽
    final dispW = _rotation.isOdd ? fh.toDouble() : fw.toDouble();
    final dispH = _rotation.isOdd ? fw.toDouble() : fh.toDouble();
    final scale = (box.width / dispW) < (box.height / dispH)
        ? box.width / dispW
        : box.height / dispH;
    final shownW = dispW * scale, shownH = dispH * scale;
    final dx = local.dx - (box.width - shownW) / 2;
    final dy = local.dy - (box.height - shownH) / 2;
    if (dx < 0 || dy < 0 || dx > shownW || dy > shownH) return null; // 黑边
    final ix = dx / scale, iy = dy / scale; // 旋转后的显示坐标
    // 反旋转（RotatedBox 顺时针转 _rotation×90°）
    double fx, fy;
    switch (_rotation % 4) {
      case 1:
        fx = iy;
        fy = fh - 1 - ix;
      case 2:
        fx = fw - 1 - ix;
        fy = fh - 1 - iy;
      case 3:
        fx = fw - 1 - iy;
        fy = ix;
      default:
        fx = ix;
        fy = iy;
    }
    // 缩放到相机实际的 AF 坐标空间：自动倍数（取景帧头部解出）优先，人工覆盖时用人工值
    final (kx, ky) = _afScale;
    return (
      (fx * kx).round().clamp(0, 200000),
      (fy * ky).round().clamp(0, 200000),
    );
  }

  /// 对焦动作的短暂反馈（显示在取景画面左上角的 chip 位）。
  /// 用页面内 chip 而不是 SnackBar：连续点击时 SnackBar 会排队堆叠。
  void _flashAfNote(String text) {
    _afNoteTimer?.cancel();
    setState(() => _afNote = text);
    _afNoteTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _afNote = null);
    });
  }

  // ------------------------------------------------------------ 对焦坐标标定

  /// 长按取景画面进入：滑动缩放系数 → 「发送测试点」→ 看相机屏幕上的对焦框
  /// 是否落在画面 1/4 处。找到正确的系数后保存，之后所有点击都用它换算。
  Future<void> _showAfCalibration() async {
    if (_afCalibrating) return;
    _afCalibrating = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF1C1C1E),
        isScrollControlled: true,
        builder: (ctx) => _afCalibrationSheet(ctx),
      );
    } finally {
      _afCalibrating = false;
    }
  }

  bool _afCalibrating = false;

  Widget _afCalibrationSheet(BuildContext ctx) {
    final fw = _frameW > 0 ? _frameW : 640;
    final fh = _frameH > 0 ? _frameH : 424;
    var busy = false;
    String? result;
    return StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('对焦标定', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              // 自动值优先：倍数是从取景帧头部里读出来的，不需要肉眼估
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF22262E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _afScaleIsAuto ? kAccent.withValues(alpha: 0.6) : Colors.white24,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _afAuto != null
                          ? '自动解出（取景帧头部）：×${_afAuto!.$1.toStringAsFixed(2)}（x）'
                              ' ×${_afAuto!.$2.toStringAsFixed(2)}（y）'
                          : '未取到取景帧头部 → 只能人工标定',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _afScaleIsAuto ? kAccent : Colors.white70,
                      ),
                    ),
                    if (_afAuto != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _afManualOverride ? '当前已改为人工值，自动值被覆盖' : '当前按自动值换算，通常无需再调',
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ],
                ),
              ),
              if (_afManualOverride)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () {
                      setState(() => _afManualOverride = false);
                      setSheet(() {});
                    },
                    child: const Text('恢复自动值'),
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                '下面是**人工覆盖**（自动值不可用、或想微调时用）：发一个测试点，'
                '看相机屏幕上对焦框落在画面哪里，点选对应位置即可反推倍数。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Colors.white.withValues(alpha: 0.6)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() => busy = true);
                              try {
                                // 固定发"画面 1/4 处"的原始帧坐标（=160,106）
                                await NikonEngine.afArea(fw ~/ 4, fh ~/ 4);
                                setSheet(() => result = '已发送测试点 (${fw ~/ 4}, ${fh ~/ 4})：'
                                    '看相机上的对焦框落在画面哪里？');
                              } catch (e) {
                                setSheet(() => result = '发送失败：$e');
                              } finally {
                                setSheet(() => busy = false);
                              }
                            },
                      icon: const Icon(Icons.send, size: 16),
                      label: const Text('发送测试点'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text('相机上的对焦框落在：',
                  style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6))),
              const SizedBox(height: 6),
              // 发的是"画面 1/4 处"：落点比例 f 直接给出倍数 = 0.25 / f
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final opt in const [
                    (label: '正中（1/2）', frac: 0.5),
                    (label: '1/4 处', frac: 0.25),
                    (label: '1/8 处', frac: 0.125),
                    (label: '1/16 处', frac: 0.0625),
                    (label: '1/32 处', frac: 0.03125),
                    (label: '顶在最左/最上', frac: 0.0),
                  ])
                    ActionChip(
                      label: Text(opt.label, style: const TextStyle(fontSize: 11.5)),
                      backgroundColor: const Color(0xFF2A2D35),
                      onPressed: () async {
                        final k = opt.frac <= 0 ? 12.0 : (0.25 / opt.frac);
                        final v = k.clamp(0.25, 16).toDouble();
                        await model.setAfAreaScale(v);
                        setState(() => _afManualOverride = true);
                        setSheet(() {});
                        _flashAfNote('已改为人工倍数 ×${v.toStringAsFixed(2)}');
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('当前生效倍数', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text(
                    _afScaleIsAuto
                        ? '×${_afScale.$1.toStringAsFixed(2)}（自动）'
                        : '×${_afScale.$1.toStringAsFixed(2)}（人工）',
                    style: const TextStyle(fontSize: 13, color: kAccent, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Slider(
                value: model.afAreaScale.clamp(0.5, 16),
                min: 0.5,
                max: 16,
                divisions: 62,
                label: model.afAreaScale.toStringAsFixed(2),
                activeColor: kAccent,
                onChanged: (v) {
                  model.setAfAreaScale(v);
                  setState(() => _afManualOverride = true);
                  setSheet(() {});
                },
              ),
              const SizedBox(height: 12),
              Text('取景帧 $fw×$fh · 测试点 = (${fw ~/ 4}, ${fh ~/ 4})（画面 1/4 处）',
                  style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() => busy = true);
                              try {
                                final r = await NikonEngine.probeAfArea(fw, fh);
                                for (final line in r) {
                                  AppLog.add('AF标定 $line');
                                }
                                setSheet(() => result = r.isEmpty ? '无输出' : r.join('\n'));
                              } catch (e) {
                                setSheet(() => result = '探针失败：$e');
                              } finally {
                                setSheet(() => busy = false);
                              }
                            },
                      child: const Text('跑标定探针'),
                    ),
                  ),
                ],
              ),
              if (result != null) ...[
                const SizedBox(height: 10),
                Text(result!, style: const TextStyle(fontSize: 11.5, height: 1.5, color: kAccent)),
              ],
              const Divider(height: 22),
              // 防待机"戳一下"已实测无效（每 15 秒发 DeviceReady + 重发对焦点，屏幕照灭），
              // 所以把开关撤掉——留一个没用的开关比没有更糟。这里只留事实与出路。
              Text(
                '关于相机息屏\n'
                '本机在 Wi-Fi 智能设备模式下不提供任何息屏/待机属性'
                '（0xD064/0xD062/0xD066/0xD0B3 探针实测全为"不支持"），'
                '定时发协议活动也留不住屏幕（已实测无效）。'
                '唯一有效的是改相机设置：MENU → ✏️自定义设定菜单 → c3「电源关闭延迟」→ 选更长时间。',
                style: TextStyle(fontSize: 11.5, height: 1.6, color: Colors.white.withValues(alpha: 0.6)),
              ),
              const Divider(height: 22),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('完成'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () async {
                      await model.setAfAreaScale(4.0);
                      setSheet(() {});
                      if (context.mounted) setState(() {});
                    },
                    child: const Text('恢复 ×4'),
                  ),
                ],
              ),
              Text(
                '相机不提供"AF 坐标空间尺寸"属性（0xD0xx 探针实测全"不支持"），所以读不到、'
                '只能这样测一次；结果会记住，之后点画面就按它换算。\n'
                '验证：点画面正中 → 相机上的对焦框应落在正中。',
                style: const TextStyle(fontSize: 11.5, height: 1.5, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// AF 驱动失败时的可行动建议。
  ///
  /// 真机证据（交接文档 §19/§20）：AF 驱动是 0x90C1（libgphoto2 定义），旧的 0x90C3
  /// 其实是 DelImageSDRAM（要求 1 个参数），所以必然 ParameterNotSupported。
  /// 这条提示留给"码对了但相机仍拒绝"的情况——最常见的是档位/对焦模式限制，
  /// 不能只丢一句"对焦失败或不支持"给用户。
  static const String kAfHint =
      '· 直接按「拍摄」——相机会自行完成对焦，不必手动驱动\n'
      '· AUTO / 场景自动档下对焦由相机接管，需切到 P/A/S/M 才能手动驱动\n'
      '· 镜头在 MF 时不支持 AF 驱动';

  Future<void> _downloadLast() async {
    final f = _lastShot;
    if (f == null) return;
    setState(() => _downloadingLast = true);
    try {
      final r = await model.download([f]);
      if (mounted && r.isNotEmpty) {
        showNotice(context, r);
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

  /// 曝光补偿：0x5010，单位 1/1000 EV，dtype=INT16（负值以 u16 补码返回，
  /// 属性 Dump 里能看到 60536 这类值 = -5000）。
  int? _exposureBiasRaw() {
    final v = _descValue('exposureBias');
    if (v == null) return null;
    final i = v.toInt();
    return i > 32767 ? i - 65536 : i;
  }

  String _biasText() {
    final v = _exposureBiasRaw();
    if (v == null) return '--';
    if (v == 0) return '±0EV';
    final ev = v / 1000.0;
    return '${ev > 0 ? '+' : '−'}${ev.abs().toStringAsFixed(ev.abs() % 1 == 0 ? 0 : 1)}EV';
  }

  // ------------------------------------------------------------ 档位与可编辑性
  //
  // ExposureProgramMode：1=M 2=P 3=A 4=S；其他值（如 AUTO 场景）原样显示数字。
  // 置灰规则只是引导，相机仍是最终裁判——被拒时 setShotParam 会把 PtpException 提出来。

  /// 档位名。0x500E = ExposureProgramMode（属性 Dump 已确认可读），
  /// 但**尼康枚举顺序与标准 PTP 的 1=M/2=P/3=A/4=S 是否一致无法只靠 Dump 断定**，
  /// 所以再叠一层自校准：用"哪个参数可写"反推档位（M=都可写、S=仅快门、
  /// A=仅光圈、P/AUTO=都不可写），与数字名不一致时以可写性为准并写日志。
  String? _modeName() {
    final m = _params?['mode'];
    if (m is! Map) return null;
    final v = (m['value'] as num?)?.toInt();
    if (v == null) return null;
    final byNumber = switch (v) {
      1 => 'M',
      2 => 'P',
      3 => 'A',
      4 => 'S',
      // 尼康厂商扩展档位（真机实测：用户确认 32784=AUTO、32792=SCN）
      32784 => 'AUTO',
      32792 => 'SCN',
      _ => null,
    };
    final byWritable = _modeFromWritability();
    if (byNumber != null && byWritable != null && byNumber != byWritable) {
      AppLog.add('档位名冲突：0x500E=$v → $byNumber，但可写性显示 $byWritable（按 $byWritable 显示）');
      return byWritable;
    }
    return byWritable ?? byNumber ?? v.toString();
  }

  /// 由"光圈/快门是否可写"反推档位（不依赖厂商枚举顺序）。
  String? _modeFromWritability() {
    final f = _paramWritable('fNumber');
    final s = _paramWritable('exposureTime');
    if (!f && !s) return null; // P/AUTO 或不支持写入：无法区分，交给数字
    if (f && s) return 'M';
    if (s) return 'S';
    return 'A';
  }

  bool _paramWritable(String name) {
    final d = _params?[name];
    return d is Map && d['writable'] == true;
  }

  bool _paramEditable(String name) {
    if (!_paramWritable(name)) return false;
    // 曝光补偿的"能不能改"完全由相机自己的可写标志决定（P/S/A 可，M 通常不可），
    // 不必再叠档位规则——相机是最终裁判，写错了会被拒。
    if (name == 'exposureBias') return true;
    switch (_modeName()) {
      case 'M':
        return true; // M：光圈/快门/ISO 全部可改
      case 'A':
        return name == 'fNumber'; // A：只改光圈
      case 'S':
        return name == 'exposureTime'; // S：只改快门
      case 'P':
        return name == 'exposureBias'; // P：可改曝光补偿
      default:
        return false; // AUTO / 未知：只读
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
        showNotice(context, '设置失败：$e');
      }
    }
    _loadParams(); // 设置可能联动其他参数，统一后台刷新
  }

  Future<void> _showParamEditor(String name) async {
    final d = _params?[name];
    if (d is! Map) return;
    final current = (d['value'] as num?)?.toInt() ?? 0;
    // 曝光补偿的枚举表是 u16 补码（60536 其实是 -5000），先归一化再排序，
    // 否则列表会从 +5EV 开始往下排、负值全跑到末尾。
    int norm(int v) => name == 'exposureBias' && v > 32767 ? v - 65536 : v;
    final cur = norm(current);
    final values = ((d['values'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => norm(e.toInt()))
        .toList()
      ..sort();
    final range = (d['range'] as List?)?.whereType<num>().map((e) => norm(e.toInt())).toList();
    String fmt(int v) => switch (name) {
      'fNumber' => _fNumberValueText(v),
      'exposureTime' => _exposureValueText(v),
      'exposureBias' => (() {
          if (v == 0) return '±0EV';
          final ev = v / 1000.0;
          return '${ev > 0 ? '+' : '−'}${ev.abs().toStringAsFixed(ev.abs() % 1 == 0 ? 0 : 1)}EV';
        })(),
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
                    color: v == cur ? const Color(0xFF3D7BFF) : Colors.white,
                    fontWeight: v == cur ? FontWeight.w700 : FontWeight.w400,
                  )),
                  trailing: v == cur ? const Icon(Icons.check, size: 18, color: Color(0xFF3D7BFF)) : null,
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
            var v = cur.clamp(min, max);
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
    if (picked != null && picked != cur) {
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
                    // 取景卡住时最需要这个：一眼看出是相机忙还是链路断了
                    LinkStatusButton(model: model),
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
                // 相机疑似待机时的提前提醒：待机后取景与快门都会被拒，
                // 而表象与"未对焦"一样，等用户按了快门才发现就太晚了。
                if (!disconnected && _cameraMaybeAsleep) _asleepBanner(),
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
    if (disconnected) return DisconnectedView(message: model.connStateText);
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
        return LayoutBuilder(
          builder: (context, cons) {
            final box = Size(cons.maxWidth, cons.maxHeight);
            return Stack(
              fit: StackFit.expand,
              children: [
                // 点画面任意位置 = 指定该点为对焦点并驱动 AF；长按 = 对焦坐标标定
                GestureDetector(
                  onTapUp: (d) => _focusAt(d.localPosition, box),
                  onLongPress: _showAfCalibration,
                  child: ColoredBox(color: Colors.black, child: _orientedImage(frame, _rotation, gapless: true)),
                ),
                // 对焦点指示：**常驻**，颜色即状态（相机上的对焦框也是一直亮着的）
                if (_afTarget != null)
                  Positioned(
                    left: _afTarget!.dx - 26,
                    top: _afTarget!.dy - 26,
                    child: IgnorePointer(child: _AfCrosshair(state: _afState)),
                  ),
                // 取景故障面板：说清"为什么没有画面"以及怎么办（此前只有一个转圈）。
                // 可关闭：点卡片外的遮罩、点右上角 ×、或点两个操作按钮都行——
                // 此前只有"唤醒并重进/切到盲拍"两条路，想先看一眼画面再决定都做不到。
                if (_lvProblem != null && _lvProblem != _dismissedProblem)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _dismissedProblem = _lvProblem),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.42),
                        child: Center(
                          child: GestureDetector(
                            // 卡片自身的点击不透传给遮罩，避免点在文字上就被关掉
                            onTap: () {},
                            child: _lvProblemCard(_lvProblem!),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 相机没接受指定点时，把实际发出去的坐标摆出来（排错的第一手证据）
                if (_afSent != null && (_afState == 'fallback' || _afState == 'failed'))
                  Positioned(
                    right: 10,
                    top: 38,
                    child: _overlayChip('发送坐标 (${_afSent!.$1},${_afSent!.$2})'),
                  ),
            Positioned(
              left: 10,
              top: 10,
              child: _overlayChip('● LIVE ${_fps}fps'),
            ),
            // 点击画面 = AF。对焦指令在途时给出可见反馈：AF 驱动到合焦之间
            // 相机没有画面变化，没有这个提示用户会以为点击没生效。
            if (_focusing)
              Positioned(
                left: 10,
                top: 38,
                child: _overlayChip('AF 对焦中…'),
              )
            else if (_afNote != null)
              Positioned(
                left: 10,
                top: 38,
                child: _overlayChip(_afNote!),
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
            // 对焦坐标标定入口：相机接受了坐标却把对焦点放在别处时用它校准
            Positioned(
              left: 10,
              bottom: 40,
              child: _overlayChip(
                '🎯 标定对焦',
                tooltip: '相机上的对焦框与点击位置不一致时，点这里校准坐标缩放',
                onTap: _showAfCalibration,
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
      },
    );
  }

  Widget _waitingFrame() {
    // 一直转圈是最糟的反馈：用户分不清"在连"与"已经失败"。
    // 一旦判定取景有问题，就把原因和恢复入口直接摆出来。
    if (_lvProblem != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _lvProblemCard(_lvProblem!),
        ),
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

  /// 相机疑似待机时的横幅（含一键唤醒尝试）。
  ///
  /// 判据是"连续 3 次读不到参数"，不是猜——相机待机后取景与快门都会被拒，
  /// 表象与"未对焦"一样，等用户按了快门才发现就太晚了。
  Widget _asleepBanner() => Container(
        width: double.infinity,
        color: const Color(0xFF3A2A18),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.bedtime_outlined, size: 16, color: Color(0xFFE5A08A)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '相机可能已进入待机（屏幕灭）：此时取景与快门都会被拒。\n'
                '按一下相机任意按钮即可恢复；长期方案见「🎯 标定对焦」里的说明。',
                style: TextStyle(fontSize: 11.5, height: 1.45, color: Color(0xFFE5A08A)),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
              onPressed: () async {
                await NikonEngine.wakeUp();
                await _loadParams();
              },
              child: const Text('尝试唤醒', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  /// 取景故障卡片：原因 + 「唤醒并重进取景」+ 「切到盲拍」+ 右上角关闭。
  ///
  /// 真机结论（2026-09-15）：相机待机（屏幕灭）后，`0x9201` 仍回成功但 `0x9203`
  /// 恒 NotLiveView、`0x9205` 被接受却不生效；且本机不支持修改息屏时间
  /// （0xD064/0xD062/0xD066/0xD0B3 全部"不支持"）。所以这里必须把话说全：
  /// **PTP 侧不一定叫得醒它**，要按相机按钮/调菜单；同时给出"盲拍"这条不带取景的活路。
  ///
  /// **必须有明确的关闭入口**：用户经常只是"想先看一眼、再决定要不要重试"，
  /// 而这张卡片盖在取景画面上，关不掉就等于挡住了唯一的信息来源。
  Widget _lvProblemCard(String msg) => Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5A08A)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.videocam_off_outlined, size: 22, color: Color(0xFFE5A08A)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: '关闭提示（不会重进取景）',
                  visualDensity: VisualDensity.compact,
                  color: Colors.white70,
                  onPressed: () => setState(() => _dismissedProblem = _lvProblem),
                ),
              ],
            ),
            if (_cameraMaybeAsleep) ...[
              const SizedBox(height: 2),
              const Text('相机可能已进入待机（屏幕灭）',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFE5A08A))),
            ],
            const SizedBox(height: 8),
            Text(msg,
                style: const TextStyle(fontSize: 12.5, height: 1.5),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              '相机待机（屏幕灭）后取景通道会失效，而且**连快门也会被拒**'
              '（实测持续 DeviceBusy，表象与"未对焦"一样）：\n'
              '· 按一下相机任意按钮唤醒后即可继续；\n'
              '· 长期方案：MENU → ✏️自定义设定菜单 → c3「电源关闭延迟」→ 选更长时间'
              '（本机 Wi-Fi 模式下 App 改不了它）。',
              style: TextStyle(fontSize: 11.5, height: 1.55, color: Colors.white.withValues(alpha: 0.7)),
              textAlign: TextAlign.left,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: _retryLiveView,
                    child: const Text('唤醒并重进'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () => _switchMode(_RemoteMode.blind),
                    child: const Text('切到盲拍'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '点卡片外、或右上角 × 可关闭本提示（不会重进取景）',
              style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.5)),
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
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                _modeChip(),
                _paramChip('fNumber', _fNumberText()),
                _paramChip('exposureTime', _exposureText()),
                _paramChip('iso', _isoText()),
                _paramChip('exposureBias', _biasText()),
                _param(model.battery >= 0 ? '${model.battery}%' : '--'),
              ],
            ),
          ),
          // 拍后自动下载是"设置"而非"动作"，改用开关；此前只靠图标与颜色区分状态
          Row(
            children: [
              TextButton.icon(
                onPressed: (disconnected || _focusing) ? null : _focus,
                icon: _focusing
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.center_focus_strong, size: 18),
                label: Text(_focusing ? '对焦中' : '对焦', style: const TextStyle(fontSize: 13)),
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

  /// 档位 chip（M/A/S/P/AUTO/SCN），无数据时显示 --
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

/// 对焦点指示：一个方框 + 中心点，**常驻**（相机上的对焦框也是一直亮着的，
/// 只在手机上闪 1.4 秒会让用户觉得"手机端不显示焦点位置"）。
///
/// 颜色即状态：
/// - `focusing` 白色（指令在途，附"对焦中"小字）
/// - `focused`  尼康黄（已指定该点）
/// - `fallback` 暖橙（相机接受了指令但拒绝坐标，实际按当前 AF 区域对焦）
/// - `failed`   红色（对焦未驱动成功）
class _AfCrosshair extends StatelessWidget {
  const _AfCrosshair({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      'focusing' => (Colors.white, '对焦中'),
      'focused' => (kAccent, null),
      'fallback' => (const Color(0xFFE5A08A), '未接受该点'),
      'failed' => (const Color(0xFFE5484D), '对焦失败'),
      _ => (Colors.white70, null),
    };
    return SizedBox(
      width: 52,
      height: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: 2),
                  borderRadius: BorderRadius.circular(4),
                  color: color.withValues(alpha: 0.06),
                ),
              ),
              Container(width: 4, height: 4, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            ],
          ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 9.5,
                  color: color,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
