import 'package:flutter_test/flutter_test.dart';
import 'package:nikonsync/models/camera_file.dart';
import 'package:nikonsync/models/pair_linker.dart';

/// RAW+JPEG 配对的规则测试。
///
/// 为什么要有这组测试：真机上（用户当前的卡里只有 JPEG）**根本看不到成对标记**，
/// 也就无法验证配对逻辑是否生效；而配对连错的后果是"下载/删除动到了别的照片"。
/// 所以把规则抽成纯函数并用构造出来的文件列表覆盖各种边界。
CameraFile _f({
  required int handle,
  required String? name,
  String folder = '100NZ502',
  bool jpeg = false,
  bool video = false,
  bool noInfo = false,
}) {
  final f = CameraFile(handle: handle, folder: folder);
  if (!noInfo) {
    f.name = name;
    f.isJpeg = jpeg;
    f.isVideo = video;
    f.size = 1024;
  }
  return f;
}

void main() {
  test('同目录同基名的 JPG + NEF 互相配对', () {
    final jpg = _f(handle: 1, name: 'DSC_1234.JPG', jpeg: true);
    final nef = _f(handle: 2, name: 'DSC_1234.NEF');
    expect(PairLinker.linkAll([jpg, nef]), 2);
    expect(jpg.pairHandle, 2);
    expect(nef.pairHandle, 1);
    expect(jpg.isPaired, isTrue);
  });

  test('只有 JPEG（无 RAW）时不配对', () {
    final a = _f(handle: 1, name: 'DSC_0001.JPG', jpeg: true);
    final b = _f(handle: 2, name: 'DSC_0002.JPG', jpeg: true);
    expect(PairLinker.linkAll([a, b]), 0);
    expect(a.isPaired, isFalse);
    expect(b.isPaired, isFalse);
  });

  test('同基名但都不是 RAW（两张 JPEG 重名）时不配对', () {
    final a = _f(handle: 1, name: 'DSC_1234.JPG', jpeg: true);
    final b = _f(handle: 2, name: 'DSC_1234.JPG', jpeg: true);
    expect(PairLinker.linkAll([a, b]), 0);
  });

  test('同基名但目录不同时不配对', () {
    final a = _f(handle: 1, name: 'DSC_1234.JPG', jpeg: true, folder: '100NZ502');
    final b = _f(handle: 2, name: 'DSC_1234.NEF', folder: '101NZ502');
    expect(PairLinker.linkAll([a, b]), 0);
  });

  test('基名大小写不同仍视为同一张（相机可能小写）', () {
    final a = _f(handle: 1, name: 'dsc_1234.jpg', jpeg: true);
    final b = _f(handle: 2, name: 'DSC_1234.NEF');
    expect(PairLinker.linkAll([a, b]), 2);
    expect(a.pairHandle, 2);
  });

  test('NRW 后缀也算 RAW', () {
    final a = _f(handle: 1, name: 'DSC_0777.JPG', jpeg: true);
    final b = _f(handle: 2, name: 'DSC_0777.NRW');
    expect(PairLinker.linkAll([a, b]), 2);
    expect(b.kind, 'raw');
  });

  test('视频不参与配对（同基名的 MOV 与 JPG 不算一对）', () {
    final a = _f(handle: 1, name: 'DSC_1234.JPG', jpeg: true);
    final b = _f(handle: 2, name: 'DSC_1234.MOV', video: true);
    expect(PairLinker.linkAll([a, b]), 0);
  });

  test('详情未加载（无文件名）时不配对，加载后由增量配对补上', () {
    final a = _f(handle: 1, name: null, noInfo: true);
    final b = _f(handle: 2, name: 'DSC_1234.NEF');
    expect(PairLinker.linkAll([a, b]), 0);
    // 索引补全后：fileInfo 回来时调用 link()
    a.name = 'DSC_1234.JPG';
    a.isJpeg = true;
    expect(PairLinker.link(a, b), isTrue);
    expect(a.pairHandle, 2);
    expect(b.pairHandle, 1);
  });

  test('重新配对会先清掉旧配对（换了卡/删了文件不会残留）', () {
    final jpg = _f(handle: 1, name: 'DSC_1234.JPG', jpeg: true);
    final nef = _f(handle: 2, name: 'DSC_1234.NEF');
    PairLinker.linkAll([jpg, nef]);
    expect(jpg.isPaired, isTrue);
    // 第二次枚举时 RAW 不在了
    PairLinker.linkAll([jpg]);
    expect(jpg.isPaired, isFalse);
    expect(jpg.pairHandle, isNull);
  });

  test('多对文件一次性配对，且只与自己的另一半相连', () {
    final list = [
      _f(handle: 1, name: 'DSC_0001.JPG', jpeg: true),
      _f(handle: 2, name: 'DSC_0001.NEF'),
      _f(handle: 3, name: 'DSC_0002.JPG', jpeg: true),
      _f(handle: 4, name: 'DSC_0002.NEF'),
      _f(handle: 5, name: 'DSC_0003.JPG', jpeg: true),
    ];
    expect(PairLinker.linkAll(list), 4);
    expect(list[0].pairHandle, 2);
    expect(list[2].pairHandle, 4);
    expect(list[4].pairHandle, isNull);
  });
}
