import 'package:flutter/material.dart';

/// 全局强调色（尼康黄）。此前在 6 个文件里各写一份字面量。
const Color kAccent = Color(0xFFFFE100);

/// 卡片容器：调试面板与设置页共用同一套装饰。
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(14)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: const Color(0xFF161616),
        child: Padding(padding: padding, child: child),
      );
}

/// 列表空状态：一个灰图标加一句说明。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
}

/// Wi-Fi 信号格（4 格）。
///
/// [level]：0~4（`WifiManager.calculateSignalLevel` 的结果）；**-1 表示"无数据"**
/// （未连接、USB 连接、或系统拒绝提供 RSSI）——此时全部显示为空心，
/// 宁可显示"没有数据"也不要假装满格。
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, this.level = -1, this.size = 16, this.color});

  final int level;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // 1 格及以下用暖色：那是"能用但会卡"的区间，值得提醒
    final active = color ?? (level <= 1 ? const Color(0xFFE5A08A) : kAccent);
    return SizedBox(
      width: size,
      height: size,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: size * 0.19,
              height: size * (0.34 + 0.22 * i),
              decoration: BoxDecoration(
                color: (level >= 0 && i < level) ? active : Colors.white24,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    );
  }
}

/// 连接断开态：相册页与遥控页共用。
class DisconnectedView extends StatelessWidget {
  const DisconnectedView({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text(message, style: const TextStyle(fontSize: 15)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      );
}
