import 'dart:async';

import 'package:flutter/material.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../engine/settings_store.dart';
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

class _ConnectPageState extends State<ConnectPage> with WidgetsBindingObserver {
  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.refreshWifi();
    // 插入相机时系统会把本应用拉起（Manifest 声明了 USB_DEVICE_ATTACHED），
    // 但那一刻事件通道可能还没建立、事件会丢，所以这里主动补查一次；
    // 查到就按设置自动连接 USB，或把模式切到 USB 并提示。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await model.pollUsbAttach();
      if (!mounted) return;
      if (model.usbAttachNotice != null) setState(() => _connMode = 'usb');
      await _autoWifiOnce();
    });
  }

  /// 回到前台时再给自动连接一次机会。
  ///
  /// 典型场景：① 用户按提示到系统设置里加入相机热点，再切回来——此时才是
  /// "该自动连"的时刻，而 initState 早就跑过了；② 用户后台时插上相机。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      model.resetAutoConnectGate();
      unawaited(() async {
        // 先补查 USB（后台插线时系统不会给我们投 Intent），再试 Wi-Fi 自动连接
        await model.pollUsbAttach();
        if (mounted && model.usbAttachNotice != null) setState(() => _connMode = 'usb');
        await _autoWifiOnce();
      }());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 自动连接已记住的相机（仅在当前 Wi-Fi 就是那台相机热点时才动手）
  Future<void> _autoWifiOnce() async {
    final note = await model.tryAutoConnectWifi();
    if (!mounted || note == null) return;
    _snack(note);
  }

  /// 扫描手机所在网段里的相机（相机接入同一路由器时用）。
  ///
  /// 找到的地址会以 chip 形式显示在下方，点一下即连——不必切热点、不必手输 IP。
  Future<void> _scanLan() async {
    try {
      await model.scan();
      if (!mounted) return;
      final n = model.foundCameras.length;
      _snack(n == 0
          ? '本网段内没找到相机。若相机是热点模式，请先在系统设置里加入它的热点；'
              '若是 STA 模式，请确认手机与相机连的是同一个路由器（并关闭路由器的"客户端隔离"）'
          : '找到 $n 台相机，点下面的地址即可连接');
    } catch (e) {
      if (mounted) _snack('扫描失败：${_errText(e)}');
    }
  }

  /// 一行小字提示（引导文案用它，避免到处写样式）
  Widget _hintLine(String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
      );

  /// 一键连接进行中（正在等系统确认框）
  bool _apJoining = false;

  /// **热点没连上**时的两条出路。
  ///
  /// 失败几乎只有三种原因：① 应用里还没有这个热点的密码（最常见——系统 Wi-Fi 里
  /// 输过的密码应用读不到，Android 禁止）；② 密码不对；③ 用户在系统确认框里点了取消
  /// （这种失败来得很快，`connectViaProfile` 不会为它自动重试，也就不会走到这里）。
  ///
  /// 引导必须对症：**主推"填热点密码"**（一次即可，之后「一键连接」全自动）；
  /// "系统面板"降级为备选（免密，但每次连接都要点一下）——
  /// 之前把它放首位，用户每次连接都得绕道系统设置，这正是被反馈的"又要填又要切"。
  Future<void> _apFallbackDialog(CameraProfile c, ApJoinException e) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('热点没连上', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('热点：${c.ssid}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_errText(e.reason),
                style: TextStyle(fontSize: 12.5, height: 1.5, color: Colors.white.withValues(alpha: 0.7))),
            const SizedBox(height: 10),
            Text(e.hint, style: const TextStyle(fontSize: 12.5, height: 1.5)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'settings'),
            child: const Text('系统面板（每次连接都需手点）'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'pass'),
            child: const Text('填热点密码（一次即可）'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'settings') {
      await model.openWifiSettings();
      // 连完切回来会自动连上（见 AppModel.tryAutoConnectWifi 的网络层兜底判断）
    } else if (choice == 'pass') {
      await _askApPassword(c);
    }
  }

  /// 让用户补一次相机热点密码，**保存后立刻重试连接**。
  ///
  /// 相机热点的密码也是印在相机屏幕上的（网络菜单 → 连接至智能设备 → Wi-Fi 连接），
  /// 输一次存在档案里，之后 `WifiNetworkSpecifier` 直接带凭据请求，不再依赖
  /// "系统里有没有保存过这个热点"。
  Future<void> _askApPassword(CameraProfile c) async {
    final ctrl = TextEditingController(text: c.password);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('相机热点密码', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('密码显示在相机屏幕上：网络菜单 → 连接至智能设备 → Wi-Fi 连接。',
                style: TextStyle(fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: '密码', isDense: true, hintText: '相机屏幕上那一串'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存并重试')),
        ],
      ),
    );
    if (ok != true) {
      ctrl.dispose();
      return;
    }
    final pw = ctrl.text.trim();
    ctrl.dispose();
    await model.updateCameraProfile(c, ssid: c.ssid, password: pw, name: c.name, sta: c.sta);
    if (!mounted) return;
    if (pw.isEmpty) {
      _snack('密码为空，仍会用系统已保存的凭据尝试');
    }
    await _connectViaProfile(c);
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
      if (mounted) _snack('已连接相机');
    } catch (e) {
      if (!mounted) return;
      final t = _errText(e);
      final c = model.settings.lastCamera;
      // 手机不在相机网络里时，直连相机必然被拒（ECONNREFUSED，来源是家路由网段）。
      // 这是最容易发生的场景——相机热点没有互联网，**手机不会停在它上面**，
      // 会自己跳回家路由器。这时别只报错：能"一键连接"就把出路直接给出来。
      if (c != null &&
          c.canAutoJoin &&
          (t.contains('ECONNREFUSED') || t.contains('请确认手机已连上相机热点'))) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text('手机不在相机的网络里', style: TextStyle(fontSize: 16)),
            content: Text(
              '刚才的连接是从「${model.wifi?['ip'] ?? '其他网络'}」发起的，到不了相机。\n\n'
              '点下面的「一键连接」，本应用会替你把 Wi-Fi 切到相机热点'
              '「${c.ssid}」（系统弹框点一次“连接”即可，密码用系统已保存的）。',
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('一键连接'),
              ),
            ],
          ),
        );
        if (go == true && mounted) await _connectViaProfile(c);
        return;
      }
      _snack('连接失败：$t');
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

  /// 「我的相机」卡片：多台相机各自一键连接，也能新增。
  ///
  /// 做成列表是因为用户不只连自己的相机，也会连别人的——每台的热点名/密码/地址都不同。
  /// 新增时**从系统列表里挑热点名**，不让用户手抄一长串 SSID（那串字母数字极易输错）。
  ///
  /// 文案随当前链路切换：USB 模式下**完全不提"热点"**，否则用户会以为这里只支持热点。
  Widget _cameraListCard({required bool usb}) {
    final cams = model.cameras;
    final lastSsid = model.settings.lastCamera?.ssid;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.photo_camera_outlined, size: 18, color: kAccent),
              const SizedBox(width: 8),
              const Text('我的相机',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              const Spacer(),
              // "添加相机"是"录入热点名"的入口，只在 Wi-Fi 模式下有意义
              if (!usb)
                TextButton.icon(
                  onPressed: _addCamera,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加', style: TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
          Text(
            usb
                ? '这里是连过的相机记录（数据线连接会记下相机名）。插好数据线后点「连接」。'
                : '这里是连过的相机记录（Wi-Fi 与数据线都会记）。点「连接」按记录的方式连；'
                    '数据线连过的相机补一个热点名后，也能走 Wi-Fi 一键连接。',
            style: TextStyle(fontSize: 11, height: 1.4, color: Colors.white.withValues(alpha: 0.4)),
          ),
          for (final c in cams)
            _cameraRow(
              c,
              usb: usb,
              isLast: !usb && c.ssid.isNotEmpty && c.ssid == lastSsid,
            ),
          const SizedBox(height: 4),
          Text(
            usb
                ? (model.autoConnectUsb
                    ? '自动连接已开启：插入数据线后会自动连相机（设置页可关）'
                    : '自动连接已关闭：插入数据线后需要手动点「连接」')
                : (model.autoConnectWifi
                    ? '自动连接已开启：连上其中任一台的热点后会自动连相机（设置页可关）'
                    : '自动连接已关闭：需要手动点「连接」'),
            style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }

  Widget _cameraRow(CameraProfile c, {required bool usb, required bool isLast}) {
    final busy = model.connState == 'connecting';
    // USB 模式下"连接"= 让相机走数据线：必须有相机真的插着才给按钮，
    // 否则点下去只会得到一句失败提示。
    final usbReady = model.usbAttachNotice != null;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(c.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ),
                    if (isLast) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: kAccent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('上次使用',
                            style: TextStyle(fontSize: 9.5, color: kAccent)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 1),
                Text(c.subtitleFor(usb: usb),
                    style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.45))),
              ],
            ),
          ),
          if (usb)
            TextButton(
              onPressed: (busy || !usbReady)
                  ? null
                  : () async {
                      try {
                        await model.connectUsb();
                        if (mounted) setState(() {});
                      } catch (e) {
                        if (mounted) _snack('USB 连接失败：${_errText(e)}');
                      }
                    },
              child: Text(
                usbReady ? '连接' : '未检测到相机',
                style: TextStyle(fontSize: 12.5, color: usbReady ? kAccent : Colors.white30),
              ),
            )
          else
            TextButton(
              onPressed: busy ? null : () => _connectViaProfile(c),
              child: Text(c.canAutoJoin ? '一键连接' : '连接',
                  style: const TextStyle(fontSize: 12.5, color: kAccent)),
            ),
          PopupMenuButton<String>(
            tooltip: '更多',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
            onSelected: (v) async {
              if (v == 'edit') {
                await _cameraEditDialog(existing: c);
              } else if (v == 'remove') {
                // 按对象身份删：SSID 可能为空（只连过 USB），用 SSID 当键会误删
                await model.removeCameraProfile(c);
                if (mounted) {
                  setState(() {});
                  _snack('已删除「${c.label}」');
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑', style: TextStyle(fontSize: 14))),
              PopupMenuItem(value: 'remove', child: Text('删除', style: TextStyle(fontSize: 14))),
            ],
          ),
        ],
      ),
    );
  }

  /// 新增相机：先让用户从**附近热点列表**里选 SSID（免手抄），再填密码。
  Future<void> _addCamera() => _cameraEditDialog();

  /// 新增/编辑相机档案。
  ///
  /// 流程按"最少输入"设计：
  /// ① 点「选择附近热点」→ 系统扫描结果列表 → 点选相机那台（SSID 自动填好）；
  /// ② 密码**可以留空**——手机第一次连过该热点后系统就记住了凭据；
  /// ③ 保存后可直接连接，连上后相机名与地址会自动写回这台档案。
  Future<void> _cameraEditDialog({CameraProfile? existing}) async {
    // 缺热点名时按三级顺序尽力预填，目标是**让用户什么都不用输**：
    // ① 读当前所连网络（正连着相机热点时是事实，但本机 ROM 读不到 SSID）；
    // ② 用相机自身上报的型号 + 序列号推定（实测能推出正确热点名）；
    // ③ 都不行就留空，用户手输 —— 绝不阻塞（预填失败不是错误）。
    var autoFilled = false;
    var initialSsid = existing?.ssid ?? '';
    var fillNote = '';
    if (initialSsid.isEmpty && existing != null) {
      final cur = await _currentSsidSafe();
      if (cur != null) {
        initialSsid = cur;
        autoFilled = true;
        fillNote = '已按当前所连网络自动填入（若不对可改）';
      } else {
        final guess = CameraProfile.deriveApSsid(
          cameraName: existing.name,
          serial: existing.serial,
        );
        if (guess != null) {
          initialSsid = guess;
          autoFilled = true;
          fillNote = '由相机序列号推得，请与相机屏幕上的一串核对';
        }
      }
    } else if (initialSsid.isNotEmpty && (existing?.ssidDerived ?? false)) {
      fillNote = '当前是推定值，与相机屏幕核对后保存即可转正';
    }
    if (!mounted) return;
    final ssidCtrl = TextEditingController(text: initialSsid);
    final passCtrl = TextEditingController(text: existing?.password ?? '');
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    var sta = existing?.sta ?? false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(existing == null ? '添加相机' : '编辑相机', style: const TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ssidCtrl,
                  decoration: InputDecoration(
                      labelText: '相机热点 SSID',
                      isDense: true,
                      helperText: autoFilled
                          ? fillNote
                          : '相机屏幕上那一串（如 NIKON_Z50_2_46907）',
                      helperStyle: TextStyle(
                          fontSize: 10.5,
                          color: autoFilled ? kAccent : Colors.white.withValues(alpha: 0.5))),
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                // 两个"免手抄"入口横排各占一半：窄弹窗里如果和输入框同一行，
                // 按钮会被挤到几乎看不见（用户反馈过"找不到选热点的地方"）。
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final s = await _currentSsidSafe();
                          if (!mounted) return;
                          if (s != null) {
                            ssidCtrl.text = s;
                            setDlg(() {});
                            return;
                          }
                          // 本机 ROM 读不到当前 SSID：退一步用相机自身上报的
                          // 型号 + 序列号推导（实测能推出正确热点名）
                          final guess = CameraProfile.deriveApSsid(
                            cameraName: nameCtrl.text,
                            serial: existing?.serial,
                          );
                          if (guess == null) {
                            _snack('读不到当前热点名，也无法推定：请照相机屏幕手输（或先连一次相机让档案记下序列号）');
                            return;
                          }
                          ssidCtrl.text = guess;
                          setDlg(() {});
                          _snack('已按相机序列号推得「$guess」，请与相机屏幕核对');
                        },
                        icon: const Icon(Icons.wifi_lock, size: 15),
                        label: const Text('用当前网络', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        // 不要求用户手抄长 SSID：列表来自系统（当前网络 / 已保存 / 附近扫描）
                        onPressed: () async => _pickNearbySsid((v) {
                          ssidCtrl.text = v;
                          setDlg(() {});
                        }),
                        icon: const Icon(Icons.list, size: 15),
                        label: const Text('选择附近热点', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  decoration: const InputDecoration(
                    labelText: '热点密码（填一次即可）',
                    isDense: true,
                    helperText: '存档后「一键连接」全自动，不用再输；不填则每次连接要在系统面板手点',
                    helperStyle: TextStyle(fontSize: 10.5),
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: '备注名（可留空，连上后自动填相机名）', isDense: true),
                  autocorrect: false,
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('相机接在同一路由器（STA 模式）', style: TextStyle(fontSize: 13.5)),
                  subtitle: const Text('选它就不用切热点，直接扫同一网络；速度也更快',
                      style: TextStyle(fontSize: 11)),
                  value: sta,
                  activeThumbColor: kAccent,
                  onChanged: (v) => setDlg(() => sta = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (ssidCtrl.text.trim().isEmpty && !sta) {
                  _snack('请填热点 SSID 或选「同一路由器」');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      if (existing != null) {
        // **就地修改**这条档案。走 saveCameraProfile 的话，因为旧记录的 SSID 是空的，
        // 按新 SSID 匹配不到 → 会另建一条，旧的无 SSID 记录永远留在列表里，
        // 用户看到的就是"补了 SSID 还是不显示相机热点"（真机反馈原文）。
        await model.updateCameraProfile(
          existing,
          ssid: ssidCtrl.text,
          password: passCtrl.text,
          name: nameCtrl.text,
          sta: sta,
        );
      } else {
        await model.saveCameraProfile(
          ssid: ssidCtrl.text.trim(),
          password: passCtrl.text,
          name: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
          sta: sta,
        );
      }
      if (mounted) {
        setState(() {});
        _snack(existing == null
            ? '已保存。点「连接」即可（连上后会自动补全相机名与地址）'
            : '已保存到「${existing.label}」。点「连接」即可');
      }
    }
    ssidCtrl.dispose();
    passCtrl.dispose();
    nameCtrl.dispose();
  }

  /// 「重新扫描」在弹出列表里的哨兵值
  static const String _kRescan = '\u0000rescan';

  /// 读当前连接的热点名（读不到返回 null，不抛）
  Future<String?> _currentSsidSafe() async {
    try {
      final s = await NikonEngine.currentSsid();
      if (s != null && s.isNotEmpty && !s.startsWith('<')) return s;
    } catch (_) {}
    return null;
  }

  /// 弹出"相机热点"选择列表。
  ///
  /// 这是**避开手抄 SSID** 的关键（SSID 通常是一长串字母数字，肉眼抄极易出错）。
  /// 三个来源一起给，按"越好用越靠前"排：
  /// ① **手机现在就连着的热网**——手机已连着相机热点时一步到位；
  /// ② **手机已保存的热点**——相机热点必然是用户手动连过一次的，名字几乎必然在其中；
  ///    而且它**不需要现扫**（新装应用/系统限流时现扫常常长时间为空）；
  /// ③ **附近扫到的热点**——按信号强度排。
  Future<void> _pickNearbySsid(ValueChanged<String> onPick) async {
    while (true) {
      final picked = await _showSsidSheet();
      if (picked == null) return; // 取消
      if (picked == _kRescan) continue; // 重新扫描
      onPick(picked);
      return;
    }
  }

  /// 展示选择列表；返回选中的 SSID / `_kRescan` / null（取消）
  Future<String?> _showSsidSheet() async {
    final perm = await model.ensureWifiScanPermission();
    if (!mounted) return null;
    if (perm != WifiScanPerm.granted) {
      await _wifiPermGuide(perm);
      return null;
    }
    final cur = await _currentSsidSafe();
    final saved = await model.savedWifiSsids();
    List<Map<String, dynamic>> nearby = const [];
    try {
      nearby = await NikonEngine.scanWifiNetworks();
    } catch (e) {
      if (mounted) _snack('扫描失败：${_errText(e)}');
    }
    if (!mounted) return null;

    // 去重：当前网络 > 已保存 > 附近扫描（后面的不再重复列出）
    final rows = <({String ssid, String note})>[];
    if (cur != null) rows.add((ssid: cur, note: '手机现在就连着它'));
    for (final s in saved) {
      if (rows.any((r) => r.ssid == s)) continue;
      rows.add((ssid: s, note: '手机已保存的热点'));
    }
    for (final n in nearby) {
      final ssid = (n['ssid'] as String?) ?? '';
      if (ssid.isEmpty || rows.any((r) => r.ssid == ssid)) continue;
      final level = (n['level'] as num?)?.toInt() ?? -100;
      rows.add((ssid: ssid, note: '附近扫到 · 信号 $level dBm'));
    }

    if (!mounted) return null;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 2),
              child: Row(children: [
                Text('选择相机热点', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '相机屏幕上显示的 SSID 就在下面。选不到时：先让相机进入 Wi-Fi 连接模式，'
                '再点「重新扫描」。',
                style: TextStyle(fontSize: 11.5, height: 1.4, color: Colors.white.withValues(alpha: 0.45)),
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Text(
                  '没找到可列出的热点。请确认：\n'
                  '· 手机 Wi-Fi 已打开\n'
                  '· 相机已进入「连接至智能设备 → Wi-Fi 连接」（热点开着才会出现）\n'
                  '· 已授予「附近的设备」权限\n\n'
                  '部分系统会限制第三方应用扫描热点（真机实测 startScan 直接被拒），'
                  '此时**请直接在上一个输入框手输**相机屏幕上显示的 SSID——'
                  '只要手机此刻正连着相机热点，上面的「用当前网络」也能一键填上。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: Colors.white.withValues(alpha: 0.6)),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    leading: Icon(
                      i == 0 && cur != null ? Icons.wifi_lock : Icons.wifi,
                      size: 18,
                      color: i == 0 && cur != null ? kAccent : Colors.white54,
                    ),
                    title: Text(rows[i].ssid, style: const TextStyle(fontSize: 13.5)),
                    subtitle: Text(rows[i].note, style: const TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(ctx, rows[i].ssid),
                  ),
                ),
              ),
            const Divider(height: 12),
            TextButton.icon(
              onPressed: () => Navigator.pop(ctx, _kRescan),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新扫描', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// 扫描权限没拿到时的引导。
  ///
  /// 必须区分两种情况（这正是之前"点了没反应"的根源）：
  /// 用户**刚拒绝**可以再弹一次；系统**不再弹框**就只能去应用设置。
  Future<void> _wifiPermGuide(WifiScanPerm perm) async {
    final blocked = perm == WifiScanPerm.blocked;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('需要「附近的设备」权限', style: TextStyle(fontSize: 16)),
        content: Text(
          blocked
              ? '系统已经不再弹授权框了（权限被拒绝过，或本机策略如此），所以只能手动打开：\n\n'
                  '应用设置 → 权限 → 附近的设备 → 允许\n\n'
                  '打开后回来重新点「选择附近热点」即可。'
              : '列出附近热点需要「附近的设备」权限，刚才被拒绝了。可以再试一次。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(blocked ? '去设置授权' : '再试一次'),
          ),
        ],
      ),
    );
    if (go != true) return;
    if (blocked) {
      await model.openAppSettings();
    } else {
      // 再弹一次系统框；结果由下一次点击时的状态检查接手
      await NikonEngine.requestWifiScanPermission();
      if (mounted) _snack('请在系统弹框里允许「附近的设备」');
    }
  }

  /// 按档案一键连接（AP 档案会先请系统加入热点）
  Future<void> _connectViaProfile(CameraProfile c) async {
    setState(() => _apJoining = true);
    try {
      final note = await model.connectViaProfile(c);
      if (mounted) {
        _snack(note);
        setState(() {});
      }
    } on ApJoinException catch (e) {
      // 热点这一步就失败了：给对症的出路（填密码 / 去系统设置连一次）
      if (mounted) await _apFallbackDialog(c, e);
    } on StateError catch (e) {
      // 档案缺热点名：引导去补一次（选附近热点），而不是让他对着"连接失败"发懵
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('还缺相机热点名', style: TextStyle(fontSize: 16)),
          content: Text(e.message, style: const TextStyle(fontSize: 13, height: 1.5)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('现在补上'),
            ),
          ],
        ),
      );
      if (go == true) await _cameraEditDialog(existing: c);
    } catch (e) {
      if (mounted) _snack('连接失败：${_errText(e)}');
    } finally {
      if (mounted) setState(() => _apJoining = false);
    }
  }

  /// 「已记住的相机」一行（已连接面板里用）：只做"确认 + 忘记"，
  /// 不给"重连"——此刻已经连着，重连没有意义。
  Widget _rememberedRow() {
    final p = model.settings.lastCamera;
    final label = p?.label ?? '这台相机';
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              title: const Text('忘记所有已记录的相机？', style: TextStyle(fontSize: 16)),
              content: Text(
                '将清空 ${model.cameras.length} 台相机的记录（热点名/密码/地址），'
                '之后不再自动连接，需要重新添加。',
                style: const TextStyle(fontSize: 13.5),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('忘记')),
              ],
            ),
          );
          if (ok != true) return;
          await model.forgetCamera();
          if (mounted) {
            setState(() {});
            _snack('已忘记所有相机');
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bookmark_outline, size: 15, color: kAccent),
              const SizedBox(width: 6),
              Text('已记住：$label（共 ${model.cameras.length} 台）',
                  style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.55))),
              const SizedBox(width: 4),
              Text('点此忘记',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.3))),
            ],
          ),
        ),
      ),
    );
  }

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
        const SizedBox(height: 14),
        // 已连接时也要能**确认"这台相机被记住了"**——卡片只放在未连接面板时，
        // 用户连上后回来看不到它，会以为没记住（反馈正是如此）。
        if (model.settings.hasRememberedCamera) _rememberedRow(),
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
    // "上次使用的那台相机"，用于顶部一键连接按钮与热点提示
    final lastCamera = model.settings.lastCamera;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        if (model.reconnectAttempt > 0) _reconnectCard(),

        // ① 先选方式（默认 Wi-Fi，与用户实际使用方式一致）
        _modeSwitch(),
        const SizedBox(height: 14),

        // ①b 检测到 USB 接入：把它说清楚，否则用户看到的是"插上线、App 自己开了、
        //    然后什么都不做"（这正是之前 Manifest 声明了却无人处理的后果）
        if (model.usbAttachNotice != null) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFFFE100).withValues(alpha: 0.45)),
            ),
            child: Row(
              children: [
                const Icon(Icons.usb, size: 18, color: Color(0xFFFFE100)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '检测到 ${model.usbAttachNotice} 已通过 USB 接入，点下面的按钮连接',
                    style: const TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '不再提示',
                  onPressed: () async {
                    await model.dismissUsbAttach();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // ② **先确认网络，再连接**。第一次用的顺序天然是
        //    "去系统设置连上相机 Wi-Fi → 回来点连接"，所以"当前网络 + 打开 Wi-Fi 设置"
        //    必须排在「连接相机」**上面**；反过来会让人对着一个注定失败的按钮先点一次。
        //    USB 模式没有这个前置，主按钮直接放最上面。
        if (!usb) ...[
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
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => model.openWifiSettings(),
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('打开手机 Wi-Fi 设置（先连上相机热点）'),
          ),
          const SizedBox(height: 12),
        ],

        // ③ 主按钮
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

        // ④ USB 的前置条件说明（Wi-Fi 的网络状态已挪到上面）
        if (usb)
          OutlinedButton.icon(
            onPressed: () => setState(() => _guideOpen = true),
            icon: const Icon(Icons.usb, size: 18),
            label: const Text('USB 需先关闭相机的「连接至智能设备」'),
          ),

        if (!usb) ...[
          const SizedBox(height: 10),
          // 相机接入**同一个路由器**（相机端选 STA 模式）时，手机完全不用切热点，
          // 直接在局域网里就能找到它——这也是唯一能顺带拿到 5GHz 的接法。
          // 之前 model.scan() 写了却没有任何入口，等于这条路在界面上没有门。
          OutlinedButton.icon(
            onPressed: (!onWifi || model.scanning) ? null : _scanLan,
            icon: model.scanning
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search, size: 18),
            label: Text(model.scanning ? '正在扫描本网段…' : '扫描同一网络内的相机'),
          ),
          const SizedBox(height: 8),
          // AP 模式（最常用）的"一键"：App 内加入相机热点 + 连相机，不必去系统设置。
          // 有档案（含热点名）才显示；没有就引导去「添加相机」。
          if (lastCamera?.canAutoJoin == true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  onPressed: (model.connState == 'connecting' || _apJoining)
                      ? null
                      : () => _connectViaProfile(lastCamera!),
                  icon: _apJoining
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_lock, size: 18),
                  label: Text(_apJoining
                      ? '等待系统确认…'
                      : '一键连接「${lastCamera!.label}」'),
                ),
              ),
            ),
          // 「添加相机」只在**一条记录都没有**时出现：有记录时，「我的相机」卡片里
          // 已经有一个「添加」，两个入口做同一件事只会让人犹豫点哪个（真机反馈）。
          if (model.cameras.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: _addCamera,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加相机（录一次热点名，之后一键连）'),
              ),
            ),
          const SizedBox(height: 8),
          // 说清"要不要切热点"这个最容易卡住的问题
          if (!onWifi)
            _hintLine('未连接 Wi-Fi：先在系统设置里连上相机热点，或连上相机所接入的路由器')
          else if (lastCamera != null &&
              lastCamera.canAutoJoin &&
              ssid != null &&
              !ssid.startsWith('<') &&
              ssid != lastCamera.ssid)
            _hintLine(
              '当前网络是「$ssid」，不是「${lastCamera.ssid}」。'
              '若相机已接入同一路由器（相机端：连接至智能设备 → Wi-Fi连接 → STA mode），'
              '点上面的「扫描同一网络内的相机」即可直接连，无需切换热点。',
            ),
        ],

        // ④ 已记录的相机：放在"怎么连"的设置之后，而不是页面最上方——
        //    这一页同时管 Wi-Fi 与 USB，把"上次的相机"顶在最上面会让人以为只支持热点连接。
        if (model.cameras.isNotEmpty) ...[
          const SizedBox(height: 14),
          _cameraListCard(usb: usb),
        ],

        // ⑤ 指导默认折叠：一句话摘要 + 展开看全部步骤
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
                            _step(
                              5,
                              '【另一种接法，更快】相机同一菜单里改选 Wi-Fi连接 → STA mode，'
                              '选中你家路由器（优先 5GHz）并输密码；'
                              '手机保持连家里路由器不动，回本页点「扫描同一网络内的相机」即可。'
                              '此接法不受相机自建热点的 11g 上限限制，速度上限明显更高',
                            ),
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
