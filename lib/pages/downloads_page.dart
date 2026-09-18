import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/app_log.dart';
import '../engine/nikon_engine.dart';
import '../engine/record_store.dart';
import 'local_viewer_page.dart';
import 'widgets/app_widgets.dart';
import 'widgets/drag_selection.dart';
import 'widgets/gallery_filter_bar.dart';
import 'widgets/gallery_options_sheet.dart';

/// 手机页：已下载照片管理。**与相机相册页同一套浏览能力**——
/// 类型 / 文件夹筛选、按天分组（可折叠）、四种排序、滑动范围多选、批量删除。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.model, this.onSelectionChanged});

  final AppModel model;

  /// 选择模式变化时上报。
  ///
  /// 存在的理由：返回键的处理在外层（`HomeShell`），而选择状态在本页——
  /// 不告诉外层的话，外层就不知道该"先取消选中"还是"直接退回相机页"。
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<DownloadsPage> createState() => DownloadsPageState();
}

/// 公开 State 类型：外层（`HomeShell`）要用 `GlobalKey` 直接问"现在是否在多选"、
/// 并在返回键按下时先退出多选。公开的理由和 `ScaffoldState`/`NavigatorState` 一样——
/// 它是这个页面**对外可查询的状态**，不是内部实现细节。
class DownloadsPageState extends State<DownloadsPage> {
  static const yellow = kAccent;
  static const int _cols = 3;
  static const double _gap = 2;

  /// 与相机相册页保持一致：相机出片是 3:2，正方形会切坏构图
  static const double _cellAspect = 3 / 2;

  final ScrollController _scrollCtrl = ScrollController();
  final Map<String, GlobalKey> _cellKeys = {};
  final Map<String, Uint8List?> _thumbs = {};
  bool _deleting = false;

  // ---- 浏览筛选（与相册页同名同语义，便于对照与复用组件）----
  String _kind = 'all'; // all / jpeg / raw / video
  String _folder = '全部';

  /// 是否处于多选态（供外层判断返回键该先做什么）
  bool get hasSelection => _sel.selectMode;

  /// 退出多选（返回键第一层）
  void exitSelection() => _sel.exitSelect();

  /// 按天分组。本机页默认**开**（下载历史按天看最自然，且这是它原有行为）；
  /// 相册页默认关（那边更常按最新顺序翻）。
  bool _groupByDay = true;

  /// 只看 RAW+JPEG 成对（本机侧按文件名推导，见 _computePairs）
  bool _pairedOnly = false;

  /// 已折叠的日期分组（键 = 日期标题）。
  final Set<String> _collapsedDays = {};

  List<RecEntry>? _rawCache;
  List<RecEntry>? _entriesCache;

  /// 滑动多选状态机（列表版：用命中测试把屏幕坐标换算成索引）
  late final DragSelection<String> _sel = DragSelection<String>(
    keyAt: (i) => _entries[i].key,
    itemCount: () => _entries.length,
    indexAt: _hitIndex,
    scrollController: _scrollCtrl,
    viewportBox: () => context.findRenderObject() as RenderBox?,
    // 所有入口（点角标、长按滑动、全选、按天整选）最终都走这里，
    // 因此选择模式的上报只在这一处，不会漏
    onChanged: () => setState(() => widget.onSelectionChanged?.call(_sel.selectMode)),
  );

  AppModel get model => widget.model;

  /// 原始记录（未筛选）。records.all 每次调用都会重新排序，而拖动选择会高频读取它
  /// （命中测试逐格查询、范围选中逐项换算），因此按内容版本号缓存一份。
  List<RecEntry> get _raw => _rawCache ??= model.gateway.records.all;

  /// 筛选 + 排序后的列表。与相册页同一套语义（类型 / 文件夹 / 排序）。
  List<RecEntry> get _entries => _entriesCache ??= _computeFiltered();

  /// 是否处于筛选状态（决定删除提示的范围文案）
  bool get _filterActive => _kind != 'all' || _folder != '全部';

  /// 本地文件的格式分类，与相册页的 kind 取值保持一致（jpeg / raw / video）。
  ///
  /// 本机记录里没有 kind 字段（只有文件名），所以按扩展名反推——
  /// 这样两个页面的筛选条可以共用同一个组件与同一个取值。
  static String _kindOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.mov') || n.endsWith('.mp4') || n.endsWith('.avi')) return 'video';
    if (n.endsWith('.nef') || n.endsWith('.nrw') || n.endsWith('.dng') || n.endsWith('.cr2')) {
      return 'raw';
    }
    return 'jpeg';
  }

  /// 本地文件夹：取决于下载时保存的位置（系统相册 Pictures/NikonSync，或用户自选目录）。
  static String _folderOf(RecEntry e) {
    final p = e.path ?? '';
    final i = p.lastIndexOf('/');
    return i <= 0 ? '未知位置' : p.substring(0, i);
  }

  /// 可选的文件夹列表（供选项弹窗使用）
  List<String> get _folders {
    final set = <String>{for (final e in _raw) _folderOf(e)};
    return set.toList()..sort();
  }

  List<RecEntry> _computeFiltered() {
    var list = List<RecEntry>.of(_raw);
    if (_kind != 'all') list = list.where((e) => _kindOf(e.name) == _kind).toList();
    if (_folder != '全部') list = list.where((e) => _folderOf(e) == _folder).toList();
    if (_pairedOnly) list = list.where((e) => _pairedKeys.contains(e.key)).toList();
    // 排序沿用全局设置（与相册页同一个 sortMode），避免两个页面对"排序"的理解分叉
    int cmp(RecEntry a, RecEntry b) => switch (model.sortMode) {
          'oldest' => a.time.compareTo(b.time),
          'nameAsc' => a.name.compareTo(b.name),
          'nameDesc' => b.name.compareTo(a.name),
          _ => b.time.compareTo(a.time),
        };
    return list..sort(cmp);
  }

  /// 改筛选条件：丢缓存并把选择集收敛到新列表上（否则"已选 N"会包含看不见的条目）
  void _setFilter({String? kind, String? folder, bool? groupByDay, bool? pairedOnly}) {
    setState(() {
      if (kind != null) _kind = kind;
      if (folder != null) _folder = folder;
      if (groupByDay != null) _groupByDay = groupByDay;
      if (pairedOnly != null) _pairedOnly = pairedOnly;
      _entriesCache = null;
    });
    if (_sel.selected.isEmpty) return;
    _sel.prune(_entries.map((e) => e.key).toSet());
  }

  Future<void> _showOptions() => showGalleryOptionsSheet(
        context: context,
        folders: _folders,
        kind: _kind,
        folder: _folder,
        sortMode: model.sortMode,
        // 本机页没有"下载画质"的概念，传 null 即隐藏该段
        onKind: (v) => _setFilter(kind: v),
        onFolder: (v) => _setFilter(folder: v),
        onSort: model.setSortMode,
      );

  @override
  void initState() {
    super.initState();
    model.addListener(_onModelChanged);
    // 首屏就可能要显示成对标记，先算一遍（后续在记录变化时重算）
    _computePairs();
    // 旧记录补全保存位置（一次性，见 _backfillPaths 的说明）
    WidgetsBinding.instance.addPostFrameCallback((_) => _backfillPaths());
  }

  bool _backfillDone = false;

  /// 给旧记录补全保存位置。
  ///
  /// 早期版本的下载记录只存了文件名，没存路径，于是本机页把它们统统归到"未知位置"。
  /// 这里按文件名向媒体库查一次相对路径并写回记录——**只查缺路径的那些**，
  /// 且只做一次，避免每次进页面都扫一遍媒体库。
  Future<void> _backfillPaths() async {
    if (_backfillDone) return;
    _backfillDone = true;
    final missing = _raw.where((e) => (e.path ?? '').isEmpty).take(200).toList();
    if (missing.isEmpty) return;
    var fixed = 0;
    for (final e in missing) {
      try {
        final p = await NikonEngine.mediaRelativePath(e.name);
        if (p != null && p.isNotEmpty) {
          model.gateway.records.updatePath(e.key, p);
          fixed++;
        }
      } catch (_) {}
    }
    if (fixed > 0) AppLog.add('补全了 $fixed 条旧记录的保存位置');
  }

  @override
  void dispose() {
    model.removeListener(_onModelChanged);
    _sel.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    // 只有记录**内容**变了才重算：`records.all` 每次调用都会重新排序，
    // 而模型通知是 150ms 节流的——索引/下载期间等于每 150ms 排一次全部记录。
    final rev = model.gateway.records.revision;
    if (rev != _recordsRevision) {
      _recordsRevision = rev;
      _rawCache = null;
      _entriesCache = null;
      _computePairs(); // 成对关系随记录集合变化，必须先于筛选重算
      // 顺带回收已消失条目的 GlobalKey 与缩略图：两者都只增不减，
      // 删除记录后旧对象仍被 map 持有（虽未挂载，白白占着内存）。
      final alive = _raw.map((e) => e.key).toSet();
      _cellKeys.removeWhere((k, _) => !alive.contains(k));
      _thumbs.removeWhere((k, _) => !alive.contains(k));
    }
    if (_sel.selected.isEmpty) return;
    _sel.prune(_entries.map((e) => e.key).toSet());
  }

  int _recordsRevision = -1;

  /// 按日期分组。列表已排序，但按文件名排序时同一天的条目可能被拆开
  /// （与相册页同样如实呈现，不做二次归并）。
  List<MapEntry<String, List<RecEntry>>> get _sections {
    final out = <MapEntry<String, List<RecEntry>>>[];
    for (final e in _entries) {
      final day = '${e.time.month}月${e.time.day}日';
      if (out.isEmpty || out.last.key != day) out.add(MapEntry(day, []));
      out.last.value.add(e);
    }
    return out;
  }

  GlobalKey _keyOf(RecEntry e) => _cellKeys.putIfAbsent(e.key, GlobalKey.new);

  /// 命中测试：全局坐标 → 展平后的记录索引
  int? _hitIndex(Offset global) {
    final entries = _entries;
    for (var i = 0; i < entries.length; i++) {
      final ctx = _cellKeys[entries[i].key]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return i;
    }
    return null;
  }

  Future<void> _loadThumb(RecEntry e) async {
    final key = e.key;
    if (_thumbs.containsKey(key)) return;
    _thumbs[key] = null;
    // 先查缓存（内存 + 磁盘，跨启动有效）：此前每次进本机页都要重新向 MediaStore
    // 取缩略图，几百张时进页面明显发白，退出再进又重来一遍
    final cached = await model.gateway.localThumbCache.get(key);
    if (cached != null) {
      if (mounted) setState(() => _thumbs[key] = cached);
      return;
    }
    // 旧版本下载的记录没有 uri：按文件名从 MediaStore 找回
    var uri = e.uri;
    if (uri == null) {
      uri = await NikonEngine.findMediaByName(e.name);
      if (uri != null) model.gateway.records.updateUri(key, uri);
    }
    if (uri == null) return;
    final t = await NikonEngine.mediaThumb(uri);
    if (t != null && t.isNotEmpty) model.gateway.localThumbCache.put(key, t);
    if (mounted) setState(() => _thumbs[key] = t);
  }

  /// 本机成对关系：同名词干、且一个 RAW 一个 JPEG（相机"同时记录"的产物）。
  ///
  /// 相机页有成对标记，本机页此前没有——于是"RAW 收了、JPEG 没收"这种情况在手机上
  /// 根本看不出来，而这正是成对照片最需要看见的信息。
  final Set<String> _pairedKeys = {};

  static String _stemOf(String name) {
    final dot = name.lastIndexOf('.');
    return (dot <= 0 ? name : name.substring(0, dot)).toUpperCase();
  }

  void _computePairs() {
    _pairedKeys.clear();
    final byStem = <String, List<RecEntry>>{};
    for (final e in _raw) {
      (byStem[_stemOf(e.name)] ??= []).add(e);
    }
    for (final list in byStem.values) {
      final hasRaw = list.any((e) => _kindOf(e.name) == 'raw');
      final hasJpeg = list.any((e) => _kindOf(e.name) == 'jpeg');
      if (hasRaw && hasJpeg) {
        for (final e in list) {
          _pairedKeys.add(e.key);
        }
      }
    }
  }

  Future<void> _deleteSelected() async {
    final picks = _entries.where((e) => _sel.selected.contains(e.key)).toList();
    if (picks.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('删除 ${picks.length} 张照片？', style: const TextStyle(fontSize: 16)),
        content: const Text('将从手机中删除这些文件，删除后无法恢复。', style: TextStyle(fontSize: 13.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    var done = 0;
    for (final e in picks) {
      if (e.uri != null) await NikonEngine.mediaDelete(e.uri!);
      model.gateway.records.removeKey(e.key);
      done++;
    }
    // 删除是逐个 await 的，期间用户可能已返回上一页
    if (!mounted) return;
    setState(() => _deleting = false);
    _sel.exitSelect();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已删除 $done 张照片')));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final entries = _entries;
        // "按天分组"关闭时用同一个空标题段承载全部条目，这样下面的 sliver 逻辑
        // 与分组时完全一致（只有一个代码路径，不会出现两套分叉）
        final sections = _groupByDay
            ? _sections
            : <MapEntry<String, List<RecEntry>>>[MapEntry('', entries)];
        // 每段在展平列表中的起始下标：滑动选择的命中测试返回展平索引，
        // 单元格需要知道自己在整表里的位置才能确定锚点
        final sectionBase = <int>[];
        var acc = 0;
        for (final s in sections) {
          sectionBase.add(acc);
          acc += s.value.length;
        }
        final allKeys = entries.map((e) => e.key);
        return Scaffold(
          backgroundColor: const Color(0xFF0A0A0A),
          appBar: AppBar(
            title: _sel.selectMode ? Text('已选 ${_sel.selected.length}') : const Text('手机'),
            leading: _sel.selectMode
                ? IconButton(icon: const Icon(Icons.close), onPressed: _sel.exitSelect)
                : null,
            actions: [
              if (_sel.selectMode)
                TextButton(
                  onPressed: () => _sel.toggleAll(allKeys),
                  child: Text(
                    _sel.allSelected(allKeys) ? '取消全选' : '全选',
                    style: const TextStyle(color: yellow),
                  ),
                )
              else ...[
                IconButton(
                  tooltip: '选项（类型 / 文件夹 / 排序）',
                  icon: const Icon(Icons.tune),
                  onPressed: _showOptions,
                ),
              ],
            ],
          ),
          body: Column(
            children: [
              // 与相册页同一条筛选条：类型 chips + 按天分组 + 文件夹
              GalleryFilterBar(
                kind: _kind,
                folder: _folder,
                onKind: (v) => _setFilter(kind: v),
                onFolderTap: _showOptions,
                undownloadedOnly: false,
                undownloadedCount: 0,
                onToggleUndownloaded: () {},
                groupByDay: _groupByDay,
                onToggleGroupByDay: () => _setFilter(groupByDay: !_groupByDay),
                pairedOnly: _pairedOnly,
                pairedCount: _pairedKeys.length,
                onTogglePaired: () => _setFilter(pairedOnly: !_pairedOnly),
                showUndownloaded: false, // 本机页没有"未下载"的概念
              ),
              Expanded(
                child: _deleting
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : entries.isEmpty
                        ? EmptyState(
                            icon: Icons.photo_library_outlined,
                            message: _filterActive
                                ? '当前筛选条件下没有照片'
                                : '还没有从相机下载的照片',
                          )
                        : Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerMove: (d) => _sel.updateDrag(d.position),
                            onPointerUp: (_) => _sel.endDrag(),
                            onPointerCancel: (_) => _sel.endDrag(),
                            child: CustomScrollView(
                              controller: _scrollCtrl,
                              slivers: [
                                for (final (si, section) in sections.indexed) ...[
                                  if (section.key.isNotEmpty)
                                    SliverToBoxAdapter(child: _dayHeader(section)),
                                  if (section.key.isEmpty ||
                                      !_collapsedDays.contains(section.key))
                                    SliverGrid(
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: _cols,
                                        crossAxisSpacing: _gap,
                                        mainAxisSpacing: _gap,
                                        childAspectRatio: _cellAspect,
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, i) =>
                                            _cell(section.value[i], sectionBase[si] + i),
                                        childCount: section.value.length,
                                      ),
                                    ),
                                ],
                                const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
                              ],
                            ),
                          ),
              ),
            ],
          ),
          bottomNavigationBar: _sel.selectMode ? _bottomBar() : null,
        );
      },
    );
  }

  /// 日期头：左侧箭头折叠/展开，其余区域整选当天（与相册页同一套交互）。
  /// 两个动作必须分开，否则想折叠却整选了当天——几百张时不好撤销。
  Widget _dayHeader(MapEntry<String, List<RecEntry>> s) {
    final keys = s.value.map((e) => e.key).toList();
    final allSel = _sel.allSelected(keys);
    final selCount = keys.where(_sel.selected.contains).length;
    final collapsed = _collapsedDays.contains(s.key);
    return Row(
      children: [
        IconButton(
          icon: AnimatedRotation(
            turns: collapsed ? -0.25 : 0,
            duration: const Duration(milliseconds: 140),
            child: const Icon(Icons.expand_more, size: 22),
          ),
          tooltip: collapsed ? '展开 ${s.key}' : '折叠 ${s.key}',
          visualDensity: VisualDensity.compact,
          color: Colors.white70,
          onPressed: () => setState(() {
            if (!_collapsedDays.remove(s.key)) _collapsedDays.add(s.key);
          }),
        ),
        Expanded(
          child: Semantics(
            button: true,
            label: '${s.key}，${s.value.length} 张，点击${allSel ? '取消选择' : '全选'}当天',
            child: InkWell(
              onTap: () => _sel.toggleGroup(keys),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 14, 16, 8),
                child: Row(
                  children: [
                    Text(s.key,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text(collapsed ? '${s.value.length} 张 · 已折叠' : '${s.value.length} 张',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.white.withValues(alpha: 0.45))),
                    if (selCount > 0) ...[
                      const SizedBox(width: 8),
                      Text('已选 $selCount',
                          style: const TextStyle(fontSize: 11.5, color: yellow)),
                    ],
                    const Spacer(),
                    Icon(allSel ? Icons.check_circle : Icons.add_circle_outline,
                        size: 18, color: allSel ? yellow : Colors.white24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _cell(RecEntry e, int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadThumb(e));
    final bytes = _thumbs[e.key];
    final isSel = _sel.selected.contains(e.key);
    return GestureDetector(
      key: _keyOf(e),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 与相册页一致：点缩略图**始终**是"打开"（图片进本地查看器、视频交给系统播放器），
        // 选择模式下也一样——挑选时得看清才敢下手。勾选由右下角的圈负责。
        if (e.uri == null) return;
        final lower = e.name.toLowerCase();
        if (lower.endsWith('.mov') || lower.endsWith('.mp4') || lower.endsWith('.avi')) {
          NikonEngine.openMedia(e.uri!);
        } else {
          final idx = _entries.indexOf(e);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LocalViewerPage(model: model, entries: _entries, initialIndex: idx),
            ),
          );
        }
      },
      onLongPressStart: (_) {
        HapticFeedback.mediumImpact();
        _sel.beginDrag(index);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFF161616),
            alignment: Alignment.center,
            child: bytes == null
                ? const Icon(Icons.image_outlined, size: 28, color: Colors.white24)
                : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          if (e.variant != 'original')
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
                child: Text(
                  e.variant,
                  style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          if (_pairedKeys.contains(e.key))
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration:
                    BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
                child: const Text('R+J',
                    style: TextStyle(
                        fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                _sel.enterSelectAndToggle(e.key);
              },
              child: Padding(
                padding: EdgeInsets.all(_sel.selectMode ? 2 : 8),
                child: SizedBox(
                  width: _sel.selectMode ? 34 : 22,
                  height: _sel.selectMode ? 34 : 22,
                  // 选择模式下常驻可见：此时点缩略图是"打开"，勾选得有看得见的落点
                  child: _sel.selectMode
                      ? Center(
                          child: Icon(
                            isSel ? Icons.check_circle : Icons.circle_outlined,
                            size: 22,
                            color: isSel ? yellow : Colors.white,
                            shadows: const [Shadow(color: Colors.black87, blurRadius: 5)],
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          if (isSel && !_sel.selectMode)
            const Positioned(
              right: 8,
              bottom: 8,
              child: IgnorePointer(child: Icon(Icons.check_circle, size: 22, color: yellow)),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final count = _sel.selected.length;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: const Color(0xFF0F0F0F),
        child: SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            onPressed: count == 0 ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text('删除 ($count)'),
          ),
        ),
      ),
    );
  }
}
