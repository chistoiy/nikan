import 'dart:typed_data';

/// JPEG 头部解析工具集。
///
/// 用途有两个：
/// 1. 读 EXIF Orientation —— 相机横放时会在取景 JPEG 里写入该标记来声明画面
///    应有的方向，相机自己的 LCD 会按标记旋转显示；而 Flutter 的图片解码
///    **不处理 EXIF Orientation**，直接渲染就会出现"画面转了 90°"。
/// 2. 输出一帧的方向/色彩特征 —— 取景色彩与相机 LCD 不一致时用来取证，
///    判断是色彩空间标记被忽略、还是根本没有色彩标记。
///
/// 只走到 APP1(EXIF) 段与 SOF 段为止，不做完整解码，因此可以每帧调用。

// ------------------------------------------------------------------ 公开接口

/// 读出 EXIF Orientation（标签 0x0112）。取不到返回 null。
int? readExifOrientation(Uint8List bytes) {
  final h = _tiffHeader(bytes);
  if (h == null) return null;
  final e = h.lookup(0x0112);
  if (e == null) return null;
  final v = h.valueInt(e);
  return (v >= 1 && v <= 8) ? v : null;
}

/// 一帧 JPEG 的方向与色彩特征，单行文本。
///
/// 输出示例：`73KB 1600×1064 orientation=6 colorSpace=sRGB interop=R03 ICC=无`
/// - `orientation`：6/8 表示相机横放（需要转 90°）；「无」说明帧里没带方向标记，
///   自动旋转不可能生效，只能用手动旋转或厂商属性。
/// - `colorSpace`：EXIF 0xA001，1=sRGB，0xFFFF=未校准。
/// - `interop`：R98=sRGB / R03=Adobe RGB / THM=缩略图。出现 R03 基本可以断定
///   画面发闷是色彩空间标记被忽略导致的。
/// - `ICC`：是否带 ICC 色彩配置文件（解码端同样会忽略）。
String describeJpegFrame(Uint8List bytes) {
  final parts = <String>['${(bytes.length / 1024).toStringAsFixed(0)}KB'];
  final dims = _sofDimensions(bytes);
  if (dims != null) parts.add('${dims.$1}×${dims.$2}');

  final o = readExifOrientation(bytes);
  parts.add('orientation=${o ?? '无'}');

  final h = _tiffHeader(bytes);
  final csEntry = h?.lookup(0xA001);
  final cs = csEntry == null ? null : h!.valueInt(csEntry);
  parts.add('colorSpace=${cs == null ? '无' : (cs == 1 ? 'sRGB' : '0x${cs.toRadixString(16)}')}');

  final interopEntry = h?.lookup(0x0001); // 在 Interop IFD 里
  parts.add('interop=${interopEntry == null ? '无' : h!.ascii(interopEntry)}');
  parts.add('ICC=${_hasIccProfile(bytes) ? '有' : '无'}');
  return parts.join(' ');
}

// ------------------------------------------------------------------ 段遍历

const int _markerSoi = 0xD8;
const int _markerApp1 = 0xE1;
const int _markerApp2 = 0xE2;
const int _markerSos = 0xDA;

/// 依次遍历 JPEG 段。回调返回 null 表示继续，返回非 null 即作为结果返回。
/// 段长度非法或越界时立即停止（不信任数据）。
T? _walkSegments<T>(Uint8List b, T? Function(int marker, int start, int end) visit) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != _markerSoi) return null;
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null; // 段结构异常，放弃
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // 填充字节
      continue;
    }
    if (marker == _markerSoi || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2; // 无载荷标记
      continue;
    }
    if (marker == _markerSos) return null; // 进入扫描数据，后续不再有元信息
    final segLen = (b[i + 2] << 8) | b[i + 3];
    if (segLen < 2) return null;
    final segEnd = i + 2 + segLen;
    if (segEnd > b.length) return null;
    final r = visit(marker, i + 4, segEnd);
    if (r != null) return r;
    i = segEnd;
  }
  return null;
}

/// SOF 段的宽高：`(宽, 高)`。取不到返回 null。
(int, int)? _sofDimensions(Uint8List b) {
  return _walkSegments<(int, int)>(b, (marker, start, end) {
    // SOF0~SOF3 / SOF5~SOF7 / SOF9~SOF11 / SOF13~SOF15（排除 DHT=C4 等）
    final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (!isSof || start + 5 > end) return null;
    final h = (b[start + 1] << 8) | b[start + 2];
    final w = (b[start + 3] << 8) | b[start + 4];
    return (w, h);
  });
}

bool _hasIccProfile(Uint8List b) {
  return _walkSegments<bool>(b, (marker, start, end) {
    if (marker != _markerApp2 || start + 12 > end) return null;
    const sig = 'ICC_PROFILE'; // 11 字节
    for (var k = 0; k < sig.length; k++) {
      if (b[start + k] != sig.codeUnitAt(k)) return null;
    }
    return true;
  }) ??
      false;
}

// ------------------------------------------------------------------ EXIF 标签

class _TiffHeader {
  _TiffHeader(this.b, this.tiff, this.end, this.little);

  final Uint8List b;
  final int tiff;
  final int end;
  final bool little;

  int u16(int o) => little ? (b[o] | (b[o + 1] << 8)) : ((b[o] << 8) | b[o + 1]);

  int u32(int o) => little
      ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24))
      : ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);

  int get ifd0Offset => tiff + u32(tiff + 4);

  /// 在 ifdOff 指向的 IFD 里查 tag，返回 `(类型, 个数, 值字段偏移)`；找不到返回 null。
  /// 注意条目里 tag/type 各 2 字节，而"个数"是 4 字节——按 2 字节读在大端下会得到 0。
  (int, int, int)? findEntry(int ifdOff, int tag) {
    if (ifdOff < tiff || ifdOff + 2 > end) return null;
    final entries = u16(ifdOff);
    var e = ifdOff + 2;
    for (var k = 0; k < entries && e + 12 <= end; k++, e += 12) {
      if (u16(e) == tag) return (u16(e + 2), u32(e + 4), e + 8);
    }
    return null;
  }

  /// 立即数值（SHORT=3 / LONG=4；其他类型按前两字节取，够用）
  int valueInt((int, int, int) entry) {
    final (type, _, off) = entry;
    return type == 4 ? u32(off) : u16(off);
  }

  /// ASCII 立即值（最多 4 字节，去掉结尾 NUL）。
  /// ASCII 是字节串，不受 TIFF 字节序影响，直接按顺序取字节。
  String ascii((int, int, int) entry) {
    final (_, count, off) = entry;
    final n = count.clamp(0, 4);
    final s = String.fromCharCodes([for (var k = 0; k < n; k++) b[off + k]]);
    return s.replaceAll('\u0000', '').trim();
  }

  /// 依次在 IFD0 → Exif IFD(0x8769) → Interop IFD(0xA005) 中查找 tag。
  (int, int, int)? lookup(int tag) {
    final direct = findEntry(ifd0Offset, tag);
    if (direct != null) return direct;

    final exifPtr = findEntry(ifd0Offset, 0x8769);
    if (exifPtr == null) return null;
    final exifIfd = tiff + valueInt(exifPtr);
    final inExif = findEntry(exifIfd, tag);
    if (inExif != null) return inExif;

    final interopPtr = findEntry(exifIfd, 0xA005);
    if (interopPtr == null) return null;
    return findEntry(tiff + valueInt(interopPtr), tag);
  }
}

_TiffHeader? _tiffHeader(Uint8List bytes) {
  return _walkSegments<_TiffHeader>(bytes, (marker, start, end) {
    if (marker != _markerApp1 || start + 6 > end) return null;
    const exifTag = [0x45, 0x78, 0x69, 0x66]; // "Exif"
    for (var k = 0; k < 4; k++) {
      if (bytes[start + k] != exifTag[k]) return null;
    }
    final tiff = start + 6;
    if (tiff + 8 > end) return null;
    final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
    final big = bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D;
    if (!little && !big) return null;
    final h = _TiffHeader(bytes, tiff, end, little);
    if (h.u16(tiff + 2) != 0x002A) return null;
    return h;
  });
}
