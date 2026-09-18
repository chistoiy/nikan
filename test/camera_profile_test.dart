import 'package:flutter_test/flutter_test.dart';
import 'package:nikonsync/engine/settings_store.dart';

/// 相机档案的身份与"推定热点名"规则。
///
/// 为什么值得专门测：这台 ROM 上 Wi-Fi 侧**读不到热点名**
/// （`getSSID()` 恒为 `<unknown ssid>`、`startScan()` 返回 false），
/// 热点名只能由相机自身上报的型号 + 序列号推出来。推错了不会报错，
/// 只会"连不上热点"——正是最难从现象反推的那类问题，所以规则要锁死。
void main() {
  group('推定热点名（真机实测样本：Z50II）', () {
    test('Wi-Fi 链路报的名字带数字尾巴 → 去掉尾巴再用序列号末 5 位', () {
      expect(
        CameraProfile.deriveApSsid(
          cameraName: 'Z50_2_8046907',
          serial: '00000000000000000000000008046907',
        ),
        'NIKON_Z50_2_46907',
      );
    });

    test('USB 链路报的名字不带数字尾巴 → 前缀原样保留', () {
      expect(
        CameraProfile.deriveApSsid(
          cameraName: 'Z50_2',
          serial: '00000000000000000000000008046907',
        ),
        'NIKON_Z50_2_46907',
      );
    });

    test('少任何一半信息都不猜', () {
      expect(CameraProfile.deriveApSsid(cameraName: '', serial: '123456789'), isNull);
      expect(CameraProfile.deriveApSsid(cameraName: 'Z50_2', serial: ''), isNull);
      // 序列号末段不足 5 位 → 规则不成立，宁可不猜
      expect(CameraProfile.deriveApSsid(cameraName: 'Z50_2', serial: '1234'), isNull);
    });
  });

  group('档案归并：一台相机只应有一条记录', () {
    test('序列号相同 → 归并成一条，热点名/地址都保留', () {
      final s = SettingsStore();
      s.upsertCamera(name: 'Z50_2', serial: 'SN1');
      final p = s.upsertCamera(
        name: 'Z50_2_8046907',
        serial: 'SN1',
        ssid: 'NIKON_Z50_2_46907',
        ip: '192.168.1.1',
      );
      expect(s.cameras.length, 1);
      expect(p.ssid, 'NIKON_Z50_2_46907');
      expect(p.ip, '192.168.1.1');
      expect(p.serial, 'SN1');
    });

    test('拿到序列号后，ip 相同的旧记录会被合并删掉（真机上那两条的成因）', () {
      final s = SettingsStore();
      // 旧记录：无线那条（有 ip 无序列号）与 USB 那条（只有名字）
      s.upsertCamera(name: 'Z50II', ip: '192.168.1.1');
      s.upsertCamera(name: 'Z50_2_8046907');
      expect(s.cameras.length, 2);

      // 本次无线连接：序列号 + 同一个 ip
      final p = s.upsertCamera(
        serial: 'SN1',
        name: 'Z50_2_8046907',
        ssid: 'NIKON_Z50_2_46907',
        ip: '192.168.1.1',
      );
      expect(s.cameras.length, 1);
      expect(identical(s.cameras.first, p), isTrue);
      expect(p.ssid, 'NIKON_Z50_2_46907');
    });

    test('热点名是事实还是推定，记账要分清', () {
      final s = SettingsStore();
      final p = s.upsertCamera(name: 'Z50_2', serial: 'SN1', ssid: 'NIKON_Z50_2_46907', ssidDerived: true);
      expect(p.ssidDerived, isTrue);
      // 用户手填（或系统读到）的以事实为准
      s.upsertCamera(ssid: 'NIKON_Z50_2_46907', ssidDerived: false);
      expect(p.ssidDerived, isFalse);
    });
  });

  group('启动时补全推定热点名', () {
    test('只补"有型号/序列号但没热点名"的，且不动同步模式(STA)的', () {
      final s = SettingsStore();
      s.upsertCamera(name: 'Z50_2', serial: '00000000000000000000000008046907');
      final sta = CameraProfile(name: 'Z6_3', serial: '00000000000000000000000009999999', sta: true);
      s.cameras.add(sta);
      expect(s.backfillDerivedSsid(), 1);
      expect(s.cameras.first.ssid, 'NIKON_Z50_2_46907');
      expect(s.cameras.first.ssidDerived, isTrue);
      expect(sta.ssid, isEmpty);
    });

    test('已经有热点名的不会被覆盖', () {
      final s = SettingsStore();
      final p = s.upsertCamera(name: 'Z50_2', serial: '00000000000000000000000008046907', ssid: '我改过的名字');
      expect(s.backfillDerivedSsid(), 0);
      expect(p.ssid, '我改过的名字');
    });
  });

  group('删除按对象身份（热点名可能为空）', () {
    test('删掉只连过 USB 的那条，不会连带删掉别的', () {
      final s = SettingsStore();
      final a = s.upsertCamera(name: 'A');
      final b = s.upsertCamera(name: 'B');
      s.removeCameraProfile(a);
      expect(s.cameras.length, 1);
      expect(identical(s.cameras.first, b), isTrue);
    });
  });
}
