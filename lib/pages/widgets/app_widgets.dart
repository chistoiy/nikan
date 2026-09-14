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
