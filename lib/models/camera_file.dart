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
