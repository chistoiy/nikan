import 'package:flutter/material.dart';

import 'app_widgets.dart';

/// 相册页选项弹窗：文件类型 / 文件夹 / 排序 / 下载画质。
///
/// 全是无状态的"选一个就回调"，因此抽成函数，页面只负责传入当前值。
Future<void> showGalleryOptionsSheet({
  required BuildContext context,
  required List<String> folders,
  required String kind,
  required String folder,
  required String sortMode,
  required String variant,
  required ValueChanged<String> onKind,
  required ValueChanged<String> onFolder,
  required ValueChanged<String> onSort,
  required ValueChanged<String> onVariant,
}) {
  void pick(BuildContext ctx, VoidCallback apply) {
    apply();
    Navigator.pop(ctx);
  }

  return showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF161616),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          const _SectionLabel('文件类型'),
          optionTile(ctx, '全部类型', kind == 'all', () => pick(ctx, () => onKind('all'))),
          optionTile(ctx, 'JPEG 照片', kind == 'jpeg', () => pick(ctx, () => onKind('jpeg'))),
          optionTile(ctx, 'RAW (NEF)', kind == 'raw', () => pick(ctx, () => onKind('raw'))),
          optionTile(ctx, '视频', kind == 'video', () => pick(ctx, () => onKind('video'))),
          const _SectionLabel('文件夹', top: 14),
          optionTile(ctx, '所有文件夹', folder == '全部', () => pick(ctx, () => onFolder('全部'))),
          ...folders.map((name) =>
              optionTile(ctx, name, folder == name, () => pick(ctx, () => onFolder(name)))),
          const _SectionLabel('排序', top: 14),
          optionTile(ctx, '最新优先', sortMode == 'newest', () => pick(ctx, () => onSort('newest'))),
          optionTile(ctx, '最早优先', sortMode == 'oldest', () => pick(ctx, () => onSort('oldest'))),
          optionTile(ctx, '文件名 A→Z', sortMode == 'nameAsc', () => pick(ctx, () => onSort('nameAsc'))),
          optionTile(ctx, '文件名 Z→A', sortMode == 'nameDesc', () => pick(ctx, () => onSort('nameDesc'))),
          const _SectionLabel('下载画质（仅 JPEG 生效）', top: 14),
          optionTile(ctx, '原图', variant == 'original', () => pick(ctx, () => onVariant('original'))),
          optionTile(ctx, '8M（长边 3840）', variant == '8M', () => pick(ctx, () => onVariant('8M'))),
          optionTile(ctx, '2M（长边 1920）', variant == '2M', () => pick(ctx, () => onVariant('2M'))),
        ],
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.top = 8});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, top, 18, 6),
        child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white38)),
      );
}

Widget optionTile(BuildContext ctx, String label, bool selected, VoidCallback onTap) => ListTile(
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 14.5)),
      trailing: selected ? const Icon(Icons.check, color: kAccent, size: 20) : null,
      onTap: onTap,
    );
