import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikonsync/util/jpeg_exif.dart';

/// 构造一个含 EXIF APP1 的 JPEG 头，用于验证解析器。
///
/// 结构：SOI + APP1("Exif\0\0" + TIFF + IFD0) + [SOF0] + [APP2(ICC)] + SOS
Uint8List buildJpeg({
  int? orientation,
  int? colorSpace,
  String? interop, // 4 字节 ASCII，写入 Interop IFD
  int width = 1600,
  int height = 1064,
  bool withSof = true,
  bool icc = false,
  bool little = true,
}) {
  // 全部为纯函数：返回字节列表，避免"就地追加 + 展开"混用
  List<int> u16(int v) => little ? [v & 0xFF, (v >> 8) & 0xFF] : [(v >> 8) & 0xFF, v & 0xFF];
  List<int> u32(int v) => little
      ? [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
      : [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  // TIFF 规定：小于 4 字节的值左对齐放在值字段起始处，字节序作用于值本身。
  // SHORT 必须按 2 字节写，写成 32 位在大端下会错位到最后一个字节。
  List<int> entry(int tag, int type, int count, int value) => [
        ...u16(tag),
        ...u16(type),
        ...u32(count),
        ...(type == 3 ? [...u16(value), 0, 0] : u32(value)),
      ];
  List<int> asciiEntry(int tag, String s) {
    // 4 字节 ASCII 值：字符按顺序排列，剩余补 0；字节序不影响字符顺序
    final bytes = <int>[...s.codeUnits.take(4)];
    while (bytes.length < 4) {
      bytes.add(0);
    }
    return [...u16(tag), ...u16(2), ...u32(s.length), ...bytes];
  }

  const ifd0Offset = 8;
  final ifd0Entries = <List<int>>[];
  if (orientation != null) ifd0Entries.add(entry(0x0112, 3, 1, orientation));

  final exifEntries = <List<int>>[];
  if (colorSpace != null) exifEntries.add(entry(0xA001, 3, 1, colorSpace));
  final interopEntries = <List<int>>[];
  if (interop != null) interopEntries.add(asciiEntry(0x0001, interop));

  // 先按"是否要写 Exif IFD 指针"定下 IFD0 的最终条目数，再算各段偏移
  final hasExifIfd = exifEntries.isNotEmpty || interopEntries.isNotEmpty;
  var exifPtrIndex = -1;
  if (hasExifIfd) {
    exifPtrIndex = ifd0Entries.length;
    ifd0Entries.add(entry(0x8769, 4, 1, 0)); // 偏移稍后回填
  }

  final ifd0Size = 2 + ifd0Entries.length * 12 + 4;
  final exifIfdOffset = ifd0Offset + ifd0Size;

  final exifCount = exifEntries.length + (interopEntries.isNotEmpty ? 1 : 0);
  final exifIfdSize = 2 + exifCount * 12 + 4;
  final interopIfdOffset = exifIfdOffset + exifIfdSize;

  // 回填 Exif IFD 偏移
  if (exifPtrIndex >= 0) {
    ifd0Entries[exifPtrIndex] = entry(0x8769, 4, 1, exifIfdOffset);
  }
  if (interopEntries.isNotEmpty) {
    exifEntries.add(entry(0xA005, 4, 1, interopIfdOffset));
  }

  final tiff = <int>[
    ...(little ? [0x49, 0x49] : [0x4D, 0x4D]),
    ...u16(0x2A),
    ...u32(ifd0Offset),
  ];
  tiff.addAll(u16(ifd0Entries.length));
  for (final e in ifd0Entries) {
    tiff.addAll(e);
  }
  tiff.addAll([0, 0, 0, 0]);

  if (hasExifIfd) {
    assert(tiff.length == exifIfdOffset, 'Exif IFD 偏移对不上: ${tiff.length} != $exifIfdOffset');
    tiff.addAll(u16(exifEntries.length));
    for (final e in exifEntries) {
      tiff.addAll(e);
    }
    tiff.addAll([0, 0, 0, 0]);
  }

  if (interopEntries.isNotEmpty) {
    assert(tiff.length == interopIfdOffset, 'Interop IFD 偏移对不上: ${tiff.length} != $interopIfdOffset');
    tiff.addAll(u16(interopEntries.length));
    for (final e in interopEntries) {
      tiff.addAll(e);
    }
    tiff.addAll([0, 0, 0, 0]);
  }

  final out = <int>[0xFF, 0xD8];
  final app1Payload = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
  final segLen = app1Payload.length + 2;
  out.addAll([0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF, ...app1Payload]);

  if (withSof) {
    final sof = <int>[
      0x08,
      (height >> 8) & 0xFF, height & 0xFF,
      (width >> 8) & 0xFF, width & 0xFF,
      0x03,
      0x01, 0x11, 0x00,
      0x02, 0x11, 0x00,
      0x03, 0x11, 0x00,
    ];
    final sofLen = sof.length + 2;
    out.addAll([0xFF, 0xC0, (sofLen >> 8) & 0xFF, sofLen & 0xFF, ...sof]);
  }

  if (icc) {
    final iccPayload = <int>[
      ...'ICC_PROFILE'.codeUnits, 0x00, 0x01, 0x01, 0x00,
      ...List.filled(20, 0),
    ];
    final iccLen = iccPayload.length + 2;
    out.addAll([0xFF, 0xE2, (iccLen >> 8) & 0xFF, iccLen & 0xFF, ...iccPayload]);
  }

  out.addAll([0xFF, 0xDA, 0x00, 0x02]); // SOS，终止段遍历
  return Uint8List.fromList(out);
}

void main() {
  group('readExifOrientation', () {
    test('读出各方向值', () {
      for (final o in [1, 3, 6, 8]) {
        expect(readExifOrientation(buildJpeg(orientation: o)), o, reason: 'orientation=$o');
      }
    });

    test('大端 TIFF 同样能读', () {
      expect(readExifOrientation(buildJpeg(orientation: 6, little: false)), 6);
    });

    test('没有 Orientation 标签时返回 null', () {
      expect(readExifOrientation(buildJpeg(colorSpace: 1)), isNull);
    });

    test('非 JPEG / 空 / 截断数据不抛异常且返回 null', () {
      expect(readExifOrientation(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(readExifOrientation(Uint8List(0)), isNull);
      final full = buildJpeg(orientation: 6);
      expect(readExifOrientation(Uint8List.sublistView(full, 0, 8)), isNull);
      expect(readExifOrientation(Uint8List.sublistView(full, 0, 20)), isNull);
    });

    test('长度字段被破坏时不越界（读到越界即放弃）', () {
      final bad = buildJpeg(orientation: 6);
      bad[4] = 0xFF; // APP1 段长度改成极大值
      bad[5] = 0xFF;
      expect(readExifOrientation(bad), isNull);
    });
  });

  group('describeJpegFrame', () {
    test('输出尺寸、方向、色彩空间、interop 与 ICC', () {
      final b = buildJpeg(orientation: 6, colorSpace: 1, icc: true);
      final s = describeJpegFrame(b);
      expect(s, contains('1600×1064'));
      expect(s, contains('orientation=6'));
      expect(s, contains('colorSpace=sRGB'));
      expect(s, contains('ICC=有'));
    });

    test('未校准色彩空间会亮出原始值', () {
      final s = describeJpegFrame(buildJpeg(orientation: 1, colorSpace: 0xFFFF));
      expect(s, contains('colorSpace=0xffff'));
    });

    test('interop 标识按 ASCII 读出，不受字节序影响', () {
      expect(describeJpegFrame(buildJpeg(orientation: 1, interop: 'R03')),
          contains('interop=R03'));
      expect(describeJpegFrame(buildJpeg(orientation: 1, interop: 'R98', little: false)),
          contains('interop=R98'));
    });

    test('缺元信息时不崩，字段显示"无"', () {
      final s = describeJpegFrame(buildJpeg(withSof: false));
      expect(s, contains('orientation=无'));
      expect(s, contains('colorSpace=无'));
      expect(s, contains('ICC=无'));
    });
  });
}
