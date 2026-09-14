import 'package:flutter/material.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
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

  /// 开发者选项默认收起：面板占掉整屏下半部分，对普通用户只会造成困惑
  bool _showDev = false;

  /// 版本号取自系统包信息（原生侧读 BuildConfig），避免与 pubspec 手工同步时失真
  String? _version;

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    NikonEngine.appVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

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
                  secondary: Icon(
                    Icons.delete_outline,
                    size: 22,
                    color: model.deleteAfterDownload ? const Color(0xFFE5A08A) : null,
                  ),
                  title: const Text('下载后删除相机原片', style: TextStyle(fontSize: 14.5)),
                  // 不可恢复的提示常驻：此前只在开启时弹一次确认框，
                  // 关掉之后界面只剩一行"谨慎开启"，很容易被忽略
                  subtitle: Text(
                    model.deleteAfterDownload
                        ? '已开启：每次下载成功后删除相机内原文件，删除后无法恢复'
                        : '下载成功后删除相机内原文件，谨慎开启',
                    style: TextStyle(
                      fontSize: 12,
                      color: model.deleteAfterDownload ? const Color(0xFFE5A08A) : null,
                    ),
                  ),
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
            _sectionTitle('关于'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow('版本', _version ?? '…'),
                  const SizedBox(height: 6),
                  _infoRow('已验证机型', 'Nikon Z50 II · 固件 1.02'),
                  const SizedBox(height: 10),
                  Text(
                    '非官方开源作品，与尼康公司无关。无线传输存在丢包可能，'
                    '请勿作为重要数据的唯一存储。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _sectionTitle('高级'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => setState(() => _showDev = !_showDev),
                    child: Row(
                      children: [
                        const Text('开发者选项', style: TextStyle(fontSize: 14.5)),
                        const Spacer(),
                        Text(
                          _showDev ? '收起' : '协议日志 / 探针',
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                        Icon(_showDev ? Icons.expand_less : Icons.expand_more,
                            size: 20, color: Colors.white54),
                      ],
                    ),
                  ),
                  if (!_showDev) ...[
                    const SizedBox(height: 6),
                    Text(
                      '默认收起。协议调试日志与厂商探针在此展开，日常使用无需关心。',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.white.withValues(alpha: 0.45)),
                    ),
                  ],
                ],
              ),
            ),
            if (_showDev) ...[
              const SizedBox(height: 8),
              AppCard(padding: const EdgeInsets.all(6), child: _debugPanel),
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
        ],
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white38)),
      );
}
