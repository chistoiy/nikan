import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用设置（JSON 持久化）：下载画质、下载后删除等。
class SettingsStore {
  String downloadVariant = 'original'; // original / 8M / 2M
  bool deleteAfterDownload = false;
  String sortMode = 'newest'; // newest / oldest / nameAsc / nameDesc

  File? _file;
  bool _loaded = false;

  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}${Platform.pathSeparator}nikonsync_settings.json');
      _file = f;
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) {
          downloadVariant = raw['downloadVariant'] as String? ?? downloadVariant;
          deleteAfterDownload = raw['deleteAfterDownload'] as bool? ?? deleteAfterDownload;
          sortMode = raw['sortMode'] as String? ?? sortMode;
        }
      }
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final f = _file ??
          File('${(await getApplicationDocumentsDirectory()).path}'
              '${Platform.pathSeparator}nikonsync_settings.json');
      _file = f;
      await f.writeAsString(
        jsonEncode({
          'downloadVariant': downloadVariant,
          'deleteAfterDownload': deleteAfterDownload,
          'sortMode': sortMode,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}
