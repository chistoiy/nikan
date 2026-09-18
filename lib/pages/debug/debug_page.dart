import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/app_log.dart';
import '../../engine/nikon_engine.dart';
import '../../util/format.dart';
import '../widgets/app_widgets.dart';
import 'capability_sheet.dart';
import 'debug_log_card.dart';

/// 协议调试面板（保留用于问题排查），可独立成页或嵌入设置页。
///
/// 验证路径：连相机热点 → 扫描 → 握手 → 枚举 → 缩略图 → 分块下载落盘。
class DebugPanel extends StatefulWidget {
  const DebugPanel({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

/// 独立成页的包装（当前入口在设置页内）
class DebugPage extends StatelessWidget {
  const DebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('协议验证面板')), body: const DebugPanel());
  }
}

/// 一个协议探针。handle 取首个已枚举文件（不需要的探针忽略该参数）。
class _Probe {
  const _Probe({
    required this.label,
    required this.run,
    this.detail,
    this.needsFiles = false,
    this.destructive = false,
  });

  /// 按钮文字
  final String label;

  /// 日志与运行说明（含操作码），缺省时用按钮文字
  final String? detail;

  final Future<List<String>> Function(int handle) run;

  /// 需要先枚举出文件，卡内为空时禁用
  final bool needsFiles;

  /// 会真实改变相机状态（实拍/写入存储卡），运行前二次确认。
  /// 此前破坏性探针与只读探针按钮外观完全一致，误触就会往用户卡里拍照。
  final bool destructive;

  String get title => detail ?? label;
}

class _DebugPanelState extends State<DebugPanel> {
  bool _busy = false;
  bool _connected = false;
  final TextEditingController _ipCtrl = TextEditingController(text: '192.168.1.1');
  final TextEditingController _nameCtrl =
      TextEditingController(text: 'Nikon Wireless Mobile Utility');

  Map<String, dynamic>? _wifi;
  List<String> _found = [];
  Map<String, dynamic>? _camera;
  Map<String, dynamic>? _enumResult;
  final List<Uint8List> _thumbs = [];
  Map<String, dynamic>? _downloadResult;
  String? _enumSummary;
  double? _progress; // null = 无下载进行中
  String _progressText = '';

  /// 探针表：原先 9 个几乎相同的包装方法 + 15 个按钮，收敛成一份声明
  static final List<_Probe> _probes = [
    _Probe(
      label: '试验:高速下载',
      detail: '高速下载探针 0x9400~0x9406',
      needsFiles: true,
      run: NikonEngine.probeHiSpeed,
    ),
    _Probe(
      label: '无线测速',
      detail: '把选中的文件真传一遍（数据丢弃、不落盘），报告平均吞吐 + 频段 + 协商速率，'
          '并判读"还有没有提速空间"。挑一张 10~30MB 的照片跑，'
          '在「相机 AP 模式」与「相机 STA 模式（接入 5GHz 路由器）」各跑一次即可对比。',
      needsFiles: true,
      run: NikonEngine.probeLinkThroughput,
    ),
    _Probe(
      label: '试验:相机缩放',
      detail: '相机端缩放探针 0x9207',
      needsFiles: true,
      run: NikonEngine.probeResize,
    ),
    _Probe(
      label: '试验:取景',
      detail: '实时取景探针 0x9200~0x9203',
      run: (_) => NikonEngine.probeLiveView(),
    ),
    _Probe(
      label: '试验:取景帧尺寸',
      detail: '取景帧尺寸探针（候选帧通道逐个试，报告 JPEG 像素尺寸）',
      run: (_) => NikonEngine.probeLvFrames(),
    ),
    _Probe(
      // USB 测速不放这里：它是独立实验，有自己的卡片（_usbCard）。
      // 埋在十几个按钮的最后一位等于没人找得到——上一轮就发生过。
      label: '试验:取景2',
      detail: '实时取景链路探针2（0x9206→拉帧→0x9201）',
      run: (_) => NikonEngine.probeLiveView2(),
    ),
    _Probe(
      label: '试验:取景3',
      detail: '取景中候选操作响应码探针',
      needsFiles: true,
      run: NikonEngine.probeLiveView3,
    ),
    _Probe(
      label: '试验:取景4',
      detail: '取景状态机探针（含 0x9400 对焦后行为）',
      needsFiles: true,
      destructive: true,
      run: NikonEngine.probeLiveView4,
    ),
    _Probe(
      label: '试验:LV对焦',
      detail: '取景中 AF/拍摄通道探针',
      needsFiles: true,
      destructive: true,
      run: NikonEngine.probeLvAf,
    ),
    _Probe(
      label: '属性码Dump',
      detail: '读取全部设备属性（确认档位/光圈/快门/ISO 属性码与可选集）',
      needsFiles: false,
      run: (_) => NikonEngine.probeProps(),
    ),
    _Probe(
      label: '试验:取景5',
      detail: '取景热身轮询（最长 45 秒，期间请观察相机屏幕）',
      needsFiles: true,
      run: NikonEngine.probeLiveView5,
    ),
    _Probe(
      label: '休眠/唤醒',
      detail: '读 LCD关闭/测光关闭/自动关机 取值表 + 测 DeviceReady 是否应答'
          '（用于查"相机息屏后遥控失效"）',
      needsFiles: false,
      run: (_) => NikonEngine.probeSleep(),
    ),
    _Probe(
      label: '实时ISO',
      detail: '差分法找"随 Auto ISO 变化"的属性（约 15 秒，期间请对着明暗变化处）',
      needsFiles: false,
      run: (_) => NikonEngine.probeLiveIso(),
    ),
    _Probe(
      label: '取景头部',
      detail: 'dump 取景帧头部全部字段（384B，找实时 ISO/光圈/快门）',
      needsFiles: false,
      run: (_) => NikonEngine.probeLvHeader(),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _refreshWifi();
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _addLog(String line) => AppLog.add(line);

  Future<void> _run(String label, Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    _addLog('▶ $label');
    try {
      await body();
    } on PlatformException catch (e) {
      _addLog('✗ $label 失败: ${e.code} ${e.message}');
    } catch (e) {
      _addLog('✗ $label 失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ 连接类操作

  Future<void> _refreshWifi() => _run('刷新网络信息', () async {
        final w = await NikonEngine.wifiInfo();
        if (!mounted) return;
        setState(() => _wifi = w);
        _addLog('网络: onWifi=${w['onWifi']} ssid=${w['ssid']} ip=${w['ip']} 网关=${w['gateway']} '
            '信号=${w['signalLevel']}格(${w['rssi']}dBm) 速率=${w['linkSpeed']}Mbps');
      });

  Future<void> _scan() => _run('扫描相机', () async {
        final found = await NikonEngine.scan();
        if (!mounted) return;
        setState(() {
          _found = found;
          if (found.isNotEmpty && _ipCtrl.text.isEmpty) _ipCtrl.text = found.first;
        });
      });

  Future<void> _connect() => _run('连接相机 ${_ipCtrl.text}', () async {
        final info = await NikonEngine.connect(_ipCtrl.text.trim(), _nameCtrl.text.trim());
        if (!mounted) return;
        setState(() {
          _connected = true;
          _camera = info;
          _enumResult = null;
          _thumbs.clear();
          _downloadResult = null;
        });
      });

  Future<void> _disconnect() => _run('断开连接', () async {
        await NikonEngine.disconnect();
        if (!mounted) return;
        setState(() {
          _connected = false;
          _camera = null;
          _enumResult = null;
          _thumbs.clear();
          _downloadResult = null;
        });
      });

  // ------------------------------------------------------------ 枚举与下载

  /// 枚举结果统一成"句柄 + 可选详情"的列表：
  /// listFolders 只返回句柄，enumerate 返回完整 ObjectInfo。
  List<Map<String, dynamic>> _enumFiles() {
    final r = _enumResult;
    if (r == null) return const [];
    return ((r['files'] as List?) ?? const []).map((e) {
      if (e is Map) return e.cast<String, dynamic>();
      return <String, dynamic>{'handle': e};
    }).toList();
  }

  int? get _firstHandle {
    final files = _enumFiles();
    if (files.isEmpty) return null;
    return (files.first['handle'] as num?)?.toInt();
  }

  Future<void> _enumerate() => _run('快速枚举（listFolders，生产路径）', () async {
        final r = await NikonEngine.listFolders();
        final count = (r['files'] as List).length;
        final folders = (r['folders'] as List).length;
        _addLog('结果: $count 个文件 / $folders 目录，耗时 ${r['ms']}ms');
        if (!mounted) return;
        setState(() {
          _enumResult = r;
          _enumSummary = '快速枚举：$count 个文件 / $folders 目录 · 耗时 ${r['ms']}ms';
          _thumbs.clear();
          _downloadResult = null;
        });
      });

  Future<void> _fullEnumerate() => _run('全量枚举（慢，含全部 ObjectInfo）', () async {
        final r = await NikonEngine.enumerate();
        if (!mounted) return;
        setState(() {
          _enumResult = r;
          _enumSummary = '全量枚举：文件 ${r['totalFiles']} 目录 ${r['folderCount']} '
              '（JPEG ${r['jpegCount']} · RAW ${r['rawCount']} · 视频 ${r['videoCount']}）';
          _thumbs.clear();
          _downloadResult = null;
        });
        _addLog(_enumSummary!);
      });

  Future<void> _loadThumbnails() => _run('缩略图测试（前 3 个文件）', () async {
        final handles = _enumFiles().take(3).map((f) => (f['handle'] as num).toInt()).toList();
        if (handles.isEmpty) throw StateError('请先枚举，或卡内没有文件');
        final thumbs = <Uint8List>[];
        for (final h in handles) {
          thumbs.add(await NikonEngine.thumbnail(h));
          _addLog('缩略图 handle=$h ${thumbs.last.length}B');
        }
        if (!mounted) return;
        setState(() => _thumbs
          ..clear()
          ..addAll(thumbs));
      });

  Future<void> _downloadTest() => _run('下载测试（第一个 JPEG）', () async {
        final files = _enumFiles();
        if (files.isEmpty) throw StateError('请先枚举');
        final handles = files.take(50).map((f) => (f['handle'] as num).toInt()).toList();
        final infos = await NikonEngine.objectInfo(handles);
        final jpegs = infos.where((f) => f['isJpeg'] == true).toList();
        final pick = jpegs.isNotEmpty ? jpegs.first : infos.first;
        final name = pick['name'] as String;
        final size = (pick['size'] as num).toInt();
        final handle = (pick['handle'] as num).toInt();
        if (!mounted) return;
        setState(() {
          _progress = 0;
          _progressText = '准备中…';
          _downloadResult = null;
        });
        final r = await NikonEngine.download(handle, name, size);
        _addLog('落盘: ${r['path']} uri=${r['uri']} 耗时=${r['ms']}ms '
            '速度=${((r['speedMBps'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}MB/s');
        if (!mounted) return;
        setState(() {
          _downloadResult = r;
          _progress = null;
        });
      });

  /// 读一次拍摄参数并逐项打日志：用于**与相机屏幕当场比对**。
  /// 起因是 Auto ISO 下相机显示 ISO 2500、App 的 0x500F 读到 2000，
  /// 需要同一时刻的两边数值才能判断是"属性不是实时值"还是"界面刷新不及时"。
  Future<void> _readParamsNow() => _run('读一次拍摄参数', () async {
        final p = await NikonEngine.shotParams();
        for (final k in const ['fNumber', 'exposureTime', 'iso', 'exposureBias', 'mode']) {
          final d = p[k];
          if (d is Map) {
            final vals = d['values'] as List?;
            _addLog('参数 $k：当前=${d['value']} 可写=${d['writable']} '
                '${vals != null ? "取值表 ${vals.length} 项" : ""}');
          } else {
            _addLog('参数 $k：无（相机未提供）');
          }
        }
        _addLog('↑ 请立刻对照相机屏幕上的 ISO / 光圈 / 快门');
      });

  Future<void> _showCapabilities() => _run('能力清单', () async {
        final caps = await NikonEngine.capabilities();
        if (!mounted) return;
        await showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF161616),
          isScrollControlled: true,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
          builder: (_) => CapabilitySheet(caps),
        );
        _addLog('能力清单已展示');
      });

  // ------------------------------------------------------------ 探针

  Future<void> _runProbe(_Probe p) async {
    if (_busy || !_connected) return;
    final h = _firstHandle;
    if (p.needsFiles && h == null) return;
    if (p.destructive && !await _confirmDestructive(p)) return;
    await _run(p.title, () async {
      final lines = await p.run(h ?? 0);
      // 结果少就直接摊开，多则只报条数（逐条明细已由原生侧写进日志面板）
      final summary =
          lines.length <= 8 ? lines.join(' | ') : '${lines.length} 组结果，详见上方日志';
      _addLog('${p.label}：$summary');
    });
  }

  Future<bool> _confirmDestructive(_Probe p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('该探针会真实拍摄', style: TextStyle(fontSize: 16)),
        content: Text(
          '${p.title}\n\n'
          '它会让相机实际拍摄一张照片并写入存储卡（可能还有未知操作码）。\n'
          '请确认卡内有空间，并接受存储卡被写入一张测试照片。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      shrinkWrap: widget.embedded,
      physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(12),
      children: [
        Row(children: [
          const Text('协议验证面板', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            tooltip: '清空日志',
            onPressed: AppLog.clear,
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          ),
        ]),
        _wifiCard(cs),
        const SizedBox(height: 12),
        _usbCard(),
        const SizedBox(height: 12),
        _connectCard(),
        const SizedBox(height: 12),
        _cameraCard(),
        const SizedBox(height: 12),
        _actionsCard(cs),
        const SizedBox(height: 12),
        if (_progress != null) _progressCard(),
        if (_downloadResult != null) _downloadResultCard(),
        if (_progress != null || _downloadResult != null) const SizedBox(height: 12),
        const DebugLogCard(),
      ],
    );
  }

  TextStyle get _hint =>
      TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12, height: 1.4);

  /// USB 实验的结论：直接显示在卡片里，不必去日志面板翻找
  List<String>? _usbResult;

  Future<void> _runUsbProbe() async {
    setState(() => _usbResult = const ['正在探测…若弹出系统授权对话框，请点「允许」']);
    await _run('USB 连接模式：设备枚举 / 会话 / 操作集 / 测速', () async {
      final lines = await NikonEngine.usbProbe();
      if (mounted) setState(() => _usbResult = lines);
    });
  }

  /// USB 连接模式实验卡片。
  ///
  /// 单独成卡而不是塞进上面的探针按钮网：它是独立实验、有前置条件、结果需要直接看到。
  /// 会占用 USB 口并打开 PTP 会话——插着相机时手机这个口就被占住，电脑端 adb 会断开，属正常。
  Widget _usbCard() => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('USB 连接（实验）',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '目的：测出 USB 模式下的真实传输速度（Wi-Fi 实测 2.4MB/s，'
              'USB 理论上快一个数量级）。\n'
              '开工前确认：①手机 OTG 已开（小米在 设置 → 更多设置 → OTG 连接）'
              '②相机退出「连接至智能设备」③相机 USB 选「MTP/PTP」档④数据线（非纯充电线）。\n'
              '注意：会占用 USB 口并开 PTP 会话，相机同时只允许一个会话，'
              '插着相机时电脑 adb 会断开——属正常现象。',
              style: _hint,
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _runUsbProbe,
              icon: const Icon(Icons.usb, size: 18),
              label: const Text('开始 USB 测速'),
            ),
            if (_usbResult != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('探测结果', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  const Spacer(),
                  // 结果必须能一键复制：用户要把它贴出来反馈，
                  // 而这块内容不在日志面板里，没有复制入口就只能手打
                  TextButton.icon(
                    onPressed: _copyUsbResult,
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: const Text('复制结果', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final l in _usbResult!)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(l,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 11.5, height: 1.4)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      );

  Future<void> _copyUsbResult() async {
    final lines = _usbResult;
    if (lines == null) return;
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('USB 探测结果已复制'), duration: Duration(seconds: 1)),
    );
  }

  Widget _wifiCard(ColorScheme cs) {
    final onWifi = _wifi?['onWifi'] == true;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(onWifi ? Icons.wifi : Icons.wifi_off, color: onWifi ? Colors.green : cs.error),
            const SizedBox(width: 8),
            const Text('网络', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (onWifi) Text('SSID: ${_wifi?['ssid'] ?? '(未知)'}', style: _hint),
          ]),
          const SizedBox(height: 6),
          Text('IP: ${_wifi?['ip'] ?? '-'}   网关: ${_wifi?['gateway'] ?? '-'}', style: _hint),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: _busy ? null : _refreshWifi, child: const Text('刷新')),
            OutlinedButton(
                onPressed: _busy ? null : () => NikonEngine.openWifiSettings(),
                child: const Text('打开 Wi-Fi 设置')),
            FilledButton.tonal(
                onPressed: _busy ? null : _scan,
                child: Text(_found.isEmpty ? '扫描相机' : '重新扫描')),
          ]),
          if (_found.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: _found
                  .map((ip) => FilterChip(
                        label: Text(ip),
                        selected: _ipCtrl.text == ip,
                        onSelected: (_) => setState(() => _ipCtrl.text = ip),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _connectCard() => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('连接', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ipCtrl,
                  enabled: !_connected,
                  decoration: const InputDecoration(
                    labelText: '相机 IP',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _nameCtrl,
                  enabled: !_connected,
                  decoration: const InputDecoration(
                    labelText: '握手 friendlyName',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              if (!_connected)
                FilledButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: const Icon(Icons.link),
                  label: const Text('连接'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开'),
                ),
            ]),
          ],
        ),
      );

  Widget _cameraCard() {
    final c = _camera;
    if (c == null) {
      return const AppCard(
        child: Text('相机：未连接', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      );
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('相机', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('${c['manufacturer']} ${c['model']}  v${c['deviceVersion']}\n'
                  '序列号: ${c['serial']}\n'
                  'Vendor: ${c['vendorDesc']}\n'
                  '支持操作 ${(c['operations'] as List).length} 个 · 事件 ${(c['events'] as List).length} 个\n'
                  '分块下载: ${c['supportsPartial'] == true ? '✓' : '✗'}   '
                  '大缩略图: ${c['supportsLargeThumb'] == true ? '✓' : '✗'}   '
                  'ObjectAdded 事件: ${c['supportsObjectAdded'] == true ? '✓' : '✗'}',
              style: _hint),
        ],
      ),
    );
  }

  Widget _actionsCard(ColorScheme cs) {
    final canUseFiles = _enumFiles().isNotEmpty;
    Widget button(_Probe p) {
      final enabled = !_busy && _connected && (!p.needsFiles || canUseFiles);
      final onPressed = enabled ? () => _runProbe(p) : null;
      // 破坏性探针用实心按钮 + 警示色区分，避免与只读探针混淆
      if (p.destructive) {
        return FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: Colors.white),
          onPressed: onPressed,
          child: Text(p.label),
        );
      }
      return OutlinedButton(onPressed: onPressed, child: Text(p.label));
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('协议验证', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(
                onPressed: (_busy || !_connected) ? null : _enumerate,
                child: const Text('① 快速枚举')),
            FilledButton.tonal(
                onPressed: (_busy || !_connected) ? null : _loadThumbnails,
                child: const Text('② 缩略图×3')),
            FilledButton.tonal(
                onPressed: (_busy || !_connected) ? null : _downloadTest,
                child: const Text('③ 下载落盘')),
            OutlinedButton(
              onPressed: (_busy || !_connected) ? null : _fullEnumerate,
              child: const Text('全量枚举(慢)'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected)
                  ? null
                  : () async {
                      final b = await NikonEngine.battery();
                      _addLog('电量: $b%');
                    },
              child: const Text('电量'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected) ? null : _showCapabilities,
              child: const Text('能力清单'),
            ),
            // 与相机屏幕逐项对照：Auto ISO 下 0x500F 疑非实时值，用它当场比对
            OutlinedButton(
              onPressed: (_busy || !_connected) ? null : _readParamsNow,
              child: const Text('读一次参数'),
            ),
            ..._probes.map(button),
          ]),
          const SizedBox(height: 10),
          if (_enumSummary != null) ...[
            Text(_enumSummary!, style: _hint),
            const SizedBox(height: 6),
            ..._enumFiles()
                .where((s) => s['name'] != null)
                .take(12)
                .map((s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        'handle=${s['handle']}  ${s['name']}  ${s['formatName']}  '
                        '${formatBytes((s['size'] as num?) ?? 0)}  ${s['date'] ?? ''}',
                        style: _hint,
                      ),
                    )),
          ],
          if (_thumbs.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: _thumbs
                  .map((t) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AspectRatio(
                                aspectRatio: 1,
                                child: Image.memory(t, fit: BoxFit.cover, gaplessPlayback: true)),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _progressCard() => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载中…  $_progressText', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress, minHeight: 6),
          ],
        ),
      );

  Widget _downloadResultCard() => AppCard(
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '已保存到系统相册：${_downloadResult?['path']}\n'
                  '${formatBytes((_downloadResult?['bytes'] as num?) ?? 0)} · ${_downloadResult?['ms']}ms · '
                  '${((_downloadResult?['speedMBps'] as num?) ?? 0).toStringAsFixed(1)} MB/s',
                  style: _hint),
            ),
          ],
        ),
      );
}
