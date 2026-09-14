import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../models/camera_file.dart';
import 'viewer_page.dart';
import 'widgets/app_widgets.dart';
import 'widgets/drag_selection.dart';
import 'widgets/gallery_cell.dart';
import 'widgets/gallery_filter_bar.dart';
import 'widgets/gallery_options_sheet.dart';
import 'widgets/gallery_status_bars.dart';

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
  final GlobalKey _gridKey = GlobalKey();
  final ScrollController _gridCtrl = ScrollController();
  List<CameraFile>? _filteredCache;

  /// 滑动多选状态机（长按起选、滑动范围、边缘自动滚动）
  late final DragSelection<int> _sel = DragSelection<int>(
    keyAt: (i) => _filtered[i].handle,
    itemCount: () => _filtered.length,
    indexAt: _indexAt,
    scrollController: _gridCtrl,
    viewportBox: () => _gridKey.currentContext?.findRenderObject() as RenderBox?,
    onChanged: () => setState(() {}),
  );

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

  /// 模型变化时丢弃筛选缓存，并剔除已不在列表里的选择
  void _onModelChanged() {
    _filteredCache = null;
    if (_sel.selected.isEmpty) return;
    _sel.prune(model.files.map((f) => f.handle).toSet());
  }

  // ------------------------------------------------------------ 筛选与排序

  /// 当前筛选+排序后的列表。
  /// 必须返回新列表：此前默认筛选下直接对 `model.files` 本体排序，
  /// 等于在渲染期改写全局状态，并把正在被 ViewerPage 持有的引用一起重排。
  List<CameraFile> get _filtered => _filteredCache ??= _computeFiltered();

  List<CameraFile> _computeFiltered() {
    var list = List<CameraFile>.of(model.files);
    if (_undownloadedOnly) list = list.where((f) => !model.isDownloaded(f)).toList();
    if (_kind != 'all') list = list.where((f) => f.kind == _kind).toList();
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
  void _setFilter({String? kind, String? folder, bool? undownloaded}) => setState(() {
        if (kind != null) _kind = kind;
        if (folder != null) _folder = folder;
        if (undownloaded != null) _undownloadedOnly = undownloaded;
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
        builder: (_) =>
            ViewerPage(model: model, files: List<CameraFile>.of(files), initialIndex: index),
      ),
    );
  }

  Future<void> _download() async {
    // 刷新或改筛选后选中集里可能残留已不在列表里的句柄，先剪掉，
    // 避免出现"已选 N 只下载了 M 张"却毫无提示。
    _sel.prune(_filtered.map((f) => f.handle).toSet());
    final picks = _filtered.where((f) => _sel.selected.contains(f.handle)).toList();
    if (picks.isEmpty) return;
    final result = await model.download(picks);
    if (!mounted) return;
    if (result.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
    _sel.exitSelect();
  }

  /// 一键下载全部未下载。
  ///
  /// 这是技术方案里承诺过、但一直没实现的"全量增量下载"的入口——
  /// 去重（records.contains）与批量下载队列早就具备，缺的只是入口。
  Future<void> _downloadAllPending(int pending) async {
    final picks = model.files.where((f) => !model.isDownloaded(f)).toList();
    if (picks.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('下载 $pending 张未下载的照片？', style: const TextStyle(fontSize: 16)),
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
    if (result.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
  }

  /// 待下载任务条：把"还差多少"和"一键传完"放在第一眼位置。
  Widget _taskBar(int pending, int downloaded) {
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
                  '还有 $pending 张未下载',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: kAccent),
                ),
                const SizedBox(height: 2),
                Text(
                  '已下载 $downloaded · 卡内 ${model.files.length}',
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
              onPressed: () => _downloadAllPending(pending),
              child: const Text('一键下载'),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 装配

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        if (model.connState != 'connected') {
          return Scaffold(
            appBar: AppBar(title: const Text('照片')),
            body: DisconnectedView(
              message: '连接已断开',
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
        final downloaded = model.files.length - pending;
        return Scaffold(
          appBar: _sel.selectMode ? _selectionAppBar() : _normalAppBar(),
          body: Column(
            children: [
              if (model.files.isNotEmpty && pending > 0) _taskBar(pending, downloaded),
              GalleryFilterBar(
                kind: _kind,
                folder: _folder,
                onKind: (v) => _setFilter(kind: v),
                onFolderTap: _showOptions,
                undownloadedOnly: _undownloadedOnly,
                undownloadedCount: pending,
                onToggleUndownloaded: () => _setFilter(undownloaded: !_undownloadedOnly),
              ),
              if (model.hasNewPhotos)
                NewPhotosBanner(onRefresh: () {
                  model.consumeNewPhotos();
                  model.loadFiles();
                }),
              if (!model.indexingDone && model.files.isNotEmpty)
                IndexProgressBar(indexed: model.indexedCount, total: model.files.length),
              if (model.downloading)
                DownloadProgressBar(
                  done: model.dlDone,
                  total: model.dlTotal,
                  fileFrac: model.dlFileFrac,
                  speedMBps: model.dlSpeed,
                  currentName: model.dlCurrentName,
                  onCancel: () => model.cancelRequested = true,
                ),
              Expanded(child: _body(files)),
            ],
          ),
          bottomNavigationBar: _sel.selectMode ? _bottomBar() : null,
        );
      },
    );
  }

  PreferredSizeWidget _normalAppBar() => AppBar(
        title: Text('照片${model.files.isEmpty ? '' : ' ${model.files.length}'}'),
        actions: [
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
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: _sel.exitSelect),
      title: Text('已选 ${_sel.selected.length}'),
      actions: [
        TextButton(
          onPressed: () => _sel.toggleAll(_filtered.map((f) => f.handle)),
          child: Text(allSelected ? '取消全选' : '全选', style: const TextStyle(color: kAccent)),
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
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (d) => _sel.updateDrag(d.position),
      onPointerUp: (_) => _sel.endDrag(),
      onPointerCancel: (_) => _sel.endDrag(),
      child: GridView.builder(
        key: _gridKey,
        controller: _gridCtrl,
        padding: const EdgeInsets.only(bottom: 96),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _cols,
          crossAxisSpacing: _gap,
          mainAxisSpacing: _gap,
          childAspectRatio: _cellAspect,
        ),
        itemCount: files.length,
        itemBuilder: (context, i) => _cell(files[i], i, files),
      ),
    );
  }

  Widget _cell(CameraFile f, int index, List<CameraFile> files) {
    if (model.gateway.needsLoad(f, withThumb: true)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) model.gateway.ensureLoaded(f, withThumb: true);
      });
    }
    return GalleryCell(
      file: f,
      thumb: f.hasThumb ? model.gateway.memThumb(f.handle) : null,
      selected: _sel.selected.contains(f.handle),
      downloaded: model.isDownloaded(f),
      onTap: () => _sel.selectMode ? _sel.toggle(f.handle) : _openViewer(index, files),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _sel.beginDrag(index);
      },
      onToggleSelect: () => _sel.enterSelectAndToggle(f.handle),
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
                height: 32,
                child: Center(
                  child: Text(
                    '${model.dlDone}/${model.dlTotal}'
                    '${model.dlSpeed > 0 ? ' · ${model.dlSpeed.toStringAsFixed(1)}MB/s' : ''}',
                    style: const TextStyle(fontSize: 13, color: Colors.white54),
                  ),
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
                ],
              ),
      ),
    );
  }
}
