import 'package:flutter/material.dart';

import '../../engine/ptp_names.dart';
import '../widgets/app_widgets.dart';

/// 相机能力清单弹窗：操作码 / 事件码 / 属性码 + 名称对照，长按可选择复制。
class CapabilitySheet extends StatelessWidget {
  const CapabilitySheet(this.caps, {super.key});

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
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kAccent),
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
