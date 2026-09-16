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

  /// 取景点击对焦的坐标缩放系数。
  ///
  /// `ChangeAfArea(0x9205)` 的 x/y 用哪个坐标空间没有文档（libgphoto2 只写了
  /// "2 参数 x, y"）。**2026-09-15 真机实测结论：相机空间 = 取景帧的 4 倍**
  /// （640×424 帧 ↔ 2560×1696），原点在左上、等比。
  /// 判据：×4 时点击位置与相机上的对焦框一致；×16 时对焦点被顶到右下角
  /// （说明坐标超范围被截断）。相机不提供任何"AF 坐标空间尺寸"属性
  /// （0xD0xx 探针全"不支持"），所以只能实测确定，无法自动推算。
  ///
  /// 键名 V3：V2 存的是"×16"这个错误结论，不能沿用。
  double afAreaScale = 4.0;

  /// RAW+JPEG 成对时，勾选一个是否自动带上配对的另一个（默认开）。
  ///
  /// 现场挑片最常见的是"要这张"——JPEG 与 RAW 都是这张照片，分开勾两次没有必要；
  /// 但只想收 JPEG 的人也不少，所以做成开关（关掉后各选各的）。
  bool linkRawJpegPairs = true;

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
          viewerQuality = raw['viewerQuality'] as String? ?? viewerQuality;
          viewerSaveOriginal = raw['viewerSaveOriginal'] as bool? ?? viewerSaveOriginal;
          // 旧键（afAreaScale ×1 时代 / afAreaScaleV2 ×16 结论）都不读：
          // 实测结论是 ×4，沿用旧值会把人卡在错倍数上
          afAreaScale = (raw['afAreaScaleV3'] as num?)?.toDouble() ?? afAreaScale;
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
          'downloadVariant': downloadVariant,
          'deleteAfterDownload': deleteAfterDownload,
          'sortMode': sortMode,
          'viewerQuality': viewerQuality,
          'viewerSaveOriginal': viewerSaveOriginal,
          'afAreaScaleV3': afAreaScale,
          'linkRawJpegPairs': linkRawJpegPairs,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}
