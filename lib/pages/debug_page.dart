import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/app_log.dart';
import '../engine/nikon_engine.dart';
import '../engine/ptp_names.dart';

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

class _DebugPanelState extends State<DebugPanel> {
  bool _busy = false;
  bool _connected = false;
  final TextEditingController _ipCtrl = TextEditingController(text: '192.168.1.1');
  final TextEditingController _nameCtrl = TextEditingController(text: 'Nikon Wireless Mobile Utility');

  Map<String, dynamic>? _wifi;
  List<String> _found = [];
  Map<String, dynamic>? _camera;
  Map<String, dynamic>? _enumResult;
  final List<Uint8List> _thumbs = [];
  Map<String, dynamic>? _downloadResult;
  double? _progress; // null = 无下载进行中
  String _progressText = '';

  final ScrollController _logCtrl = ScrollController();
  @override
  void initState() {
    super.initState();
    _refreshWifi();
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _nameCtrl.dispose();
    _logCtrl.dispose();
    super.dispose();
  }

  String _fmtBytes(num b) {
    if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)}MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)}KB';
    return '${b}B';
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

  Future<void> _refreshWifi() => _run('刷新网络信息', () async {
        final w = await NikonEngine.wifiInfo();
        if (!mounted) return;
        setState(() => _wifi = w);
        _addLog('网络: onWifi=${w['onWifi']} ssid=${w['ssid']} ip=${w['ip']} 网关=${w['gateway']}');
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

  String? _enumSummary;

  List<Map<String, dynamic>> _enumFiles() {
    final r = _enumResult;
    if (r == null) return const [];
    return ((r['files'] as List?) ?? const []).map((e) {
      if (e is Map) return e.cast<String, dynamic>();
      return <String, dynamic>{'handle': e}; // listFolders 返回纯句柄
    }).toList();
  }

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
        _addLog('落盘: ${r['path']} uri=${r['uri']} 耗时=${r['ms']}ms 速度=${((r['speedMBps'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}MB/s');
        if (!mounted) return;
        setState(() {
          _downloadResult = r;
          _progress = null;
        });
      });

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
          _connectCard(cs),
          const SizedBox(height: 12),
          _cameraCard(cs),
          const SizedBox(height: 12),
          _actionsCard(cs),
          const SizedBox(height: 12),
          if (_progress != null) _progressCard(cs),
          if (_downloadResult != null) _downloadResultCard(cs),
          if (_progress != null || _downloadResult != null) const SizedBox(height: 12),
          _logCard(cs),
        ],
      );
  }

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(14)}) => Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: const Color(0xFF161616),
        child: Padding(padding: padding, child: child),
      );

  TextStyle _hint(ColorScheme cs) => TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12, height: 1.4);

  Widget _wifiCard(ColorScheme cs) {
    final onWifi = _wifi?['onWifi'] == true;
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(onWifi ? Icons.wifi : Icons.wifi_off, color: onWifi ? Colors.green : cs.error),
          const SizedBox(width: 8),
          const Text('网络', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (onWifi) Text('SSID: ${_wifi?['ssid'] ?? '(未知)'}', style: _hint(cs)),
        ]),
        const SizedBox(height: 6),
        Text('IP: ${_wifi?['ip'] ?? '-'}   网关: ${_wifi?['gateway'] ?? '-'}', style: _hint(cs)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : _refreshWifi, child: const Text('刷新')),
          OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await NikonEngine.openWifiSettings();
                    },
              child: const Text('打开 Wi-Fi 设置')),
          FilledButton.tonal(onPressed: _busy ? null : _scan, child: Text(_found.isEmpty ? '扫描相机' : '重新扫描')),
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
    ));
  }

  Widget _connectCard(ColorScheme cs) => _card(Column(
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
      ));

  Widget _cameraCard(ColorScheme cs) {
    final c = _camera;
    if (c == null) {
      return _card(const Text('相机：未连接', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)));
    }
    return _card(Column(
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
            style: _hint(cs)),
      ],
    ));
  }

  Widget _actionsCard(ColorScheme cs) => _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('协议验证', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(onPressed: (_busy || !_connected) ? null : _enumerate, child: const Text('① 快速枚举')),
            FilledButton.tonal(
                onPressed: (_busy || !_connected) ? null : _loadThumbnails, child: const Text('② 缩略图×3')),
            FilledButton.tonal(
                onPressed: (_busy || !_connected) ? null : _downloadTest, child: const Text('③ 下载落盘')),
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
            OutlinedButton(
              onPressed: (_busy || !_connected || _enumFiles().isEmpty) ? null : _probeHiSpeed,
              child: const Text('试验:高速下载'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected || _enumFiles().isEmpty) ? null : _probeResize,
              child: const Text('试验:相机缩放'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected) ? null : _probeLiveView,
              child: const Text('试验:取景'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected) ? null : _probeLiveView2,
              child: const Text('试验:取景2'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected || _enumFiles().isEmpty) ? null : _probeLiveView3,
              child: const Text('试验:取景3'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected || _enumFiles().isEmpty) ? null : _probeLiveView4,
              child: const Text('试验:取景4'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected || _enumFiles().isEmpty) ? null : _probeLvAf,
              child: const Text('试验:LV对焦'),
            ),
            OutlinedButton(
              onPressed: (_busy || !_connected || _enumFiles().isEmpty) ? null : _probeLiveView5,
              child: const Text('试验:取景5'),
            ),
          ]),
          const SizedBox(height: 10),
          if (_enumSummary != null) ...[
            Text(_enumSummary!, style: _hint(cs)),
            const SizedBox(height: 6),
            ..._enumFiles()
                .where((s) => s['name'] != null)
                .take(12)
                .map((s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        'handle=${s['handle']}  ${s['name']}  ${s['formatName']}  ${_fmtBytes((s['size'] as num?) ?? 0)}  ${s['date'] ?? ''}',
                        style: _hint(cs),
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
      ));

  Widget _progressCard(ColorScheme cs) => _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('下载中…  $_progressText', style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress, minHeight: 6),
        ],
      ));

  Widget _downloadResultCard(ColorScheme cs) => _card(Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                '已保存到系统相册：${_downloadResult?['path']}\n'
                '${_fmtBytes((_downloadResult?['bytes'] as num?) ?? 0)} · ${_downloadResult?['ms']}ms · '
                '${((_downloadResult?['speedMBps'] as num?) ?? 0).toStringAsFixed(1)} MB/s',
                style: _hint(cs)),
          ),
        ],
      ));

  Future<void> _probeHiSpeed() => _run('高速下载探针 0x9400~0x9406', () async {
        final handles = _enumFiles();
        final h = (handles.first['handle'] as num).toInt();
        final lines = await NikonEngine.probeHiSpeed(h);
        _addLog('探针完成（对象 handle=$h）：${lines.length} 组结果，详见上方日志');
      });

  Future<void> _probeResize() => _run('相机端缩放探针 0x9207', () async {
        final handles = _enumFiles();
        final h = (handles.first['handle'] as num).toInt();
        final lines = await NikonEngine.probeResize(h);
        _addLog('探针完成（对象 handle=$h）：${lines.length} 组结果，详见上方日志');
      });

  Future<void> _probeLiveView() => _run('实时取景探针 0x9200~0x9203', () async {
        final lines = await NikonEngine.probeLiveView();
        _addLog('取景探针完成：${lines.length} 组结果，详见上方日志');
      });

  Future<void> _probeLiveView2() => _run('实时取景链路探针2（0x9206→拉帧→0x9201）', () async {
        final lines = await NikonEngine.probeLiveView2();
        _addLog('取景2探针完成：${lines.join(" | ")}');
      });

  Future<void> _probeLiveView3() => _run('取景中候选操作响应码探针', () async {
        final handles = _enumFiles();
        final h = (handles.first['handle'] as num).toInt();
        final lines = await NikonEngine.probeLiveView3(h);
        _addLog('取景3探针完成：${lines.length} 组结果，详见上方日志');
      });

  Future<void> _probeLiveView4() => _run('取景状态机探针（含 0x9400 对焦后行为，可能实拍一张）', () async {
        final handles = _enumFiles();
        final h = (handles.first['handle'] as num).toInt();
        final lines = await NikonEngine.probeLiveView4(h);
        _addLog('取景4探针完成：${lines.length} 组结果，详见上方日志');
      });

  Future<void> _probeLvAf() => _run('取景中 AF/拍摄通道探针（0x100E 会实拍）', () async {
        final handles = _enumFiles();
        final h = (handles.first['handle'] as num).toInt();
        final lines = await NikonEngine.probeLvAf(h);
        _addLog('LV对焦探针完成：${lines.length} 组结果，详见上方日志');
      });

  Future<void> _probeLiveView5() => _run('取景热身轮询（最长 45 秒，期间请观察相机屏幕）', () async {
        final handles = _enumFiles();
        final h = (handles.first['handle'] as num).toInt();
        final lines = await NikonEngine.probeLiveView5(h);
        _addLog('取景5探针完成：${lines.length} 组结果，详见上方日志');
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
          builder: (_) => _CapabilitySheet(caps),
        );
        _addLog('能力清单已展示');
      });

  Widget _logCard(ColorScheme cs) => _card(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ValueListenableBuilder<int>(valueListenable: AppLog.version, builder: (_, v, __) => Text('日志（$v）', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            const Spacer(),
            IconButton(
              tooltip: '复制全部日志',
              icon: const Icon(Icons.copy_all_outlined, size: 20),
              onPressed: () async {
                final text = AppLog.lines.map((l) => '${l.time}  ${l.text}').join('\n');
                await Clipboard.setData(ClipboardData(text: text));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已复制 ${AppLog.lines.length} 条日志'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
            IconButton(
              tooltip: '清空日志',
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              onPressed: AppLog.clear,
            ),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 260,
            child: Container(
              color: Colors.white.withValues(alpha: 0.04),
              child: SelectionArea(
                child: ValueListenableBuilder<int>(
                  valueListenable: AppLog.version,
                  builder: (context, _, __) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_logCtrl.hasClients) _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
                    });
                    final all = AppLog.lines;
                    final start = all.length > AppLog.displayWindow
                        ? all.length - AppLog.displayWindow
                        : 0;
                    return ListView.builder(
                      controller: _logCtrl,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      itemCount: all.length - start,
                      itemBuilder: (context, i) {
                        final line = all[start + i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            '${line.time}  ${line.text}',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ]),
      );
}

/// 相机能力清单弹窗：操作码/事件码/属性码 + 名称对照，长按可选择复制
class _CapabilitySheet extends StatelessWidget {
  const _CapabilitySheet(this.caps);

  final Map<String, dynamic> caps;

  List<int> _list(String key) =>
      ((caps[key] as List?) ?? const []).map((e) => (e as num).toInt()).toList();

  @override
  Widget build(BuildContext context) {
    final ops = _list('operations')..sort();
    final evts = _list('events')..sort();
    final props = _list('deviceProps')..sort();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
              child: Text(
                '能力清单 · ${caps['model'] ?? ''}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFFFFE100)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: Text('长按可选择复制', style: TextStyle(fontSize: 11, color: Colors.white38)),
            ),
            const Divider(height: 1),
            Expanded(
              child: SelectionArea(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  children: [
                    _section('支持的操作（${ops.length}）', ops, opName),
                    const SizedBox(height: 12),
                    _section('支持的事件（${evts.length}）', evts, evtName),
                    const SizedBox(height: 12),
                    _section('支持的设备属性（${props.length}）', props, (c) => ptpPropNames[c] ?? '厂商属性'),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<int> codes, String Function(int) namer) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          ...codes.map((c) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '0x${c.toRadixString(16).toUpperCase().padLeft(4, '0')}  ${namer(c)}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35),
                ),
              )),
        ],
      );
}
