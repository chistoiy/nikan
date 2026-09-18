import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用设置（JSON 持久化）：下载画质、下载后删除、查看画质等。
class SettingsStore {
  String downloadVariant = 'original'; // original / 8M / 2M
  bool deleteAfterDownload = false;
  String sortMode = 'newest'; // newest / oldest / nameAsc / nameDesc

  /// 大图查看器的默认画质：low（大缩略图）/ medium（相机端 FHD 图）/ original。
  /// 默认 medium：一张 JPEG 原图可达 20MB+，Wi-Fi 下要好几秒，
  /// 而"看个大概"根本不需要原图——需要像素级细节时再按"显示原图"。
  String viewerQuality = 'medium';

  /// 在大图页点「显示原图」时，是否顺带把原图保存到手机。
  ///
  /// **默认关**：看一张图和"把这张收进手机"是两件事，用户可能只是想放大确认
  /// 一下合焦。默认落盘会让相册里悄悄多出一堆没打算要的文件；开启后则省掉
  /// "看完再回相册点一次下载"的重复传输（同一张图只传一遍）。
  bool viewerSaveOriginal = false;

  /// 取景点击对焦的坐标缩放系数（**人工兜底值**）。
  ///
  /// 正常路径不靠它：`ChangeAfArea(0x9205)` 的坐标空间可以从**取景帧头部**里读出来
  /// （`off12/14` 相机图像尺寸 ÷ `off8/10` 取景帧尺寸，x/y 各算一次 —— 见
  /// `CameraEngine.afScaleFromHeader`），遥控页首帧后自动采用，本值只在解析失败
  /// 或用户手工覆盖时生效。
  ///
  /// 留这个兜底是因为头部解析在个别机型/固件上可能失败，那时还得能手动调。
  double afAreaScale = 4.0;

  /// RAW+JPEG 成对时，勾选一个是否自动带上配对的另一个（默认开）。
  ///
  /// 现场挑片最常见的是"要这张"——JPEG 与 RAW 都是这张照片，分开勾两次没有必要；
  /// 但只想收 JPEG 的人也不少，所以做成开关（关掉后各选各的）。
  bool linkRawJpegPairs = true;

  /// 设置结构版本。
  ///
  /// **改动任何设置键的名字或语义时必须 +1，并在 [_migrate] 里补一条迁移，不要再给键名加后缀。**
  /// 之前就是靠加后缀演进的（`afAreaScale` → `afAreaScaleV2` → `afAreaScaleV3`），结果是同一份
  /// JSON 里躺着三个同名不同后缀的键，除了作者没人知道哪个生效——而"读哪个"这件事只写在代码注释里。
  static const int schemaVersion = 1;

  /// 把旧版设置就地迁移到当前 [schemaVersion]。
  ///
  /// v0 → v1：对焦倍数键名去后缀（`afAreaScaleV3` → `afAreaScale`），
  /// 并删掉历史遗留、已不再读取的 `afAreaScale`（×1 时代取值）与 `afAreaScaleV2`（×16 的错误结论）。
  static void _migrate(Map<dynamic, dynamic> raw, int from) {
    if (from >= 1) return;
    final v3 = raw['afAreaScaleV3'];
    raw.remove('afAreaScale');
    raw.remove('afAreaScaleV2');
    raw.remove('afAreaScaleV3');
    if (v3 != null) raw['afAreaScale'] = v3;
  }

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
          // 先迁移再读：老 JSON 里可能同时存在多个历史键名
          _migrate(raw, (raw['schemaVersion'] as num?)?.toInt() ?? 0);
          downloadVariant = raw['downloadVariant'] as String? ?? downloadVariant;
          deleteAfterDownload = raw['deleteAfterDownload'] as bool? ?? deleteAfterDownload;
          sortMode = raw['sortMode'] as String? ?? sortMode;
          viewerQuality = raw['viewerQuality'] as String? ?? viewerQuality;
          viewerSaveOriginal = raw['viewerSaveOriginal'] as bool? ?? viewerSaveOriginal;
          afAreaScale = (raw['afAreaScale'] as num?)?.toDouble() ?? afAreaScale;
          linkRawJpegPairs = raw['linkRawJpegPairs'] as bool? ?? linkRawJpegPairs;
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
          'schemaVersion': schemaVersion,
          'downloadVariant': downloadVariant,
          'deleteAfterDownload': deleteAfterDownload,
          'sortMode': sortMode,
          'viewerQuality': viewerQuality,
          'viewerSaveOriginal': viewerSaveOriginal,
          'afAreaScale': afAreaScale,
          'linkRawJpegPairs': linkRawJpegPairs,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}
