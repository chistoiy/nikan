import 'package:flutter/material.dart';

import '../../app_model.dart';
import 'app_widgets.dart';

/// AppBar 上的链路状态入口：信号格（+可选文字），点开看详细诊断。
///
/// 存在的原因是一个具体困惑：**"不知道是卡住了、相机断开了，还是别的原因"**。
/// 只显示"已连接"回答不了这个问题，所以这里同时给两层证据：
/// - Wi-Fi 信号强度（RSSI / 格数 / 链路速率）——链路层；
/// - 相机活性（距上次收到相机消息多久、保活探针往返耗时）——协议层。
///
/// 颜色即结论：正常为尼康黄；探针失败转暖橙；断开转灰。
class LinkStatusButton extends StatelessWidget {
  const LinkStatusButton({super.key, required this.model, this.showText = false});

  final AppModel model;

  /// AppBar 空间紧张时只显示信号格；连接页这类宽裕位置可以带文字
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final connected = model.connState == 'connected';
    final usb = model.transport == 'usb';
    // USB 没有 Wi-Fi 信号可测：不要拿家庭 Wi-Fi 的格数冒充相机链路
    final level = (connected && !usb) ? model.wifiLevel : -1;
    final color = !connected
        ? Colors.white38
        : (model.camProbeOk ? kAccent : const Color(0xFFE5A08A));
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showLinkStatusDialog(context, model),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: showText ? 10 : 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SignalBars(level: level, size: 15, color: color),
            if (showText) ...[
              const SizedBox(width: 6),
              Text(
                _shortText(connected, usb, level),
                style: TextStyle(fontSize: 11.5, color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _shortText(bool connected, bool usb, int level) {
    if (!connected) return '未连接';
    if (usb) return 'USB';
    return level < 0 ? '—' : '$level/4';
  }
}

/// 链路诊断详情：把"卡住 / 断开 / 相机忙"三件事分开说清。
Future<void> showLinkStatusDialog(BuildContext context, AppModel model) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: model,
      builder: (ctx, _) {
        final connected = model.connState == 'connected';
        final usb = model.transport == 'usb';
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('连接状态', style: TextStyle(fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SignalBars(
                    level: (connected && !usb) ? model.wifiLevel : -1,
                    size: 18,
                    color: connected
                        ? (model.camProbeOk ? kAccent : const Color(0xFFE5A08A))
                        : Colors.white38,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      model.linkHealthText,
                      style: const TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _row('传输方式', usb ? 'USB 数据线' : 'Wi-Fi 直连相机'),
              _row(
                'Wi-Fi 信号',
                !connected ? '—' : (usb ? '不适用' : model.wifiSignalText),
              ),
              _row('链路速率', model.wifiLinkSpeed > 0 && !usb ? '${model.wifiLinkSpeed} Mbps' : '—'),
              _row(
                '距上次相机消息',
                model.camIdleMs >= 0
                    ? '${(model.camIdleMs / 1000).toStringAsFixed(1)} 秒前'
                    : '本会话尚未收到',
              ),
              _row(
                '保活探针往返',
                model.camRttMs >= 0 ? '${model.camRttMs} ms' : '尚未探测',
              ),
              const SizedBox(height: 12),
              Text(
                '怎么读这块信息：\n'
                '· 下载进度条不动，但这里仍显示"响应 N ms" → 相机在忙，稍等即可；\n'
                '· 这里显示"已 N 秒未收到相机消息" → 链路可能已断，请重新连接；\n'
                '· 信号只有 1 格且速率很低 → 距离太远或有干扰，靠近相机再试。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => model.refreshSignal(),
              child: const Text('立即检测'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}

Widget _row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, color: Colors.white60)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 12.5)),
        ],
      ),
    );
