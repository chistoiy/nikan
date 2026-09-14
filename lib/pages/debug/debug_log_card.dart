import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/app_log.dart';
import '../widgets/app_widgets.dart';

/// 协议日志卡片：实时日志视图 + 复制/清空。
/// 自己订阅 AppLog.version，因此不依赖外层是否重建（此前嵌在设置页的
/// AnimatedBuilder 里，每次 AppModel 通知都会白白重建一次）。
class DebugLogCard extends StatefulWidget {
  const DebugLogCard({super.key});

  @override
  State<DebugLogCard> createState() => _DebugLogCardState();
}

class _DebugLogCardState extends State<DebugLogCard> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ValueListenableBuilder<int>(
              valueListenable: AppLog.version,
              builder: (context, v, child) =>
                  Text('日志（$v）', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Spacer(),
            IconButton(
              tooltip: '复制全部日志',
              icon: const Icon(Icons.copy_all_outlined, size: 20),
              onPressed: () async {
                final text = AppLog.lines.map((l) => '${l.time}  ${l.text}').join('\n');
                await Clipboard.setData(ClipboardData(text: text));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已复制 ${AppLog.lines.length} 条日志'),
                    duration: const Duration(seconds: 1),
                  ),
                );
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
                  builder: (context, v, child) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_ctrl.hasClients) _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
                    });
                    final all = AppLog.lines;
                    final start = all.length > AppLog.displayWindow
                        ? all.length - AppLog.displayWindow
                        : 0;
                    return ListView.builder(
                      controller: _ctrl,
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
