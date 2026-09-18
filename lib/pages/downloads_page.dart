import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../engine/record_store.dart';
import 'local_viewer_page.dart';
import 'widgets/app_widgets.dart';
import 'widgets/drag_selection.dart';

/// 手机页：已下载照片管理。按日期分组展示，滑动范围多选，批量删除。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.model});

  final AppModel model;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  static const yellow = kAccent;
  static const int _cols = 3;
  static const double _gap = 2;

  /// 与相机相册页保持一致：相机出片是 3:2，正方形会切坏构图
  static const double _cellAspect = 3 / 2;

  final ScrollController _scrollCtrl = ScrollController();
  final Map<String, GlobalKey> _cellKeys = {};
  final Map<String, Uint8List?> _thumbs = {};
  bool _deleting = false;
  List<RecEntry>? _entriesCache;

  /// 滑动多选状态机（列表版：用命中测试把屏幕坐标换算成索引）
  late final DragSelection<String> _sel = DragSelection<String>(
    keyAt: (i) => _entries[i].key,
    itemCount: () => _entries.length,
    indexAt: _hitIndex,
    scrollController: _scrollCtrl,
    viewportBox: () => context.findRenderObject() as RenderBox?,
    onChanged: () => setState(() {}),
  );

  AppModel get model => widget.model;

  /// 记录列表。records.all 每次调用都会重新排序，而拖动选择会高频读取它
  /// （命中测试逐格查询、范围选中逐项换算），因此按通知缓存一份。
  List<RecEntry> get _entries => _entriesCache ??= model.gateway.records.all;

  @override
  void initState() {
    super.initState();
    model.addListener(_onModelChanged);
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
      _entriesCache = null;
      // 顺带回收已消失条目的 GlobalKey 与缩略图：两者都只增不减，
      // 删除记录后旧对象仍被 map 持有（虽未挂载，白白占着内存）。
      // 用 _entries 复用刚失效的缓存，不再多排一次序。
      final alive = _entries.map((e) => e.key).toSet();
      _cellKeys.removeWhere((k, _) => !alive.contains(k));
      _thumbs.removeWhere((k, _) => !alive.contains(k));
    }
    if (_sel.selected.isEmpty) return;
    _sel.prune(_entries.map((e) => e.key).toSet());
  }

  int _recordsRevision = -1;

  /// 按日期分组（时间倒序天然成组）
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
    // 旧版本下载的记录没有 uri：按文件名从 MediaStore 找回
    var uri = e.uri;
    if (uri == null) {
      uri = await NikonEngine.findMediaByName(e.name);
      if (uri != null) model.gateway.records.updateUri(key, uri);
    }
    if (uri == null) return;
    final t = await NikonEngine.mediaThumb(uri);
    if (mounted) setState(() => _thumbs[key] = t);
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
        final sections = _sections;
        final entries = _entries;
        // 每段在展平列表中的起始下标：滑动选择的命中测试返回展平索引，
        // 单元格需要知道自己在整表里的位置才能确定锚点
        final sectionBase = <int>[];
        var acc = 0;
        for (final s in sections) {
          sectionBase.add(acc);
          acc += s.value.length;
        }
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
                  onPressed: () => _sel.toggleAll(entries.map((e) => e.key)),
                  child: Text(
                    _sel.allSelected(entries.map((e) => e.key)) ? '取消全选' : '全选',
                    style: const TextStyle(color: yellow),
                  ),
                ),
            ],
          ),
          body: _deleting
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : entries.isEmpty
                  ? const EmptyState(
                      icon: Icons.photo_library_outlined,
                      message: '还没有从相机下载的照片',
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
                            SliverToBoxAdapter(
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                                child: Text(
                                  section.key,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            SliverGrid(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: _cols,
                                crossAxisSpacing: _gap,
                                mainAxisSpacing: _gap,
                                childAspectRatio: _cellAspect,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, i) => _cell(section.value[i], sectionBase[si] + i),
                                childCount: section.value.length,
                              ),
                            ),
                          ],
                          const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
                        ],
                      ),
                    ),
          bottomNavigationBar: _sel.selectMode ? _bottomBar() : null,
        );
      },
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
        if (_sel.selectMode) {
          _sel.toggle(e.key);
          return;
        }
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
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                _sel.enterSelectAndToggle(e.key);
              },
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 22, height: 22),
              ),
            ),
          ),
          if (isSel)
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
