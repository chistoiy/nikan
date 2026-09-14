import 'dart:typed_data';

import 'package:exif/exif.dart';

/// 常用的拍摄参数摘要（ISO / 光圈 / 快门）。
///
/// 相机相册查看器与本机查看器此前各解析一份，键名还不一致
/// （iso/f/s 与 iso/fNumber/exposure），统一到这里。
class ExifSummary {
  const ExifSummary({this.iso, this.fNumber, this.exposure});

  final String? iso;
  final String? fNumber;
  final String? exposure;

  bool get isEmpty => iso == null && fNumber == null && exposure == null;

  /// 从图片字节解析。非 JPEG 或没有 EXIF 时返回空摘要，不抛异常。
  static Future<ExifSummary> parse(Uint8List bytes) async {
    try {
      final tags = await readExifFromBytes(bytes);
      return ExifSummary(
        iso: tags['EXIF ISOSpeedRatings']?.printable,
        fNumber: tags['EXIF FNumber']?.printable,
        exposure: tags['EXIF ExposureTime']?.printable,
      );
    } catch (_) {
      return const ExifSummary();
    }
  }

  /// 单行展示，例如 "ISO 400   f/2.8   1/250s"
  String get text => [
        if (iso != null) 'ISO $iso',
        if (fNumber != null) 'f/$fNumber',
        if (exposure != null) '${exposure}s',
      ].join('   ');
}
