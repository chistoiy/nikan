import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// 相册页顶部筛选条：文件类型 chips + 未下载快捷筛 + 文件夹入口。
class GalleryFilterBar extends StatelessWidget {
  const GalleryFilterBar({
    super.key,
    required this.kind,
    required this.folder,
    required this.onKind,
    required this.onFolderTap,
    required this.undownloadedOnly,
    required this.undownloadedCount,
    required this.onToggleUndownloaded,
    required this.groupByDay,
    required this.onToggleGroupByDay,
    required this.pairedOnly,
    required this.pairedCount,
    required this.onTogglePaired,
    this.showUndownloaded = true,
    this.showPaired = true,
  });

  final String kind; // all / jpeg / raw / video
  final String folder;
  final ValueChanged<String> onKind;
  final VoidCallback onFolderTap;

  /// 只看未下载
  final bool undownloadedOnly;
  final int undownloadedCount;
  final VoidCallback onToggleUndownloaded;

  /// 按拍摄日期分组显示
  final bool groupByDay;
  final VoidCallback onToggleGroupByDay;

  /// 只看 RAW+JPEG 成对照片
  final bool pairedOnly;
  final int pairedCount;
  final VoidCallback onTogglePaired;

  /// 是否显示「未下载」快捷筛。本机（已下载）页没有"未下载"的概念，置 false。
  final bool showUndownloaded;

  /// 是否显示「成对」筛。本机页的成对关系尚未建立，置 false。
  final bool showPaired;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, String value) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: kind == value,
            selectedColor: kAccent,
            labelStyle: TextStyle(
              fontSize: 12.5,
              color: kind == value ? Colors.black : Colors.white70,
            ),
            checkmarkColor: Colors.black,
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: kind == value ? kAccent : Colors.white24),
            backgroundColor: const Color(0xFF161616),
            onSelected: (_) => onKind(value),
          ),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
      color: const Color(0xFF0A0A0A),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip('全部', 'all'),
            chip('JPEG', 'jpeg'),
            chip('RAW', 'raw'),
            chip('视频', 'video'),
            // 未下载快捷筛：待下载清零后仍保留（否则筛空了就没法关掉它）
            if (showUndownloaded && (undownloadedCount > 0 || undownloadedOnly))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text('未下载 $undownloadedCount'),
                  selected: undownloadedOnly,
                  selectedColor: kAccent,
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    color: undownloadedOnly ? Colors.black : kAccent,
                  ),
                  checkmarkColor: Colors.black,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: undownloadedOnly ? kAccent : kAccent.withValues(alpha: 0.5)),
                  backgroundColor: const Color(0xFF161616),
                  onSelected: (_) => onToggleUndownloaded(),
                ),
              ),
            const SizedBox(width: 4),
            // RAW+JPEG 成对筛：相机开了"同时记录"时，一张照片是两个文件，
            // 这个筛选让用户能只看这些成对照片（便于成对下载/成对清理）
            if (showPaired) ...[
              FilterChip(
                label: Text(
                  '成对 $pairedCount',
                  style: TextStyle(fontSize: 12.5, color: pairedOnly ? Colors.black : Colors.white70),
                ),
                selected: pairedOnly,
                selectedColor: kAccent,
                checkmarkColor: Colors.black,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: pairedOnly ? kAccent : Colors.white24),
                backgroundColor: const Color(0xFF161616),
                onSelected: (_) => onTogglePaired(),
              ),
              const SizedBox(width: 4),
            ],
            FilterChip(
              label: Text(
                '按天分组',
                style: TextStyle(fontSize: 12.5, color: groupByDay ? Colors.black : Colors.white70),
              ),
              selected: groupByDay,
              selectedColor: kAccent,
              checkmarkColor: Colors.black,
              showCheckmark: true,
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: groupByDay ? kAccent : Colors.white24),
              backgroundColor: const Color(0xFF161616),
              onSelected: (_) => onToggleGroupByDay(),
            ),
            const SizedBox(width: 4),
            ActionChip(
              label: Text(
                folder == '全部' ? '文件夹' : folder,
                style: const TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
              visualDensity: VisualDensity.compact,
              side: const BorderSide(color: Colors.white24),
              backgroundColor: const Color(0xFF161616),
              onPressed: onFolderTap,
            ),
          ],
        ),
      ),
    );
  }
}
