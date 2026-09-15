import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// "发现新照片"横幅：点击刷新相册列表。
class NewPhotosBanner extends StatelessWidget {
  const NewPhotosBanner({super.key, required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF232312),
        child: InkWell(
          onTap: onRefresh,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                Icon(Icons.notification_add_outlined, size: 15, color: kAccent),
                SizedBox(width: 8),
                Text('发现新照片，点击刷新', style: TextStyle(fontSize: 12.5, color: kAccent)),
                Spacer(),
                Icon(Icons.chevron_right, size: 16, color: kAccent),
              ],
            ),
          ),
        ),
      );
}

/// 后台详情索引进度条。
class IndexProgressBar extends StatelessWidget {
  const IndexProgressBar({super.key, required this.indexed, required this.total});

  final int indexed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final frac = total == 0 ? 0.0 : indexed / total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text('索引 $indexed/$total',
              style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.45))),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                  value: frac, minHeight: 2, backgroundColor: Colors.white12),
            ),
          ),
        ],
      ),
    );
  }
}

/// 批量下载进行条（含取消）。
class DownloadProgressBar extends StatelessWidget {
  const DownloadProgressBar({
    super.key,
    required this.done,
    required this.total,
    required this.fileFrac,
    required this.speedMBps,
    required this.currentName,
    required this.onCancel,
  });

  final int done;
  final int total;
  final double fileFrac;
  final double speedMBps;
  final String currentName;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final overall = total > 0 ? (done + fileFrac) / total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$done/$total'
                  '${currentName.isEmpty ? '' : ' · $currentName'}'
                  '${speedMBps > 0 ? ' · ${speedMBps.toStringAsFixed(1)}MB/s' : ''}',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.6)),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: overall.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation(kAccent),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onCancel,
            child: const Text('取消', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
