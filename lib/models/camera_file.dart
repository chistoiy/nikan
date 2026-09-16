/// 相机中的一个文件（句柄来自快速枚举，详情/缩略图按需加载）。
class CameraFile {
  CameraFile({required this.handle, required this.folder});

  final int handle;
  final String folder;

  // ---- 以下字段由 fileInfo/fileView 按需填充 ----
  String? name;
  int? size;
  String? dateText;
  String? dateRaw; // PTP 原始时间 "YYYYMMDDThhmmss"，用于排序
  int? width;
  int? height;
  bool? isVideo;
  bool? isJpeg;
  bool hasThumb = false;

  /// RAW+JPEG 成对：同一目录、同一基名的另一个文件的句柄（无配对为 null）。
  ///
  /// 相机开「RAW + JPEG 同时记录」时，同一张照片是两个独立对象
  /// （`DSC_1234.JPG` 与 `DSC_1234.NEF`，句柄与大小都不同）。这里只做**标记**，
  /// 不合并条目——见 `docs/RAW+JPEG成对照片方案.md` 的方案 A。
  /// 配对由 [AppModel] 在枚举/索引时算好写入。
  int? pairHandle;

  bool get isPaired => pairHandle != null;

  /// 文件名基名（大写，不含扩展名）。配对键用它 + 目录，避免只看文件名
  /// 把不同文件夹里的同号文件误配成一对。
  String? get baseName {
    final n = name;
    if (n == null) return null;
    final i = n.lastIndexOf('.');
    return (i < 0 ? n : n.substring(0, i)).toUpperCase();
  }

  /// 配对键：目录 + 基名（未加载详情时为 null）
  String? get pairKey {
    final b = baseName;
    return b == null ? null : '$folder/$b';
  }

  bool get infoLoaded => name != null;

  /// JPEG / RAW / 视频 分类（未加载详情时为 null）
  String? get kind {
    if (isLoadedVideo) return 'video';
    if (isLoadedJpeg) return 'jpeg';
    if (infoLoaded) return 'raw';
    return null;
  }

  bool get isLoadedVideo => isVideo == true;
  bool get isLoadedJpeg => isJpeg == true;

  String? get ext {
    final n = name;
    if (n == null) return null;
    final i = n.lastIndexOf('.');
    return i < 0 ? null : n.substring(i + 1).toUpperCase();
  }

  void applyInfo(Map<String, dynamic> m) {
    name ??= m['name'] as String?;
    size ??= (m['size'] as num?)?.toInt();
    dateText ??= m['date'] as String?;
    dateRaw ??= m['captureDate'] as String?;
    width ??= (m['width'] as num?)?.toInt();
    height ??= (m['height'] as num?)?.toInt();
    isVideo ??= m['isVideo'] as bool?;
    isJpeg ??= m['isJpeg'] as bool?;
  }

  /// 下载去重键：文件名 + 大小
  String dedupKey([String? nameOverride, int? sizeOverride]) =>
      '${nameOverride ?? name}:$sizeOverride';
}
