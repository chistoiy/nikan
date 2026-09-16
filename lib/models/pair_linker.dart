import 'camera_file.dart';

/// RAW+JPEG 配对规则（纯函数，便于单测）。
///
/// 相机开「RAW + JPEG 同时记录」时，同一张照片会生成两个独立对象：
/// `100NZ502/DSC_1234.JPG` 与 `100NZ502/DSC_1234.NEF`（句柄、大小都不同）。
/// 配对键 = **目录 + 大写基名**，并要求**类型互补**（一个 JPEG、一个 RAW）。
///
/// 为什么必须互补：同名不同类的两个文件（例如连拍写入的两张 `DSC_1234.JPG`）
/// 不该被当成一对——宁可不连，也不要连错（连错的后果是下载/删除动到了别的照片）。
class PairLinker {
  PairLinker._();

  /// 配对键：目录 + 大写基名；文件名未知时返回 null（还没索引到，无法判断）
  static String? keyOf(CameraFile f) => f.pairKey;

  /// 两个文件是否可以互为配对
  static bool canPair(CameraFile a, CameraFile b) {
    if (identical(a, b) || a.handle == b.handle) return false;
    final ka = keyOf(a);
    final kb = keyOf(b);
    if (ka == null || kb == null || ka != kb) return false;
    final ta = a.kind;
    final tb = b.kind;
    if (ta == null || tb == null) return false;
    return (ta == 'jpeg' && tb == 'raw') || (ta == 'raw' && tb == 'jpeg');
  }

  /// 在 [other] 与 [f] 之间建立双向配对（不满足条件则不动）
  static bool link(CameraFile f, CameraFile? other) {
    if (other == null || !canPair(f, other)) return false;
    f.pairHandle = other.handle;
    other.pairHandle = f.handle;
    return true;
  }

  /// 全量配对（枚举/重新索引后调用）：先清空旧配对，再按基名索引配对。
  /// 返回成功配对的文件数（= 2 × 对数）。
  static int linkAll(List<CameraFile> files) {
    for (final f in files) {
      f.pairHandle = null;
    }
    final index = <String, CameraFile>{};
    for (final f in files) {
      final k = keyOf(f);
      if (k != null) index.putIfAbsent(k, () => f);
    }
    var paired = 0;
    for (final f in files) {
      final k = keyOf(f);
      if (k == null) continue;
      if (link(f, index[k])) paired += 2;
    }
    return paired;
  }
}
