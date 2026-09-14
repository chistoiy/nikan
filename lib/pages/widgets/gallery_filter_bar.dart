import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// 相册页顶部筛选条：文件类型 chips + 文件夹入口。
class GalleryFilterBar extends StatelessWidget {
  const GalleryFilterBar({
    super.key,
    required this.kind,
    required this.folder,
    required this.onKind,
    required this.onFolderTap,
  });

  final String kind; // all / jpeg / raw / video
  final String folder;
  final ValueChanged<String> onKind;
  final VoidCallback onFolderTap;

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
