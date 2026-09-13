import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/nikon_engine.dart';
import '../engine/record_store.dart';
import 'local_viewer_page.dart';

/// 手机页：已下载照片管理。按日期分组展示，滑动范围多选，批量删除。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.model});

  final AppModel model;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  static const yellow = Color(0xFFFFE100);
  static const int _cols = 3;
  static const double _gap = 2;

  final Set<String> _selected = {}; // RecEntry.key
  bool _selectMode = false;
  bool _dragSelecting = false;
  bool _dragAdd = true;
  int? _anchorIdx;
  Offset? _lastGlobal;
  Timer? _autoScrollTimer;
  final ScrollController _scrollCtrl = ScrollController();
  final Map<String, GlobalKey> _cellKeys = {};
  final Map<String, Uint8List?> _thumbs = {};
  bool _deleting = false;

  AppModel get model => widget.model;

  List<RecEntry> get _entries => model.gateway.records.all;

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

  void _toggle(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
      if (_selectMode && _selected.isEmpty) _selectMode = false;
    });
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

  void _applyRange(int cur, bool add) {
    final anchor = _anchorIdx;
    if (anchor == null) return;
    final entries = _entries;
    final lo = min(anchor, cur), hi = max(anchor, cur);
    var changed = false;
    for (var i = lo; i <= hi && i < entries.length; i++) {
      if (add) {
        changed |= _selected.add(entries[i].key);
      } else {
        changed |= _selected.remove(entries[i].key);
      }
    }
    if (changed) setState(() {});
  }

  void _onDragMove(Offset global, bool add) {
    _lastGlobal = global;
    final hit = _hitIndex(global);
    if (hit != null) _applyRange(hit, add);
    _updateAutoScroll(global, add);
  }

  void _updateAutoScroll(Offset global, bool add) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(global);
    const edge = 90.0;
    const step = 7.0;
    double? delta;
    if (local.dy < edge && local.dy > 0) delta = -step;
    if (local.dy > box.size.height - edge && local.dy < box.size.height) delta = step;
    if (delta == null) {
      _stopAutoScroll();
      return;
    }
    if (_autoScrollTimer != null) return;
    final d = delta;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_dragSelecting || !_scrollCtrl.hasClients) {
        _stopAutoScroll();
        return;
      }
      final pos = _scrollCtrl.position;
      pos.jumpTo((pos.pixels + d).clamp(0.0, pos.maxScrollExtent));
      if (_lastGlobal != null) {
        final hit = _hitIndex(_lastGlobal!);
        if (hit != null) _applyRange(hit, add);
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
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
    final picks = _entries.where((e) => _selected.contains(e.key)).toList();
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
    setState(() {
      _deleting = false;
      _selectMode = false;
      _selected.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已删除 $done 张照片')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final sections = _sections;
        final entries = _entries;
        return Scaffold(
          backgroundColor: const Color(0xFF0A0A0A),
          appBar: AppBar(
            title: _selectMode ? Text('已选 ${_selected.length}') : const Text('手机'),
            leading: _selectMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _selectMode = false;
                      _selected.clear();
                    }),
                  )
                : null,
            actions: [
              if (_selectMode)
                TextButton(
                  onPressed: () {
                    setState(() {
                      final all = entries.map((e) => e.key).toSet();
                      if (all.length == _selected.length) {
                        _selected.clear();
                      } else {
                        _selected
                          ..clear()
                          ..addAll(all);
                      }
                    });
                  },
                  child: Text(
                    _selected.length == entries.length ? '取消全选' : '全选',
                    style: const TextStyle(color: yellow),
                  ),
                ),
            ],
          ),
          body: _deleting
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.photo_library_outlined, size: 56, color: Colors.white24),
                          const SizedBox(height: 12),
                          Text(
                            '还没有从相机下载的照片',
                            style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5)),
                          ),
                        ],
                      ),
                    )
                  : Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerMove: (d) {
                        if (_dragSelecting) _onDragMove(d.position, _dragAdd);
                      },
                      onPointerUp: (_) {
                        _dragSelecting = false;
                        _anchorIdx = null;
                        _stopAutoScroll();
                      },
                      onPointerCancel: (_) {
                        _dragSelecting = false;
                        _anchorIdx = null;
                        _stopAutoScroll();
                      },
                      child: CustomScrollView(
                        controller: _scrollCtrl,
                        slivers: [
                          for (final section in sections) ...[
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
                                childAspectRatio: 1,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, i) => _cell(section.value[i]),
                                childCount: section.value.length,
                              ),
                            ),
                          ],
                          const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
                        ],
                      ),
                    ),
          bottomNavigationBar: _selectMode ? _bottomBar() : null,
        );
      },
    );
  }

  Widget _cell(RecEntry e) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadThumb(e));
    final bytes = _thumbs[e.key];
    final isSel = _selected.contains(e.key);
    return GestureDetector(
      key: _keyOf(e),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_selectMode) {
          _toggle(e.key);
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
        if (!_selectMode) setState(() => _selectMode = true);
        _dragAdd = !_selected.contains(e.key);
        _anchorIdx = _entries.indexOf(e);
        _dragSelecting = true;
        _applyRange(_anchorIdx!, _dragAdd);
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
                if (!_selectMode) setState(() => _selectMode = true);
                _toggle(e.key);
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
    final count = _selected.length;
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
