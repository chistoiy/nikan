import 'package:flutter/material.dart';

import '../app_model.dart';
import 'debug/debug_page.dart';
import 'widgets/app_widgets.dart';

/// 设置页：存储与下载设置 + 内嵌协议验证面板。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.model});

  final AppModel model;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const yellow = kAccent;

  /// 面板自己用 ValueListenableBuilder 订阅日志，不依赖 AppModel。
  /// 固化成常量实例复用：外层 AnimatedBuilder 重建时，同一 widget 实例会
  /// 被 Flutter 跳过 build（否则每次通知都要重建这 677 行的协议面板）。
  static const _debugPanel = DebugPanel(embedded: true);

  AppModel get model => widget.model;

  Future<void> _pickFolder() => model.pickSaveFolder();

  Future<bool?> _confirmDanger() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('确认开启？', style: TextStyle(fontSize: 16)),
        content: const Text(
          '开启后，每次下载成功都会自动删除相机存储卡上的原文件。\n\n'
          '请确保手机端已完整保存后再操作。删除后无法恢复。',
          style: TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await model.setDeleteAfterDownload(true);
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _sectionTitle('存储与下载'),
            AppCard(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined, size: 22),
                  title: const Text('保存位置', style: TextStyle(fontSize: 14.5)),
                  subtitle: Text(
                    model.saveFolderUri == null
                        ? '系统相册 · Pictures/NikonSync'
                        : '自定义目录（相册 App 中不可见）',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(onPressed: _pickFolder, child: const Text('选择目录')),
                      if (model.saveFolderUri != null)
                        TextButton(onPressed: () => model.clearSaveFolder(), child: const Text('恢复默认')),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Text('下载画质（仅 JPEG 生效，RAW/视频始终原图）',
                      style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.4))),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'original', label: Text('原图')),
                    ButtonSegment(value: '8M', label: Text('8M')),
                    ButtonSegment(value: '2M', label: Text('2M')),
                  ],
                  selected: {model.downloadVariant},
                  onSelectionChanged: (s) => model.setDownloadVariant(s.first),
                  showSelectedIcon: false,
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(top: 8),
                  secondary: const Icon(Icons.delete_outline, size: 22),
                  title: const Text('下载后删除相机原片', style: TextStyle(fontSize: 14.5)),
                  subtitle: const Text('下载成功后删除相机内原文件，谨慎开启', style: TextStyle(fontSize: 12)),
                  value: model.deleteAfterDownload,
                  activeThumbColor: yellow,
                  onChanged: (v) async {
                    if (v) {
                      final ok = await _confirmDanger();
                      if (ok != true) return;
                    }
                    model.setDeleteAfterDownload(v);
                  },
                ),
              ],
            )),
            const SizedBox(height: 12),
            _sectionTitle('协议验证面板'),
            AppCard(padding: const EdgeInsets.all(6), child: _debugPanel),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white38)),
      );
}
