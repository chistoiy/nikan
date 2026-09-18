import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nikonsync/engine/camera_gateway.dart';

void main() {
  group('取消与失败的区分', () {
    test('原生 CancelledException（经 PlatformException 包装）被识别为取消', () {
      final e = PlatformException(
        code: 'error',
        message: '下载已取消（已下载 12MB）',
      );
      expect(isCancelledError(e), isTrue);
    });

    test('类名出现在消息里也算取消', () {
      expect(isCancelledError('CancelledException: 下载已取消'), isTrue);
    });

    test('普通失败绝不能被当成取消', () {
      // 这些若被误判为"取消"，用户会以为是自己点的，实际是故障——必须能区分
      expect(isCancelledError(Exception('传输不完整：期望 100 字节，实际收到 60 字节')), isFalse);
      expect(isCancelledError(Exception('对象大小无效（0），拒绝下载以免生成空文件')), isFalse);
      expect(isCancelledError(PlatformException(code: 'error', message: 'PTP DeviceBusy: 操作 0x100E')),
          isFalse);
    });
  });

  group('DownloadSummary 统计口径', () {
    test('取消时 remaining 给出"还没传的张数"', () {
      final s = DownloadSummary(total: 10)
        ..downloaded = 3
        ..skipped = 1
        ..cancelled = true;
      expect(s.done, 4);
      expect(s.remaining, 6);
    });

    test('取消不算失败，但也不等于"全部正常"', () {
      final s = DownloadSummary(total: 5)
        ..downloaded = 2
        ..cancelled = true;
      expect(s.failed, 0);
      // allOk 必须考虑 cancelled：取消时若返回 true，UI 会说"全部完成"
      expect(s.allOk, isFalse);
    });

    test('没有失败也没有取消时才是全部正常', () {
      final s = DownloadSummary(total: 2)
        ..downloaded = 2
        ..skipped = 0;
      expect(s.allOk, isTrue);
      expect(s.remaining, 0);
    });
  });
}
