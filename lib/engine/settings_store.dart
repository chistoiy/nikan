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

  /// 取景点击对焦的坐标缩放系数（**人工兜底值**）。
  ///
  /// 正常路径不靠它：`ChangeAfArea(0x9205)` 的坐标空间可以从**取景帧头部**里读出来
  /// （`off12/14` 相机图像尺寸 ÷ `off8/10` 取景帧尺寸，x/y 各算一次 —— 见
  /// `CameraEngine.afScaleFromHeader`），遥控页首帧后自动采用，本值只在解析失败
  /// 或用户手工覆盖时生效。
  ///
  /// 留这个兜底是因为头部解析在个别机型/固件上可能失败，那时还得能手动调。
  double afAreaScale = 4.0;

  /// RAW+JPEG 成对时，勾选一个是否自动带上配对的另一个（默认开）。
  ///
  /// 现场挑片最常见的是"要这张"——JPEG 与 RAW 都是这张照片，分开勾两次没有必要；
  /// 但只想收 JPEG 的人也不少，所以做成开关（关掉后各选各的）。
  bool linkRawJpegPairs = true;

  // ---- 记住连接过的设备 + 自动连接 ----

  // ---- 相机档案（可以有多台：经常还要连别人的相机）----

  /// 已记录的相机。第一台通常是自己的，后面可能是别人的/备用机。
  final List<CameraProfile> cameras = [];

  /// 上次成功使用的那台（"一键重连"默认选它、自动连接也认它）
  String? lastUsedSsid;

  CameraProfile? get lastCamera {
    if (cameras.isEmpty) return null;
    return cameras.firstWhere(
      (c) => c.ssid.isNotEmpty && c.ssid == lastUsedSsid,
      orElse: () => cameras.first,
    );
  }

  /// 兼容旧调用点：这些 getter 现在都指向"上次使用的那台"
  String? get lastCameraSsid => lastCamera?.ssid;
  String? get lastCameraIp => lastCamera?.ip;
  String? get lastCameraName => lastCamera?.name;
  String? get apPassword => lastCamera?.password;

  /// 是否记住过某台相机（名称也算数：只连过 USB 时拿不到 SSID/IP）
  bool get hasRememberedCamera => cameras.any((c) =>
      c.ssid.isNotEmpty || c.ip.isNotEmpty || c.name.isNotEmpty);

  /// 是否有可用于"一键重连"的热点记忆
  bool get hasWifiMemory =>
      cameras.any((c) => c.ssid.isNotEmpty || c.ip.isNotEmpty);

  /// 记住/更新一台相机。**按序列号归并**（Wi-Fi 与 USB 都会得到同一个序列号），
  /// 序列号未知时依次退到 SSID → 地址 → 名称。
  ///
  /// ⚠️ 给**旧记录补热点名**时不要走这里——旧记录 SSID 为空，按新 SSID 匹配不到，
  /// 结果会另建一条、旧的那条永远留着（真机反馈"补了 SSID 还是不显示"就是这个）。
  /// 编辑已有档案请用 `AppModel.updateCameraProfile()`。
  CameraProfile upsertCamera({
    String? serial,
    String? ssid,
    bool? ssidDerived,
    String? password,
    String? name,
    String? ip,
    bool? sta,
  }) {
    final serialKey = (serial ?? '').trim();
    final key = (ssid ?? '').trim();
    final nameKey = (name ?? '').trim();
    final ipKey = (ip ?? '').trim();

    // 匹配优先级 = 身份的可靠度：序列号 > 热点名 > 地址 > 名称
    var p = _findProfile((c) => serialKey.isNotEmpty && c.serial == serialKey) ??
        _findProfile((c) => key.isNotEmpty && c.ssid == key) ??
        _findProfile((c) => ipKey.isNotEmpty && c.ip == ipKey) ??
        _findProfile((c) => nameKey.isNotEmpty && c.name == nameKey) ??
        CameraProfile();

    if (!cameras.contains(p)) cameras.add(p);
    if (serialKey.isNotEmpty) p.serial = serialKey;
    if (key.isNotEmpty) {
      p.ssid = key;
      // 谁给的 SSID 决定它是否"推定"：系统读到的/用户输入的是事实，
      // 推导出来的是猜测（留待一次成功入网后转正）
      p.ssidDerived = ssidDerived ?? false;
    } else if (ssidDerived != null && p.ssid.isEmpty) {
      p.ssidDerived = ssidDerived;
    }
    if (nameKey.isNotEmpty) p.name = nameKey;
    if (ip != null && ip.isNotEmpty) p.ip = ip;
    if (password != null) p.password = password;
    if (sta != null) p.sta = sta;

    // 合并同机记录：拿到序列号后，满足任一条的就必然是同一台相机 ——
    //   · 热点名相同（同一个热点）
    //   · 地址相同（同一个 IP 只可能是同一台设备）
    //   · **推定热点名相同**（型号 + 序列号末 5 位都一致 ⇒ 同一台机身）
    // 把它们的字段并进来再删掉，避免列表里出现两条（真机反馈过的现象）。
    if (serialKey.isNotEmpty) {
      final pHint = p.ssid.isNotEmpty
          ? p.ssid
          : CameraProfile.deriveApSsid(cameraName: p.name, serial: p.serial);
      final dup = cameras
          .where((c) {
            if (identical(c, p)) return false;
            if (key.isNotEmpty && c.ssid == key) return true;
            if (ipKey.isNotEmpty && c.ip == ipKey) return true;
            if (pHint == null) return false;
            final cHint = c.ssid.isNotEmpty
                ? c.ssid
                : CameraProfile.deriveApSsid(cameraName: c.name, serial: c.serial);
            return cHint == pHint;
          })
          .toList();
      for (final c in dup) {
        if (p.ssid.isEmpty) p.ssid = c.ssid;
        if (p.ip.isEmpty) p.ip = c.ip;
        if (p.name.isEmpty) p.name = c.name;
        if (p.password.isEmpty) p.password = c.password;
        if (p.serial.isEmpty) p.serial = c.serial;
      }
      if (dup.isNotEmpty) {
        cameras.removeWhere((c) => dup.contains(c));
        if (dup.any((c) => c.ssid.isNotEmpty && c.ssid == lastUsedSsid)) {
          lastUsedSsid = p.ssid.isNotEmpty ? p.ssid : null;
        }
      }
    }
    if (p.ssid.isNotEmpty) lastUsedSsid = p.ssid;
    return p;
  }

  CameraProfile? _findProfile(bool Function(CameraProfile c) test) {
    for (final c in cameras) {
      if (test(c)) return c;
    }
    return null;
  }

  /// 给"有相机名/序列号、但热点名为空"的档案补上**推定热点名**。
  ///
  /// 为什么在启动时做：Wi-Fi 侧读不到热点名（本机 `getSSID()` 恒为 `<unknown ssid>`），
  /// 而相机自己报的序列号与型号就足以推出它——不补的话副标题永远空着，
  /// 「一键连接」也不会出现（真机反馈的正是这个）。
  ///
  /// 返回补了几条（>0 时调用方应保存）。
  int backfillDerivedSsid() {
    var n = 0;
    for (final c in cameras) {
      if (c.ssid.isNotEmpty || c.sta) continue;
      // 名称里可能已经包含数字尾巴（Wi-Fi 链路），也可能不含（USB 链路）
      final guess = CameraProfile.deriveApSsid(cameraName: c.name, serial: c.serial);
      if (guess == null || guess.isEmpty) continue;
      c.ssid = guess;
      c.ssidDerived = true;
      n++;
    }
    if (n > 0 && lastUsedSsid == null) lastUsedSsid = cameras.first.ssid;
    return n;
  }

  /// 删除一台相机。**按对象身份删**：SSID 可能为空（只连过 USB），
  /// 用 SSID 当键会把所有空 SSID 的记录一起删掉。
  void removeCameraProfile(CameraProfile target) {
    cameras.removeWhere((c) => identical(c, target));
    if (cameras.isEmpty) {
      lastUsedSsid = null;
    } else if (!cameras.any((c) => c.ssid == lastUsedSsid)) {
      lastUsedSsid = cameras.first.ssid;
    }
  }

  /// 兼容旧签名（按 SSID 删除）
  void removeCamera(String ssid) {
    cameras.removeWhere((c) => c.ssid == ssid);
    if (lastUsedSsid == ssid) {
      lastUsedSsid = cameras.isEmpty ? null : cameras.first.ssid;
    }
  }

  /// 忘记全部相机（自动连接随之失效）
  void forgetCamera() {
    cameras.clear();
    lastUsedSsid = null;
  }

  /// 连上已记住的相机热点后自动连接（默认开：用户已经手动加入过这个热点）
  bool autoConnectWifi = true;

  /// 插入 USB 相机（系统把应用拉起 / 检测到接入）后自动连接（默认开：
  /// 插数据线本身就是明确的操作，再让用户点一次没有意义）
  bool autoConnectUsb = true;

  /// 设置结构版本。
  ///
  /// **改动任何设置键的名字或语义时必须 +1，并在 [_migrate] 里补一条迁移，不要再给键名加后缀。**
  /// 之前就是靠加后缀演进的（`afAreaScale` → `afAreaScaleV2` → `afAreaScaleV3`），结果是同一份
  /// JSON 里躺着三个同名不同后缀的键，除了作者没人知道哪个生效——而"读哪个"这件事只写在代码注释里。
  static const int schemaVersion = 1;

  /// 把旧版设置就地迁移到当前 [schemaVersion]。
  ///
  /// v0 → v1：对焦倍数键名去后缀（`afAreaScaleV3` → `afAreaScale`），
  /// 并删掉历史遗留、已不再读取的 `afAreaScale`（×1 时代取值）与 `afAreaScaleV2`（×16 的错误结论）。
  static void _migrate(Map<dynamic, dynamic> raw, int from) {
    if (from >= 1) return;
    final v3 = raw['afAreaScaleV3'];
    raw.remove('afAreaScale');
    raw.remove('afAreaScaleV2');
    raw.remove('afAreaScaleV3');
    if (v3 != null) raw['afAreaScale'] = v3;
  }

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
          // 先迁移再读：老 JSON 里可能同时存在多个历史键名
          _migrate(raw, (raw['schemaVersion'] as num?)?.toInt() ?? 0);
          downloadVariant = raw['downloadVariant'] as String? ?? downloadVariant;
          deleteAfterDownload = raw['deleteAfterDownload'] as bool? ?? deleteAfterDownload;
          sortMode = raw['sortMode'] as String? ?? sortMode;
          viewerQuality = raw['viewerQuality'] as String? ?? viewerQuality;
          viewerSaveOriginal = raw['viewerSaveOriginal'] as bool? ?? viewerSaveOriginal;
          afAreaScale = (raw['afAreaScale'] as num?)?.toDouble() ?? afAreaScale;
          linkRawJpegPairs = raw['linkRawJpegPairs'] as bool? ?? linkRawJpegPairs;
          autoConnectWifi = raw['autoConnectWifi'] as bool? ?? autoConnectWifi;
          autoConnectUsb = raw['autoConnectUsb'] as bool? ?? autoConnectUsb;
          // 相机档案（多台）
          final rawCams = raw['cameras'];
          if (rawCams is List) {
            cameras
              ..clear()
              ..addAll(rawCams
                  .whereType<Map>()
                  .map((m) => CameraProfile.fromJson(Map<String, dynamic>.from(m))));
          }
          lastUsedSsid = raw['lastUsedSsid'] as String? ?? lastUsedSsid;
          // 迁移旧版（只有一台、字段散在根上）：合成一台档案，避免升级后"记住的相机"丢失
          final legacySsid = raw['lastCameraSsid'] as String?;
          final legacyIp = raw['lastCameraIp'] as String?;
          final legacyName = raw['lastCameraName'] as String?;
          if (cameras.isEmpty &&
              ((legacySsid?.isNotEmpty ?? false) ||
                  (legacyIp?.isNotEmpty ?? false) ||
                  (legacyName?.isNotEmpty ?? false))) {
            cameras.add(CameraProfile(
              ssid: legacySsid ?? '',
              ip: legacyIp ?? '',
              name: legacyName ?? '',
              password: raw['apPassword'] as String? ?? '',
            ));
            lastUsedSsid = cameras.first.ssid;
          }
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
          'schemaVersion': schemaVersion,
          'downloadVariant': downloadVariant,
          'deleteAfterDownload': deleteAfterDownload,
          'sortMode': sortMode,
          'viewerQuality': viewerQuality,
          'viewerSaveOriginal': viewerSaveOriginal,
          'afAreaScale': afAreaScale,
          'linkRawJpegPairs': linkRawJpegPairs,
          'lastCameraSsid': lastCameraSsid,
          'lastCameraIp': lastCameraIp,
          'lastCameraName': lastCameraName,
          'autoConnectWifi': autoConnectWifi,
          'autoConnectUsb': autoConnectUsb,
          'cameras': cameras.map((c) => c.toJson()).toList(),
          'lastUsedSsid': lastUsedSsid,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}

/// 一台相机的连接档案。
///
/// 做成**列表**而不是单个字段：用户不只连自己的相机，也会连别人的，
/// 每台的热点名/密码/上次地址都不同，逐个记下来才能都做到"一键重连"。
class CameraProfile {
  CameraProfile({
    this.serial = '',
    this.ssid = '',
    this.ssidDerived = false,
    this.password = '',
    this.name = '',
    this.ip = '',
    this.sta = false,
  });

  /// **相机自身的序列号**（PTP `GetDeviceInfo` 的 serialNumber）。
  ///
  /// 这是"同一台相机"的**唯一可靠身份**：Wi-Fi 与数据线两条链路的序列号完全相同，
  /// 而热点名只在 Wi-Fi 时有、USB 名字（productName，如 `Z50_2_8046907`）
  /// 与 PTP 上报的相机名（如 `Z50II`）又不一样——靠它们归并必然得到两条记录
  /// （真机反馈："无线连接和 USB 连接会在 App 上保存两条相机名称"）。
  String serial;

  /// 相机热点名（AP 模式用）。STA 模式接同一路由器时可为空。
  ///
  /// 可能是**推定值**（见 [ssidDerived]）：这台 ROM 上 Wi-Fi 侧读不到热点名，
  /// 只能用相机自身上报的数据推。
  String ssid;

  /// [ssid] 是否由推导得来（而非从系统读到/用户输入）。
  ///
  /// 推定值要显式告诉用户（副标题标"（推定）"），并且在**一次成功入网后清掉**——
  /// 那时它已被现实证实。
  bool ssidDerived;

  /// 相机热点密码。**可以为空**——空表示"用系统里已保存的凭据连"，
  /// 用户第一次在系统设置里连过该热点后就不必再输密码。
  String password;

  /// 相机名（连接成功后由 PTP/IP 握手得到，如 "Z50II"）
  String name;

  /// 上次连上的地址（Wi-Fi 时是相机在热点里的 IP）
  String ip;

  /// true = 相机接入手机所在的同一个路由器（STA 模式），手机不需要切热点
  bool sta;

  /// 列表里显示的名字
  String get label => name.isNotEmpty ? name : (ssid.isNotEmpty ? ssid : '未命名相机');

  /// 副标题：说清"这台相机怎么接"。
  ///
  /// `usb` = 连接页此刻处在 USB 模式。这时**必须完全不提"热点"**——
  /// 本页同时管 Wi-Fi 与数据线，在 USB 模式下满屏"热点"会让用户以为
  /// 这里只支持热点连接（真机反馈：USB 模式下列表里还有热点字眼）。
  String subtitleFor({required bool usb}) {
    if (usb) {
      return ssid.isEmpty
          ? '数据线直连（插上线后点「连接」）'
          : '数据线直连 · 热点名也记着（$ssid）';
    }
    if (sta) {
      return ssid.isEmpty ? 'Wi-Fi · 同一路由器（STA）' : 'Wi-Fi · 同一路由器（STA · $ssid）';
    }
    if (ssid.isEmpty) {
      return ip.isEmpty
          ? '还没记录热点名 · 补一次后就能一键连接'
          : '还没记录热点名（上次在 $ip）· 补一次后就能一键连接';
    }
    final tail = ssidDerived ? '（推定，与相机屏幕核对一下）' : '';
    // 未存密码时**不承诺**"用系统已保存的密码"——免密 specifier 请求的是开放网络，
    // 与 WPA2 热点不匹配（真机实测），实际会走"填一次密码 / 系统面板手点"的兜底。
    return password.isEmpty
        ? 'Wi-Fi · 相机热点 $ssid$tail · 未存密码'
        : 'Wi-Fi · 相机热点 $ssid$tail';
  }

  /// 兼容旧调用点（按 Wi-Fi 模式渲染）
  String get subtitle => subtitleFor(usb: false);

  /// 是否可用"一键加入热点"（AP 模式且知道热点名）
  bool get canAutoJoin => !sta && ssid.isNotEmpty;

  /// **由相机自身上报的数据推定它的自建热点名**（拿不到返回 null）。
  ///
  /// 实测（Nikon Z50II，两条链路都验过）：相机通过 PTP 报出
  /// `cameraName = Z50_2_8046907`、`serialNumber = ...08046907`，
  /// 而它在空口上广播的 SSID 正是 `NIKON_Z50_2_46907` ——
  /// 即 `NIKON_` + 型号前缀 + `_` + 序列号末 5 位。
  ///
  /// 为什么必须靠推导：这台 ROM 上 `getSSID()` 恒为 `<unknown ssid>`、
  /// `startScan()` 返回 false、`configuredNetworks` 为空（权限已授予也如此），
  /// Wi-Fi 侧根本拿不到热点名；**相机自己报的数据反而最可靠**。
  ///
  /// ⚠️ 这是**推定值**：用户可以在相机里改热点名，固件也可能换规则。
  /// 所以调用方要把它标成 [ssidDerived]，UI 上标"（推定）"，
  /// 并在一次成功入网后清掉该标记（那时已被现实证实）。
  ///
  /// 数字尾巴可能来自**名字**（Wi-Fi 链路报 `Z50_2_8046907`）也可能只有
  /// **序列号**里有（USB 链路报 `Z50_2`）——两处都找，谁先有就先用谁。
  /// 门槛取 5 位以上：型号里的 `_2`（`Z50_2`）不是序列号尾巴，别剥掉
  /// （写测试时正是被这一条抓出来的）。
  static String? deriveApSsid({String? cameraName, String? serial}) {
    final name = (cameraName ?? '').trim();
    if (name.isEmpty) return null;
    var prefix = name;
    String? digits;
    final inName = RegExp(r'_(\d{5,})$').firstMatch(name);
    if (inName != null) {
      prefix = name.substring(0, inName.start);
      digits = inName.group(1);
    }
    digits ??= RegExp(r'\d{5,}$').firstMatch((serial ?? '').trim())?.group(0);
    if (prefix.isEmpty || digits == null) return null;
    return 'NIKON_${prefix}_${digits.substring(digits.length - 5)}';
  }

  Map<String, dynamic> toJson() => {
        'serial': serial,
        'ssid': ssid,
        'ssidDerived': ssidDerived,
        'password': password,
        'name': name,
        'ip': ip,
        'sta': sta,
      };

  factory CameraProfile.fromJson(Map<String, dynamic> m) => CameraProfile(
        serial: (m['serial'] as String?) ?? '',
        ssid: (m['ssid'] as String?) ?? '',
        ssidDerived: (m['ssidDerived'] as bool?) ?? false,
        password: (m['password'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        ip: (m['ip'] as String?) ?? '',
        sta: (m['sta'] as bool?) ?? false,
      );
}
