import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_model.dart';
import 'engine/app_log.dart';
import 'pages/connect_page.dart';
import 'pages/downloads_page.dart';
import 'pages/widgets/app_widgets.dart';

/// 全局模型（应用生命周期单例）
final AppModel appModel = AppModel();

void main() {
  // 全局错误捕获：堆栈写入日志面板，便于用户复制反馈
  FlutterError.onError = (details) {
    AppLog.reportError('‼️ FlutterError: ${details.exception}');
    if (details.stack != null) {
      final st = details.stack.toString().split('\n').take(14).join(' | ');
      AppLog.add(st);
    }
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    AppLog.reportError('‼️ 未捕获异常: $e');
    AppLog.add(st.toString().split('\n').take(14).join(' | '));
    return true;
  };
  ErrorWidget.builder = (details) {
    AppLog.reportError('‼️ WidgetError: ${details.exception}');
    if (details.stack != null) {
      AppLog.add(details.stack.toString().split('\n').take(14).join(' | '));
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '页面局部错误（详情见日志）：${details.exception}',
          style: const TextStyle(color: Color(0xFFFF7B7B), fontSize: 12),
        ),
      ),
    );
  };
  runApp(const NikonSyncApp());
}

/// 首页外壳：底部双 Tab（相机 / 手机），仿 SnapBridge 结构
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;

  /// 手机页是否处于选择模式（由该页上报）。
  /// 返回键的处理在本层，而选择状态在手机页内部，所以要把它同步上来。
  bool _phoneHasSelection = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 系统内存压力：把缩略图内存缓存（最多 400 张）丢掉，只留磁盘那份。
  ///
  /// 这个回调一直没人实现，而 `ThumbCache.clearMemory()` 也一直没有调用点——
  /// 相册翻得越多、内存里攒的缩略图越多，正好是低内存时最该释放的东西。
  /// 丢掉后网格会按需从磁盘重新读，肉眼基本无感。
  @override
  void didHaveMemoryPressure() {
    appModel.gateway.thumbCache.clearMemory();
    AppLog.add('系统内存压力：已释放缩略图内存缓存');
  }

  @override
  Widget build(BuildContext context) {
    // 返回键**逐层退**，而不是一按就退出应用：
    //   ① 手机页正在多选 → 先取消多选（用户想退出的是选择，不是应用）
    //   ② 不在相机页 → 先回相机页
    //   ③ 都没有 → 才真的退出
    // 此前没有任何返回拦截：在手机页按返回会直接退出应用，多选态下尤其容易误触。
    return PopScope(
      canPop: _tab == 0 && !_phoneHasSelection,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_phoneHasSelection) {
          _phoneKey.currentState?.exitSelection();
          return;
        }
        if (_tab != 0) setState(() => _tab = 0);
      },
      child: _buildShell(context),
    );
  }

  final GlobalKey<DownloadsPageState> _phoneKey = GlobalKey<DownloadsPageState>();

  Widget _buildShell(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: IndexedStack(
        index: _tab,
        children: [
          ConnectPage(model: appModel),
          DownloadsPage(
            key: _phoneKey,
            model: appModel,
            onSelectionChanged: (v) {
              if (v != _phoneHasSelection) setState(() => _phoneHasSelection = v);
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0F0F0F),
          indicatorColor: kAccent,
          iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Colors.black : Colors.white70),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => TextStyle(
              fontSize: 12,
              color: s.contains(WidgetState.selected) ? Colors.black : Colors.white70,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          height: 64,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.photo_camera_outlined), selectedIcon: Icon(Icons.photo_camera), label: '相机'),
            NavigationDestination(icon: Icon(Icons.smartphone_outlined), selectedIcon: Icon(Icons.smartphone), label: '手机'),
          ],
          onDestinationSelected: (i) => setState(() => _tab = i),
        ),
      ),
    );
  }
}

class NikonSyncApp extends StatelessWidget {
  const NikonSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '尼康速传',
      debugShowCheckedModeBanner: false,
      theme: _darkTheme(),
      home: const HomeShell(),
    );
  }

  /// SnapBridge 风格深色主题：黑底 + 尼康黄
  ThemeData _darkTheme() {
    const yellow = kAccent;
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      colorScheme: base.colorScheme.copyWith(
        primary: yellow,
        onPrimary: Colors.black,
        secondary: yellow,
        onSecondary: Colors.black,
        surface: const Color(0xFF161616),
        onSurface: Colors.white,
        surfaceContainerHighest: const Color(0xFF232323),
        outlineVariant: const Color(0xFF2E2E2E),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: yellow,
          foregroundColor: Colors.black,
          disabledBackgroundColor: const Color(0xFF3A3A22),
          disabledForegroundColor: Colors.white38,
          minimumSize: const Size.fromHeight(48),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white38),
          minimumSize: const Size.fromHeight(48),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
