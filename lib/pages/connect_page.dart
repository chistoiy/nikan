import 'package:flutter/material.dart';

import '../app_model.dart';
import 'gallery_page.dart';
import 'remote_page.dart';
import 'settings_page.dart';
import 'widgets/app_widgets.dart';
import 'widgets/link_status.dart';

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
              if (connected) LinkStatusButton(model: model),
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
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            // 点这一行看链路诊断：信号强度、相机活性、探针往返
            onTap: () => showLinkStatusDialog(context, model),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SignalBars(
                    level: model.transport == 'wifi' ? model.wifiLevel : -1,
                    size: 14,
                    color: model.camProbeOk ? kAccent : const Color(0xFFE5A08A),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    'Wi-Fi 已连接${ip.isEmpty ? '' : ' · $ip'}',
                    style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.6)),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: Colors.white.withValues(alpha: 0.35)),
                ],
              ),
            ),
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
        // 存储卡剩余容量：来自 GetStorageInfo(0x1005)，连接后自动拉取。
        // 决定"能不能整卡同步"的第一手信息，此前完全没有。
        if (model.storageText.isNotEmpty) ...[
          const SizedBox(height: 10),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.sd_card_outlined, size: 18, color: Color(0xFFFFE100)),
                const SizedBox(width: 6),
                Text(model.storageText, style: const TextStyle(fontSize: 13.5)),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '刷新卡容量',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh, size: 15),
                  onPressed: () => model.refreshStorage(),
                ),
              ],
            ),
          ),
        ],
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

  /// 连接方式（默认 Wi-Fi）。用户反馈：一打开只看到大段指导，得往下滑才能找到
  /// 连接按钮，很多人根本没意识到要滑。所以把"选方式 + 主按钮"放到最上面，
  /// 指导收进可展开区域，默认折叠。
  String _connMode = 'wifi';
  bool _guideOpen = false;

  Widget _modeSwitch() {
    Widget seg(String label, IconData icon, String value) {
      final on = _connMode == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _connMode = value;
            _guideOpen = false;
          }),
          child: Container(
            height: 42,
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: on ? const Color(0xFFFFE100) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: on ? Colors.black : Colors.white70),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                      color: on ? Colors.black : Colors.white70,
                    )),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(children: [
        seg('Wi-Fi', Icons.wifi, 'wifi'),
        seg('USB', Icons.usb, 'usb'),
      ]),
    );
  }

  Widget _guidePanel() {
    final onWifi = model.wifi?['onWifi'] == true;
    final ssid = model.wifi?['ssid'] as String?;
    final usb = _connMode == 'usb';
    final connecting = model.connState == 'connecting';

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        if (model.reconnectAttempt > 0) _reconnectCard(),

        // ① 先选方式（默认 Wi-Fi，与用户实际使用方式一致）
        _modeSwitch(),
        const SizedBox(height: 14),

        // ② 主按钮紧接着出现：不滚动就能点到
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: connecting
              ? null
              : (usb
                  ? () => model.connectUsb().catchError((e) => _snack('USB 连接失败：$e'))
                  : _scanAndConnect),
          child: connecting
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('连接中…'),
                  ],
                )
              : Text(usb ? '连接 USB 相机' : '连接相机'),
        ),
        const SizedBox(height: 10),

        // ③ 状态/前置条件：Wi-Fi 看当前网络，USB 提示前置条件
        if (!usb)
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
                onWifi
                    ? '${model.wifi?['ip'] ?? ''}   信号 ${model.wifi?['signalLevel'] ?? '-'}/4 格'
                    : '请先在系统设置中连接相机热点',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5)),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => model.refreshWifi(),
              ),
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: () => setState(() => _guideOpen = true),
            icon: const Icon(Icons.usb, size: 18),
            label: const Text('USB 需先关闭相机的「连接至智能设备」'),
          ),

        if (!usb) ...[
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => model.openWifiSettings(),
            child: const Text('打开手机 Wi-Fi 设置'),
          ),
        ],

        // ④ 指导默认折叠：一句话摘要 + 展开看全部步骤
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              ListTile(
                leading: Icon(usb ? Icons.usb : Icons.menu_book_outlined,
                    size: 20, color: const Color(0xFFFFE100)),
                title: Text(usb ? 'USB 连接步骤' : 'Wi-Fi 连接步骤',
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  usb
                      ? '关闭「连接至智能设备」→ USB 设为 MTP/PTP → 连线'
                      : '相机进入「连接至智能设备 → Wi-Fi 连接（AP 模式）」',
                  style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.55)),
                ),
                trailing: Icon(_guideOpen ? Icons.expand_less : Icons.expand_more, size: 20),
                onTap: () => setState(() => _guideOpen = !_guideOpen),
              ),
              if (_guideOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: usb
                        ? [
                            // USB 路径最容易踩的坑：没关掉"连接至智能设备"，相机就一直在
                            // 找热点，USB 不会进 PTP；另外相机的 USB 模式必须是 MTP/PTP。
                            _step(1, '相机：MENU → 网络菜单 → 连接至智能设备 → 选「关闭」'),
                            _step(2, '相机：MENU → 网络菜单 → USB → 选「MTP/PTP」'),
                            _step(3, '用数据线连接相机与手机（先在相机关机状态下连线，再开机）'),
                            _step(4, '手机弹出「允许访问设备」时点「允许」，回到本页点上面的按钮'),
                          ]
                        : [
                            _step(1, '相机：MENU → 网络菜单 → 连接至智能设备 → Wi-Fi 连接（AP 模式）'),
                            _step(2, '依次选「建立连接」「开始」，相机屏幕会显示 SSID 与密码'),
                            _step(3, '手机 Wi-Fi 连接该 SSID（密码见相机屏幕）后返回本应用'),
                            _step(4, '回到本页点上面的「连接相机」'),
                          ],
                  ),
                ),
            ],
          ),
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

  /// 自动重连进度卡片。第 1 次尝试前 nextInMs 为 0，此时不显示倒计时。
  Widget _reconnectCard() {
    final n = model.reconnectAttempt;
    final total = model.reconnectTotal;
    final next = (model.reconnectNextMs / 1000).ceil();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFE100)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '连接中断，正在自动重连（第 $n/$total 次）',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFFFFE100)),
                ),
                const SizedBox(height: 4),
                Text(
                  '${next > 0 ? '约 $next 秒后重试。' : ''}'
                  '相机需要时间释放上一个会话（PTP/IP 只允许一台主机），'
                  '这段时间新连接会被相机拒绝，属正常现象。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
