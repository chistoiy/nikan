import 'package:flutter/material.dart';

import '../app_model.dart';
import 'gallery_page.dart';
import 'remote_page.dart';
import 'settings_page.dart';

/// 连接页（SnapBridge 风格）：Wi-Fi 引导 + 扫描连接 + 已连接相机面板。
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.model});

  final AppModel model;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    model.refreshWifi();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _scanAndConnect() async {
    try {
      await model.refreshWifi();
      if (model.wifi?['onWifi'] != true) {
        _snack('请先在手机上连接相机 Wi-Fi 热点');
        return;
      }
      _snack('正在连接相机…');
      await model.connectSmart();
    } catch (e) {
      _snack('连接失败：${_errText(e)}');
    }
  }

  String _errText(Object e) {
    var s = e.toString();
    if (s.startsWith('PlatformException(')) s = s.substring(18);
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final connected = model.connState == 'connected';
        return Scaffold(
          appBar: AppBar(
            title: const Text('尼康速传'),
            actions: [
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SettingsPage(model: model)),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: connected ? _connectedPanel() : _guidePanel(),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------ 已连接

  Widget _connectedPanel() {
    final info = model.cameraInfo;
    final model_ = (info?['model'] as String?) ?? '';
    final ip = model.foundCameras.isNotEmpty ? model.foundCameras.first : '';
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      children: [
        const SizedBox(height: 12),
        Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.photo_camera_outlined, size: 120, color: Colors.white.withValues(alpha: 0.16)),
              Positioned(
                right: -6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(color: Color(0xFFFFE100), shape: BoxShape.circle),
                  child: const Icon(Icons.wifi, size: 16, color: Colors.black),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            model_.isEmpty ? '已连接相机' : 'Nikon $model_',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            'Wi-Fi 已连接${ip.isEmpty ? '' : ' · $ip'}',
            style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.55)),
          ),
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.battery_5_bar_outlined, size: 20, color: Color(0xFFFFE100)),
            const SizedBox(width: 4),
            Text(model.battery >= 0 ? '${model.battery}%' : '—',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 28),
            const Icon(Icons.photo_library_outlined, size: 18, color: Color(0xFFFFE100)),
            const SizedBox(width: 6),
            Text(model.files.isEmpty ? '' : '${model.files.length} 张照片',
                style: const TextStyle(fontSize: 14)),
          ],
        ),
        const SizedBox(height: 40),
        FilledButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => GalleryPage(model: model)),
          ),
          child: const Text('浏览照片'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => RemotePage(model: model)),
          ),
          child: const Text('遥控拍摄（试验性）'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => model.disconnect(),
          child: const Text('断开连接'),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 引导

  Widget _guidePanel() {
    final onWifi = model.wifi?['onWifi'] == true;
    final ssid = model.wifi?['ssid'] as String?;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        const SizedBox(height: 8),
        Center(
          child: Icon(Icons.photo_camera_outlined, size: 110, color: Colors.white.withValues(alpha: 0.14)),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Wi-Fi 连接', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFFFFE100))),
              const SizedBox(height: 14),
              _step(1, '在相机设定菜单选择「连接至智能设备」→「Wi-Fi 连接」'),
              _step(2, '选择「建立 Wi-Fi 连接」，相机屏幕显示 SSID 和密码'),
              _step(3, '手机连接该 Wi-Fi 网络后返回本应用'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            borderRadius: BorderRadius.circular(14),
          ),
          child: ListTile(
            leading: Icon(
              onWifi ? Icons.wifi : Icons.wifi_off,
              color: onWifi ? const Color(0xFFFFE100) : Colors.white38,
            ),
            title: Text(
              onWifi ? (ssid ?? '已连接 Wi-Fi（名称未知）') : '未连接 Wi-Fi',
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              onWifi ? '${model.wifi?['ip'] ?? ''}' : '请先在系统设置中连接相机热点',
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5)),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => model.refreshWifi(),
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: model.connState == 'connecting' ? null : _scanAndConnect,
          child: model.connState == 'connecting'
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('连接中…'),
                  ],
                )
              : const Text('连接相机'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: model.connState == 'connecting'
              ? null
              : () => model.connectUsb().catchError((e) => _snack('USB 连接失败：$e')),
          child: const Text('USB 数据线连接（高速下载，实测 27 MB/s）'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => model.openWifiSettings(),
          child: const Text('打开手机 Wi-Fi 设置'),
        ),
        if (model.foundCameras.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('发现的相机', style: TextStyle(fontSize: 12, color: Colors.white38)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: model.foundCameras
                .map((ip) => ActionChip(
                      label: Text(ip),
                      onPressed: () => model.connect(ip).catchError((e) => _snack('连接失败：$e')),
                    ))
                .toList(),
          ),
        ],
        if (model.connError != null) ...[
          const SizedBox(height: 16),
          Text(
            '上次连接失败：${_errText(model.connError!)}\n\n'
            '提示：若相机屏幕显示"连接失败"，请先在相机上选择重试，再点上面的连接按钮。',
            style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFFFF7B7B)),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _step(int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Color(0xFFFFE100), shape: BoxShape.circle),
            child: Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13.5, height: 1.5, color: Colors.white.withValues(alpha: 0.82)),
            ),
          ),
        ],
      ),
    );
  }
}
