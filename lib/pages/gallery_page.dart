import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../models/camera_file.dart';
import 'viewer_page.dart';
import 'widgets/app_widgets.dart';
import 'widgets/drag_selection.dart';
import 'widgets/gallery_cell.dart';
import 'widgets/gallery_filter_bar.dart';
import 'widgets/gallery_options_sheet.dart';
import 'widgets/gallery_status_bars.dart';
import 'widgets/link_status.dart';

/// 相册页：3 列缩略图网格、按需加载、类型/文件夹筛选、
/// 长按进入选择 + 按住滑动批量勾选（微信式）、批量下载。
///
/// 呈现部件已拆到 widgets/：单元格 GalleryCell、筛选栏 GalleryFilterBar、
/// 状态条 gallery_status_bars、选项弹窗 gallery_options_sheet，
/// 滑动多选状态机在 DragSelection。本文件只负责装配与相机交互。
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, required this.model});

  final AppModel model;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  static const int _cols = 3;
  static const double _gap = 2;

  /// 单元格宽高比。相机出片是 3:2，正方形会把横构图切坏，
  /// 而且同样的屏幕高度下 3:2 能多显示约一半行数。
  static const double _cellAspect = 3 / 2;

  String _kind = 'all'; // all / jpeg / raw / video
  String _folder = '全部';

  /// 只看未下载（与 _kind 是正交维度，因此单独一个开关）
  bool _undownloadedOnly = false;

  /// 只看 RAW+JPEG 成对照片（相机开了"同时记录"时，一张照片是两个文件）
  bool _pairedOnly = false;

  /// 按拍摄日期分组显示（分组后点日期头部即可整选当天）
  bool _groupByDay = false;

  /// 已折叠的日期分组（键 = 日期标题）。
  ///
  /// 存在的理由：按天分组时，一天可能有几百张，想找前一天的就得从头滑到尾。
  /// 折叠状态只在本次会话内保留，不做持久化——它是"临时看"的操作，不是设置。
  final Set<String> _collapsedDays = {};

  /// 分组模式下的逐格命中测试表。
  /// 分组后行高不再固定（夹着日期头部），坐标换算失效，改用矩形命中
  /// ——与手机页同一套做法。
  final Map<int, GlobalKey> _cellKeys = {};
  final GlobalKey _gridKey = GlobalKey();
  final ScrollController _gridCtrl = ScrollController();
  List<CameraFile>? _filteredCache;

  /// 滑动多选状态机（长按起选、滑动范围、边缘自动滚动）
  late final DragSelection<int> _sel = DragSelection<int>(
    keyAt: (i) => _filtered[i].handle,
    itemCount: () => _filtered.length,
    indexAt: (g) => _groupByDay ? _hitIndex(g) : _indexAt(g),
    scrollController: _gridCtrl,
    viewportBox: () => _gridKey.currentContext?.findRenderObject() as RenderBox?,
    onChanged: () => setState(_syncPairs),
  );

  /// RAW+JPEG 成对联动：任何选择变化后补齐/去除配对的另一半。
  ///
  /// 放在 [DragSelection.onChanged] 里做，是因为选择集的所有入口（点格子、点勾选
  /// 热区、长按滑动、全选、按日期整组）最终都会走这个回调——只在这一处实现，
  /// 就不会出现"点选会联动、滑动不会"这种半生效。
  bool _syncingPairs = false;

  void _syncPairs() {
    if (!model.linkRawJpegPairs || _syncingPairs) return;
    _syncingPairs = true;
    try {
      final byHandle = {for (final f in model.files) f.handle: f};
      // 配对是一对一关系，一轮即可收敛；两轮是保险（配对在索引过程中可能刚补齐）
      for (var pass = 0; pass < 2; pass++) {
        var changed = false;
        // ① 选中项 → 带上它的配对
        for (final h in _sel.selected.toList()) {
          final p = byHandle[h]?.pairHandle;
          if (p != null && !_sel.selected.contains(p)) {
            _sel.selected.add(p);
            changed = true;
          }
        }
        // ② 取消项 → 带下它的配对（否则配对会一直粘着，取消不掉）
        for (final f in byHandle.values) {
          final p = f.pairHandle;
          if (p == null) continue;
          if (!_sel.selected.contains(f.handle) && _sel.selected.contains(p)) {
            _sel.selected.remove(p);
            changed = true;
          }
        }
        if (!changed) break;
      }
      if (_sel.selected.isEmpty && _sel.selectMode) _sel.selectMode = false;
    } finally {
      _syncingPairs = false;
    }
  }

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    model.addListener(_onModelChanged);
  }

  @override
  void dispose() {
    model.removeListener(_onModelChanged);
    _sel.dispose();
    _gridCtrl.dispose();
    super.dispose();
  }

  Object? _filterFp;

  /// 模型变化时按**指纹**决定要不要丢弃筛选缓存，并剔除已不在列表里的选择。
  ///
  /// 之前是无条件 `_filteredCache = null`：而 `AppModel._notifyThrottled` 只有 150ms 节流，
  /// 索引期间每补全一个文件、下载期间每 300ms 报一次进度都会通知——对 5000 张的卡，
  /// 等于每 150ms 重排一次 5000 项，并连带重建整个网格（明显的掉帧来源）。
  ///
  /// 指纹**必须**带上 `indexedCount`：文件详情是逐个补全的，而筛选依赖 `kind`、
  /// 排序依赖 `name`/`dateRaw`——只比列表长度会漏掉"又一个文件的详情到了"，
  /// 结果就是筛选与排序结果停在旧状态（与刚修掉的 `files.length % 16` 是同一类错误）。
  void _onModelChanged() {
    final fp = _filterFingerprint();
    if (fp != _filterFp) {
      _filterFp = fp;
      _filteredCache = null;
    }
    final identity = identityHashCode(model.files);
    if (identity != _lastFilesIdentity) {
      // 重新枚举（换卡/刷新/断开重连）后回收旧键：`_cellKeys` 只增不减，
      // 换卡后上一张卡的句柄与 GlobalKey 仍被 map 持有
      _lastFilesIdentity = identity;
      final alive = model.files.map((f) => f.handle).toSet();
      _cellKeys.removeWhere((h, _) => !alive.contains(h));
    }
    if (_sel.selected.isEmpty) return;
    _sel.prune(model.files.map((f) => f.handle).toSet());
  }

  int? _lastFilesIdentity;

  Object _filterFingerprint() => Object.hash(
        identityHashCode(model.files),
        model.files.length,
        model.indexedCount,
        model.sortMode,
        _kind,
        _folder,
        _undownloadedOnly,
        _pairedOnly,
        // 只有"只看未下载"依赖去重记录，其余筛选下记录变化不影响结果集。
        // 用 revision 而不是 length：同长度下的替换（补 uri）也必须让缓存失效。
        _undownloadedOnly ? model.gateway.records.revision : 0,
      );

  // ------------------------------------------------------------ 筛选与排序

  /// 当前筛选+排序后的列表。
  /// 必须返回新列表：此前默认筛选下直接对 `model.files` 本体排序，
  /// 等于在渲染期改写全局状态，并把正在被 ViewerPage 持有的引用一起重排。
  List<CameraFile> get _filtered => _filteredCache ??= _computeFiltered();

  List<CameraFile> _computeFiltered() {
    var list = List<CameraFile>.of(model.files);
    if (_undownloadedOnly) list = list.where((f) => !model.isDownloaded(f)).toList();
    if (_kind != 'all') list = list.where((f) => f.kind == _kind).toList();
    if (_pairedOnly) list = list.where((f) => f.isPaired).toList();
    if (_folder != '全部') list = list.where((f) => f.folder == _folder).toList();
    int cmp(CameraFile a, CameraFile b) {
      switch (model.sortMode) {
        case 'oldest':
          final da = a.dateRaw, db = b.dateRaw;
          if (da == null && db == null) return a.handle.compareTo(b.handle);
          if (da == null) return 1;
          if (db == null) return -1;
          final c = da.compareTo(db);
          return c != 0 ? c : a.handle.compareTo(b.handle);
        case 'nameAsc':
        case 'nameDesc':
          final na = a.name, nb = b.name;
          if (na == null && nb == null) return a.handle.compareTo(b.handle);
          if (na == null) return 1;
          if (nb == null) return -1;
          final c = na.compareTo(nb);
          return model.sortMode == 'nameAsc' ? c : -c;
        default: // newest：文件夹倒序 + 句柄倒序
          final c = b.folder.compareTo(a.folder);
          return c != 0 ? c : b.handle.compareTo(a.handle);
      }
    }

    return list..sort(cmp);
  }

  /// 改筛选条件：丢弃筛选缓存，并把选择集收敛到新列表上。
  /// 不收敛的话"已选 N"会包含看不见的条目，"取消全选"也按不干净。
  void _setFilter({String? kind, String? folder, bool? undownloaded, bool? groupByDay, bool? pairedOnly}) =>
      setState(() {
        if (kind != null) _kind = kind;
        if (folder != null) _folder = folder;
        if (undownloaded != null) _undownloadedOnly = undownloaded;
        if (groupByDay != null) _groupByDay = groupByDay;
        if (pairedOnly != null) _pairedOnly = pairedOnly;
        _filteredCache = null;
        _sel.prune(_filtered.map((f) => f.handle).toSet());
      });

  void _showOptions() {
    final folders = model.files
        .map((f) => f.folder)
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    showGalleryOptionsSheet(
      context: context,
      folders: folders,
      kind: _kind,
      folder: _folder,
      sortMode: model.sortMode,
      variant: model.downloadVariant,
      onKind: (v) => _setFilter(kind: v),
      onFolder: (v) => _setFilter(folder: v),
      onSort: model.setSortMode,
      onVariant: model.setDownloadVariant,
    );
  }

  // ------------------------------------------------------------ 索引换算

  /// 全局坐标 → 网格单元格索引
  int? _indexAt(Offset global) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return _indexOf(box.globalToLocal(global), box.size.width);
  }

  GlobalKey _keyOf(int handle) => _cellKeys.putIfAbsent(handle, GlobalKey.new);

  /// 分组模式下的索引换算：逐个单元格做矩形包含判断。
  /// 未构建的单元格没有 context，直接跳过（只有可见的才可能命中）。
  int? _hitIndex(Offset global) {
    final files = _filtered;
    for (var i = 0; i < files.length; i++) {
      final ctx = _cellKeys[files[i].handle]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(global)) return i;
    }
    return null;
  }

  /// 是否处于任何筛选状态（决定一键下载的范围与文案）
  bool get _filterActive => _kind != 'all' || _folder != '全部' || _undownloadedOnly;

  /// 条目所属的日期标题。PTP 原始时间 "YYYYMMDDThhmmss" 最可靠，
  /// 退到相机给的可读字符串；两者都没有说明详情尚未读到。
  static String _dayOf(CameraFile f) {
    final raw = f.dateRaw;
    if (raw != null && raw.length >= 8) {
      final y = raw.substring(0, 4);
      final m = int.tryParse(raw.substring(4, 6));
      final d = int.tryParse(raw.substring(6, 8));
      if (m != null && d != null) return '$m月$d日 · $y';
    }
    final text = f.dateText;
    return (text != null && text.isNotEmpty) ? text : '未知日期';
  }

  /// 按天切分当前列表。列表已排序，同一天的条目通常连续；
  /// 若排序把同一天拆开（如按文件名排序），会如实出现两个同名分组。
  List<({String day, int base, List<CameraFile> files})> _daySections(List<CameraFile> files) {
    final out = <({String day, int base, List<CameraFile> files})>[];
    String? curDay;
    List<CameraFile>? bucket;
    for (var i = 0; i < files.length; i++) {
      final day = _dayOf(files[i]);
      if (bucket == null || day != curDay) {
        bucket = <CameraFile>[];
        out.add((day: day, base: i, files: bucket));
        curDay = day;
      }
      bucket.add(files[i]);
    }
    return out;
  }

  /// 数据空间单元格索引：屏幕局部坐标 + 列表滚动偏移（否则滚动后选错行）
  int? _indexOf(Offset local, double width) {
    final cellW = (width - _gap * (_cols - 1)) / _cols;
    if (cellW <= 0) return null;
    final files = _filtered;
    if (files.isEmpty) return null;
    // 行高由单元格宽高比决定：改动 childAspectRatio 时这里必须同步，
    // 否则滑动选择会按错误的行距换算、选到别的行
    final cellH = cellW / _cellAspect;
    final scroll = _gridCtrl.hasClients ? _gridCtrl.offset : 0.0;
    var row = ((scroll + local.dy) / (cellH + _gap)).floor();
    if (row < 0) row = 0;
    final col = (local.dx / (cellW + _gap)).floor().clamp(0, _cols - 1);
    var idx = row * _cols + col;
    if (idx >= files.length) idx = files.length - 1;
    return idx;
  }

  // ------------------------------------------------------------ 动作

  /// 打开大图查看器。传入当次渲染所用的列表，避免查看器内部重算导致索引错位。
  void _openViewer(int index, List<CameraFile> files) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewerPage(
          model: model,
          files: List<CameraFile>.of(files),
          initialIndex: index,
          // 把"选中"能力带进查看器：挑图时最顺的是"放大看清 → 决定要不要 → 下一张"，
          // 不必退出去再点角标
          isSelected: (h) => _sel.selected.contains(h),
          onToggleSelect: (h) => _sel.enterSelectAndToggle(h),
        ),
      ),
    );
  }

  /// 下载结束后的统一反馈。
  ///
  /// 汇总串本身以前就有，但**没有下文**：用户看到"失败 3"却不知道是哪三张、为什么，
  /// 也没法重试——而那三张往往正是他最想要的。所以有问题时额外给一个入口。
  void _afterDownload(String result) {
    if (result.isEmpty || !mounted) return;
    if (model.dlIssues.isEmpty) {
      showNotice(context, result);
      return;
    }
    showNotice(
      context,
      result,
      duration: const Duration(seconds: 12),
      action: SnackBarAction(
        label: '查看这 ${model.dlIssues.length} 张',
        onPressed: _showDownloadIssues,
      ),
    );
  }

  /// 列出本次跳过/失败的文件与原因，并支持一键重试失败项。
  Future<void> _showDownloadIssues() async {
    final issues = List.of(model.dlIssues);
    final failable = model.failedDownloadFiles();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Text('有 ${issues.length} 张没传成',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: issues.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(issues[i].name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(issues[i].reason,
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.white.withValues(alpha: 0.6))),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  onPressed: failable.isEmpty
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _retryFailed(failable);
                        },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    failable.isEmpty
                        ? '其中没有可重试的失败项'
                        : '重试失败的 ${failable.length} 张',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryFailed(List<CameraFile> picks) async {
    _afterDownload(await model.download(picks));
  }

  Future<void> _download() async {
    // 刷新或改筛选后选中集里可能残留已不在列表里的句柄，先剪掉，
    // 避免出现"已选 N 只下载了 M 张"却毫无提示。
    _sel.prune(_filtered.map((f) => f.handle).toSet());
    final picks = _filtered.where((f) => _sel.selected.contains(f.handle)).toList();
    if (picks.isEmpty) return;
    final result = await model.download(picks);
    if (!mounted) return;
    _afterDownload(result);
    _sel.exitSelect();
  }

  /// 下载给定范围内的未下载文件。
  ///
  /// 范围由调用方决定：无筛选时是整个卡，有筛选（类型/目录/未下载）时是筛选结果。
  /// 这是技术方案里承诺过、但一直没实现的"全量增量下载"。
  Future<void> _downloadPending(List<CameraFile> scope) async {
    final picks = scope.where((f) => !model.isDownloaded(f)).toList();
    if (picks.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('下载 ${picks.length} 张未下载的照片？', style: const TextStyle(fontSize: 16)),
        content: const Text(
          '按当前画质设置逐张下载，已下载过的会自动跳过。\n'
          '尚未读取详情的文件会先补读再下载，数量多时需要一些时间。',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始下载')),
        ],
      ),
    );
    if (ok != true) return;
    final result = await model.download(picks);
    if (!mounted) return;
    _afterDownload(result);
  }

  /// 相机端操作：保护 / 取消保护 / 删除卡上原片。
  ///
  /// 原生的 `deleteObject(0x100B)` 与 `protectObject(0x1012)` 早就实现并封装到了
  /// Dart 侧，但此前**没有任何 UI 入口**（审查文档 C1）——相机上"保护"过的照片
  /// 不会被相机自己的删除操作清掉，是现场挑片的刚需。
  Future<void> _cameraOp(String kind) async {
    _sel.prune(_filtered.map((f) => f.handle).toSet());
    final picks = _filtered.where((f) => _sel.selected.contains(f.handle)).toList();
    if (picks.isEmpty) return;

    if (kind == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text('删除相机上的 ${picks.length} 个文件？', style: const TextStyle(fontSize: 16)),
          content: const Text(
            '直接从相机存储卡删除，删除后无法恢复。\n'
            '已下载到手机的副本不受影响；受保护的文件相机会拒绝删除。',
            style: TextStyle(fontSize: 13.5, height: 1.5),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 40), backgroundColor: const Color(0xFFE53935)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final protect = kind != 'delete';
    var done = 0;
    final failed = <String>[];
    for (final f in picks) {
      try {
        if (kind == 'delete') {
          await NikonEngine.deleteObject(f.handle);
        } else {
          await NikonEngine.protectObject(f.handle, protect: protect);
        }
        done++;
      } catch (e) {
        failed.add('${f.name ?? f.handle}（$e）');
      }
    }
    if (!mounted) return;
    _sel.exitSelect();
    if (kind == 'delete') {
      await model.loadFiles(); // 卡上没了，重新枚举
      if (!mounted) return;
      unawaited(model.refreshStorage());
    }
    final label = switch (kind) {
      'delete' => '已删除',
      'unprotect' => '已取消保护',
      _ => '已保护',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed.isEmpty
              ? '$label $done 个文件'
              : '$label $done 个，失败 ${failed.length} 个：${failed.take(3).join('、')}',
        ),
        duration: Duration(seconds: failed.isEmpty ? 2 : 8),
      ),
    );
  }

  /// 状态条：按「进行中的下载 > 新照片 > 索引」的优先级**只显示一条**。
  /// 三块状态条此前各自判断、可以同时出现，最多挤掉网格 100dp 以上。
  Widget _statusBar(int total) {
    if (model.downloading) {
      return DownloadProgressBar(
        done: model.dlDone,
        total: model.dlTotal,
        fileFrac: model.dlFileFrac,
        speedMBps: model.dlSpeed,
        currentName: model.dlCurrentName,
        onCancel: () => model.cancelDownload(),
      );
    }
    if (model.hasNewPhotos) {
      return NewPhotosBanner(onRefresh: () {
        model.consumeNewPhotos();
        model.loadFiles();
      });
    }
    if (!model.indexingDone && model.files.isNotEmpty) {
      return IndexProgressBar(indexed: model.indexedCount, total: total);
    }
    return const SizedBox.shrink();
  }

  /// 待下载任务条：把"还差多少"和"一键传完"放在第一眼位置。
  ///
  /// 有筛选时按钮传的是**筛选范围内**的未下载文件，文案也相应区分，
  /// 避免"显示 231 张、实际只传了 40 张"这种对不上的情况。
  Widget _taskBar(int pendingAll) {
    final filtered = _filterActive;
    final pendingFiltered = _filtered.where((f) => !model.isDownloaded(f)).length;
    final target = filtered ? pendingFiltered : pendingAll;
    if (target == 0) return const SizedBox.shrink();
    return Container(
      color: const Color(0xFF1F1F14),
      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filtered ? '筛选范围内还有 $target 张未下载' : '还有 $pendingAll 张未下载',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: kAccent),
                ),
                const SizedBox(height: 2),
                Text(
                  filtered
                      ? '当前筛选 ${_filtered.length} 张 · 卡内 ${model.files.length}'
                      : '已下载 ${model.files.length - pendingAll} · 卡内 ${model.files.length}'
                          '${model.storageText.isEmpty ? '' : ' · ${model.storageText}'}',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.55)),
                ),
              ],
            ),
          ),
          if (model.downloading)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text('${model.dlDone}/${model.dlTotal}',
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              onPressed: () => _downloadPending(filtered ? _filtered : model.files),
              child: Text(filtered ? '下载 $target 张' : '一键下载'),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 装配

  @override
  Widget build(BuildContext context) {
    final page = AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        if (model.connState != 'connected') {
          return Scaffold(
            appBar: AppBar(title: const Text('照片')),
            body: DisconnectedView(
              message: model.connStateText,
              action: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回重新连接'),
              ),
            ),
          );
        }
        final files = _filtered;
        // 待下载数量：未读到详情的文件按"未下载"计，随索引进度收敛
        final pending = model.files.where((f) => !model.isDownloaded(f)).length;
        return Scaffold(
          appBar: _sel.selectMode ? _selectionAppBar() : _normalAppBar(),
          body: Column(
            children: [
              _taskBar(pending),
              GalleryFilterBar(
                kind: _kind,
                folder: _folder,
                onKind: (v) => _setFilter(kind: v),
                onFolderTap: _showOptions,
                undownloadedOnly: _undownloadedOnly,
                undownloadedCount: pending,
                onToggleUndownloaded: () => _setFilter(undownloaded: !_undownloadedOnly),
                groupByDay: _groupByDay,
                onToggleGroupByDay: () => _setFilter(groupByDay: !_groupByDay),
                pairedOnly: _pairedOnly,
                pairedCount: model.files.where((f) => f.isPaired).length,
                onTogglePaired: () => _setFilter(pairedOnly: !_pairedOnly),
              ),
              // 状态条只显示一条：此前三块各自判断、可同时堆叠，最多挤掉网格 100dp 以上
              _statusBar(files.length),
              Expanded(child: _body(files)),
            ],
          ),
          bottomNavigationBar: _sel.selectMode ? _bottomBar() : null,
        );
      },
    );
    // 返回键**逐层退**：多选态下先退出多选，再按一次才离开相册页。
    // 此前多选态按返回会直接退页（在根页就是退出应用），选了半天全丢。
    return PopScope(
      canPop: !_sel.selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _sel.exitSelect();
      },
      child: page,
    );
  }

  PreferredSizeWidget _normalAppBar() => AppBar(
        title: Text('照片${model.files.isEmpty ? '' : ' ${model.files.length}'}'),
        actions: [
          // 链路状态：点开可分辨"卡住了 / 相机忙 / 链路已断"
          LinkStatusButton(model: model),
          IconButton(
            tooltip: '显示选项',
            icon: const Icon(Icons.tune),
            onPressed: _showOptions,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: model.loadingFiles ? null : () => model.loadFiles(),
          ),
        ],
      );

  PreferredSizeWidget _selectionAppBar() {
    final allSelected = _sel.allSelected(_filtered.map((f) => f.handle));
    // 下载中锁定"改选择"的入口（全选/取消全选），与格子点击、滑动选择保持一致；
    // 「取消」按钮仍可用——万一确实要退出多选态，不该把人困住。
    final locked = model.downloading;
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: _sel.exitSelect),
      title: Text(locked ? '下载中 · 已选 ${_sel.selected.length}' : '已选 ${_sel.selected.length}'),
      actions: [
        TextButton(
          onPressed: locked ? null : () => _sel.toggleAll(_filtered.map((f) => f.handle)),
          child: Text(allSelected ? '取消全选' : '全选',
              style: TextStyle(color: locked ? Colors.white38 : kAccent)),
        ),
      ],
    );
  }

  Widget _body(List<CameraFile> files) {
    if (model.loadingFiles && model.files.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (model.filesError != null && model.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：${model.filesError}',
                style: const TextStyle(fontSize: 13, color: Colors.white54)),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => model.loadFiles(), child: const Text('重试')),
          ],
        ),
      );
    }
    if (files.isEmpty) {
      return EmptyState(
        icon: Icons.photo_library_outlined,
        message: model.files.isEmpty ? '存储卡里没有照片' : '当前筛选条件下没有照片',
      );
    }
    return _selectionHost(_groupByDay ? _groupedGrid(files) : _flatGrid(files));
  }

  static const SliverGridDelegate _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: _cols,
    crossAxisSpacing: _gap,
    mainAxisSpacing: _gap,
    childAspectRatio: _cellAspect,
  );

  /// 滑动选择的手势宿主：两种布局共用同一套指针处理。
  /// 下载进行中忽略滑动（选择集已锁定），否则拖到一半就开始传、选择还在变，很容易误操作。
  Widget _selectionHost(Widget child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (d) {
          if (model.downloading) return;
          _sel.updateDrag(d.position);
        },
        onPointerUp: (_) => _sel.endDrag(),
        onPointerCancel: (_) => _sel.endDrag(),
        child: child,
      );

  Widget _flatGrid(List<CameraFile> files) => GridView.builder(
        key: _gridKey,
        controller: _gridCtrl,
        padding: const EdgeInsets.only(bottom: 96),
        gridDelegate: _gridDelegate,
        itemCount: files.length,
        itemBuilder: (context, i) => _cell(files[i], i, files),
      );

  /// 按天分组视图：点日期头部即整选/取消当天的照片，左侧箭头可折叠该天。
  /// 分组后行高不固定，因此滑动选择改用逐格命中（见 _hitIndex）。
  Widget _groupedGrid(List<CameraFile> files) {
    final sections = _daySections(files);
    return CustomScrollView(
      key: _gridKey,
      controller: _gridCtrl,
      slivers: [
        for (final s in sections) ...[
          SliverToBoxAdapter(child: _dayHeader(s)),
          // 折叠后不渲染这一天的网格：既省构建，也让用户能直接看到下一天
          if (!_collapsedDays.contains(s.day))
            SliverGrid(
              gridDelegate: _gridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) => _cell(s.files[i], s.base + i, files),
                childCount: s.files.length,
              ),
            ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }

  /// 日期头：左侧箭头 = 折叠/展开，其余区域 = 整选当天。
  ///
  /// 两个动作必须分开：合在一个手势里的话，想折叠却整选了当天（或反之），
  /// 而"整选当天"在几百张的卡上并不好撤销。
  Widget _dayHeader(({String day, int base, List<CameraFile> files}) s) {
    final handles = s.files.map((f) => f.handle).toList();
    final allSel = _sel.allSelected(handles);
    final selCount = handles.where(_sel.selected.contains).length;
    final collapsed = _collapsedDays.contains(s.day);
    // 下载进行中不允许改选择集（见 _cell 的说明）
    final locked = model.downloading;
    return Row(
      children: [
        IconButton(
          icon: AnimatedRotation(
            turns: collapsed ? -0.25 : 0,
            duration: const Duration(milliseconds: 140),
            child: const Icon(Icons.expand_more, size: 22),
          ),
          tooltip: collapsed ? '展开 ${s.day}' : '折叠 ${s.day}',
          visualDensity: VisualDensity.compact,
          color: Colors.white70,
          onPressed: () => setState(() {
            if (!_collapsedDays.remove(s.day)) _collapsedDays.add(s.day);
          }),
        ),
        Expanded(
          child: Semantics(
            button: true,
            label: '${s.day}，${s.files.length} 张，点击${allSel ? '取消选择' : '全选'}当天',
            child: InkWell(
              onTap: locked ? null : () => _sel.toggleGroup(handles),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 14, 6),
                child: Row(
                  children: [
                    Text(s.day,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text(collapsed ? '${s.files.length} 张 · 已折叠' : '${s.files.length} 张',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.white.withValues(alpha: 0.45))),
                    if (selCount > 0) ...[
                      const SizedBox(width: 8),
                      Text('已选 $selCount',
                          style: const TextStyle(fontSize: 11.5, color: kAccent)),
                    ],
                    const Spacer(),
                    Icon(allSel ? Icons.check_circle : Icons.add_circle_outline,
                        size: 18, color: allSel ? kAccent : Colors.white24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _cell(CameraFile f, int index, List<CameraFile> files) {
    if (model.gateway.needsLoad(f, withThumb: true)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) model.gateway.ensureLoaded(f, withThumb: true);
      });
    }
    // 下载进行中：**锁定选择集**，但保留看大图。
    // 理由：下载清单是按下按钮那一刻的快照，此刻改选择并不会改变正在传的内容，
    // 却会让用户以为"我把这张取消了"——之前点一下图片就取消选中，正是这个误导。
    // 而"想看看到底传的是哪张"是非常自然的需求，所以点击语义改成开查看器。
    final locked = model.downloading;
    return GalleryCell(
      key: _keyOf(f.handle),
      file: f,
      thumb: f.hasThumb ? model.gateway.memThumb(f.handle) : null,
      selected: _sel.selected.contains(f.handle),
      downloaded: model.isDownloaded(f),
      pairDownloaded: model.isPairDownloaded(f),
      // 点缩略图**始终**是看大图：挑选时总得放大确认才敢下手，图多时尤其如此。
      // 勾选交给右下角的圈——选择模式下它常驻可见（非选择模式点它进入选择模式）。
      onTap: () => _openViewer(index, files),
      onLongPress: locked
          ? null
          : () {
              HapticFeedback.mediumImpact();
              _sel.beginDrag(index);
            },
      onToggleSelect: locked ? null : () => _sel.enterSelectAndToggle(f.handle),
      inSelectMode: _sel.selectMode,
    );
  }

  Widget _bottomBar() {
    final count = _sel.selected.length;
    final variantLabel = switch (model.downloadVariant) {
      '2M' => '2M',
      '8M' => '8M',
      _ => '原图',
    };
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: const Color(0xFF0F0F0F),
        child: model.downloading
            ? SizedBox(
                height: 46,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${model.dlDone}/${model.dlTotal}'
                      '${model.dlSpeed > 0 ? ' · ${model.dlSpeed.toStringAsFixed(1)}MB/s' : ''}',
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                    // 说清"为什么点了没反应"：此刻改选择不会影响已经在传的清单，
                    // 所以选择被锁定，但看大图仍然可用
                    const Text(
                      '下载中，选择已锁定（仍可点开大图）',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ),
              )
            : Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: count == 0 ? null : _download,
                        child: Text('下载 ($count)'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  PopupMenuButton<String>(
                    tooltip: '下载画质',
                    onSelected: model.setDownloadVariant,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'original', child: Text('原图', style: TextStyle(fontSize: 14))),
                      PopupMenuItem(value: '8M', child: Text('8M (长边3840)', style: TextStyle(fontSize: 14))),
                      PopupMenuItem(value: '2M', child: Text('2M (长边1920)', style: TextStyle(fontSize: 14))),
                    ],
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white38),
                        borderRadius: BorderRadius.circular(23),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(variantLabel,
                              style: const TextStyle(fontSize: 13.5, color: Colors.white)),
                          const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
                        ],
                      ),
                    ),
                  ),
                  // 相机端操作：保护/取消保护（无损）+ 删除卡上原片（不可恢复）
                  PopupMenuButton<String>(
                    tooltip: '相机端操作',
                    onSelected: _cameraOp,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'protect', child: Text('保护（相机上标记为不可删）', style: TextStyle(fontSize: 14))),
                      PopupMenuItem(value: 'unprotect', child: Text('取消保护', style: TextStyle(fontSize: 14))),
                      PopupMenuItem(value: 'delete', child: Text('删除相机上的原片', style: TextStyle(fontSize: 14))),
                    ],
                    icon: const Icon(Icons.more_vert, color: Colors.white70),
                  ),
                ],
              ),
      ),
    );
  }
}
