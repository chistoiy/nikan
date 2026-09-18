# AI 开发交接文档（HANDOFF）

> 本文档面向接手本项目的 AI/开发者。读完即可继续开发，无需重新摸索。
> 最后更新：2026-09-15 · 版本状态：M2 稳定；USB（U1）与遥控页增强已开发完成，**待真机验证**

---

## 1. 一句话现状

尼康 Z50 II 照片传输 App（Flutter UI + Kotlin PTP 引擎，仅 Android）。Wi-Fi 主链路稳定。**USB 传输层（U1）已完成开发**：实测吞吐 27.1 MB/s（Wi-Fi 的 11 倍），`PtpSession` 接口抽取让 Wi-Fi/USB 双传输层共用全部上层逻辑。**遥控页增强已完成开发**：取景窗点击对焦、档位识别（M/A/S/P）、按档位联动参数编辑（不可改置灰）、参数实时刷新。**待真机验证**（清单见 §18.4）；Wi-Fi 方言的档位属性码待「属性码Dump」探针确认。

## 2. 核心链路（必须先理解）

> **2026-09-15 起为双传输层架构**：`PtpSession` 接口（PtpSession.kt）抽象了上层全部依赖
> （transact / transactShort / transactWithDataOut / getObjectToStream / getThumbnailBytes /
> connect / close / notifyLinkDead / 两个回调）。`PtpIpClient`（Wi-Fi）与 `PtpUsbClient`（USB）
> 各实现一份；`CameraEngine.client` 字段类型即 `PtpSession`，枚举/下载/遥控/保活完全共用。
> 语义约定：**非 OK 响应码一律抛 `PtpException`**（上层按码处理，如 0xA004 未对焦）；
> 传输故障抛 `IOException`（USB 侧内部先走重枚举恢复，恢复失败才判死）。

### 2.1 Wi-Fi 主链路（原有内容，仍然有效）

```
相机(Z50 II) ──Wi-Fi AP 热点──> 手机
  相机 = 网关(192.168.1.1)，监听 TCP 15740 = PTP/IP 服务
  App 握手时伪装尼康官方 App(WMU) 的固定 GUID → 相机视为已配对主机，
  放行完整操作集（126 操作 / 26 事件，实测确认）
```

- **协议层**：`PtpIpClient.kt` 双 TCP 通道（命令+事件），事务串行（一把锁）。
- **关键结论：PTP 命令通道同一时刻只能跑一个事务**，所有并发设计都要基于"串行+优先级队列"。
- **生产路径**：连接用 `connectSmart()`（直接对网关握手+重试，禁止先裸 TCP 扫描——会触发相机端"连接失败"状态）。

## 3. 构建与环境（有坑）

```bash
# 必须带这个镜像变量（清华镜像缺 Flutter 引擎 Maven 构件，会构建失败）
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn flutter build apk --debug
# 或直接双击项目根目录 build_apk.bat / build_apk.sh
# 产物：build/app/outputs/flutter-apk/app-debug.apk
# 安装：adb install -r <apk>（手机需开 USB 调试；小米会拦 adb input 注入，UI 自动化用 uiautomator 工具）
```

⚠️ **versionCode 陷阱**：pubspec.yaml 当前是 `1.0.1+2040`（基号 2040）。手机上装的是
带 `--build-number` 的 release 包；直接 `flutter build apk` 产出的包 versionCode=1，
会被系统以 `INSTALL_FAILED_VERSION_DOWNGRADE` 拒绝。**分 ABI 包还会再叠加 ABI 偏移
（见下面「发版 / 建 Release」）**。

装机用这条（release、同签名、versionCode 递增，升级安装保留应用数据）：
```bash
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
  flutter build apk --release --target-platform android-arm64 --build-number <递增数字>
adb install -r build/app/outputs/flutter-apk/app-release.apk
# 测试机：小米 23127PN0CC（houji，arm64-v8a）
```

不要用 `adb install -r` 装 debug 包覆盖 release 包：debug 用 debug keystore 签名，
与 release 签名不一致会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`；卸载重装则会清空
应用数据（下载去重记录 nikonsync_downloads.json 与设置）。

### 发版 / 建 Release（2026-09-16 定，1.0.1 起照此执行）

`gh` 已安装并登录（账号 `chistoiy`），但**不在 Git Bash 的 PATH 里**，用绝对路径：

```bash
GH="/c/Program Files/GitHub CLI/gh.exe"

# 1) 改版本号（pubspec.yaml 的 version: <名>+<基号>），再打三个分 ABI 包
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
  flutter build apk --release --split-per-abi --build-number <基号>
cp -f build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  dist/NikonSync-v<名>-arm64.apk
cp -f build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk dist/NikonSync-v<名>-arm32.apk
cp -f build/app/outputs/flutter-apk/app-x86_64-release.apk      dist/NikonSync-v<名>-x86_64.apk

# 2) 核对（必做）：versionName 必须是新版本，versionCode 必须高于上一版对应 ABI
AAPT=/d/app_workplace/android_studio_sdk/build-tools/36.1.0/aapt2.exe
"$AAPT" dump badging dist/NikonSync-v<名>-arm64.apk | grep -E "^package:|^native-code:"

# 3) 提交 + 打标签 + 推送
git commit ... && git push origin main
git tag -a <名> -m "..." && git push origin <名>

# 4) 建 Release（dist/ 被 gitignore，APK 只能走 Release 附件）
"$GH" release create <名> --title "版本 <名>" --notes-file .workbuddy/release-body-<名>.md \
  --latest --verify-tag dist/NikonSync-v<名>-arm64.apk dist/NikonSync-v<名>-arm32.apk dist/NikonSync-v<名>-x86_64.apk
"$GH" release list   # 确认已置 Latest
```

⚠️ **两个坑**（1.0.1 实际踩到）：
1. **分 ABI 包只能用 `--split-per-abi`**。`--target-platform android-arm,android-x64` 打的是
   一个通用包，而 `build/app/outputs/flutter-apk/` 里**残留上一版的 per-ABI 文件**——
   照名字 `cp` 会把**旧版本包**拷进 dist（1.0.1 时差点把 1.0.0 的 arm32 传上去）。
   所以第 2 步的 aapt2 核对不能省。
2. **versionCode 会被 Flutter 叠加 ABI 偏移 ×1000**：基号 2040 → arm64 **4040** / arm32 **3040** /
   x86_64 **6040**。1.0.0 的对应值是 2001 / 1001 / 4001。新版基号必须让三个值都高于旧版，
   否则老包会被 `INSTALL_FAILED_VERSION_DOWNGRADE` 拒绝。

Release 正文模板见 `.workbuddy/release-body-1.0.1.md`（本机文件，未入库；结构：亮点 → 本版更新 →
修复表 → 下载表 → 使用方法 → 已知限制 → 验证 → 开源）。

- Flutter 3.38.9 / Dart 3.10.8 / Java 21 / minSdk 29 / 仅 Android
- 依赖：path_provider、exif（EXIF 解析）。状态管理用 ChangeNotifier（AppModel 单例，无第三方状态库）

## 4. 目录与关键文件

| 文件 | 职责 |
|---|---|
| `android/.../Ptp.kt` | 协议常量（包类型/操作码/事件码/格式码/WMU GUID）|
| `android/.../PtpWire.kt` | 报文编解码 + PTP 数据集读取器（ByteReader）|
| `android/.../PtpDatasets.kt` | DeviceInfo/ObjectInfo 解析 |
| `android/.../PtpIpClient.kt` | **核心**：握手/事务/分块下载（模式自动协商）/事件读取/断线通知 |
| `android/.../CameraEngine.kt` | 引擎单例：连接/枚举/下载/遥控/保活/SAF/MediaStore/探针 |
| `android/.../NikonsyncPlugin.kt` | 通道桥接（MethodChannel+EventChannel+SAF 结果）|
| `android/.../KeepAliveService.kt` | 后台保活前台服务（WifiLock+WakeLock）|
| `lib/app_model.dart` | 全局状态：连接/文件/索引/下载/设置；**原生事件唯一订阅者** |
| `lib/engine/camera_gateway.dart` | 请求串行调度（可见优先>后台索引）、缩略图缓存、下载记录 |
| `lib/engine/thumb_cache.dart` / `record_store.dart` / `settings_store.dart` | 缓存/去重记录/设置持久化 |
| `lib/engine/app_log.dart` | **全局日志缓冲**（300 条环形，通知 300ms 节流防 UI 重建风暴，错误上报防递归；UI 只渲染最近 120 条，复制为全量）|
| `lib/pages/*.dart` | connect/gallery/downloads/remote/settings/debug/viewer/local_viewer |
| `docs/技术方案.md` | 总体方案（M0~M4 规划）|
| `docs/reference/` | aero-shutter 参考源码 + WMU 功能审计文档（逆向线索库）|

### 4.1 2026-09-15 新增文件

- `PtpSession.kt`——传输层接口 + `TransactResult` + `DlMode`（含 data-OUT 事务）
- `PtpUsbClient.kt`——PTP/USB 传输层：整包读 + 余料缓冲、事务串行、重枚举恢复
  （等设备重现 10s + 重新授权）、GetObject 流式下载（64KB 块）、断点续传
  （GetPartialObject）、中断端点事件线程
- `PtpUsbProbe.kt`——U0 实验探针（调试面板入口），大量经验已迁移进 PtpUsbClient

## 5. 协议硬知识（全部踩坑验证过，勿再踩）

1. **握手**：InitCommandRequest 用 WMU 固定 GUID `00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF` + 友好名（UTF-16LE），事件连接用 InitCommandAck 返回的连接号绑定，必须先于 OpenSession。
2. **枚举是目录式的**：`GetObjectHandles(storage, fmt, parent=0xFFFFFFFF)` 只返回根（DCIM 文件夹句柄 0x11004000），必须拿句柄逐层下钻。区分目录/文件用格式 0x3001 查询做集合差（该机格式过滤有效，但保留探测回退）。
3. **0x101B = 标准 GetPartialObject，参数 3 个**（句柄、偏移 u32、最大长度 u32）。⚠️ 发 4 个参数（64 位偏移）会报 ParameterNotSupported——这是历史上下载失败的根因。
4. **0x1012 是 SetObjectProtection（写保护），不是分块下载**，绝不能用于下载。
5. **缩略图**：0x90C4（尼康大缩略图，该机可用）→ 失败回退 0x100A。
6. **事件**：标准事件 socket 收得到 DevicePropChanged，**收不到 ObjectAdded/CaptureComplete**（该模式下的实测行为）。拍摄相关事件疑似走厂商队列 0x90C1/0x90C0（排水已实现，解析格式待日志确认）。
7. **实时取景 0x9200 被拒**（OperationNotSupported）：0x92xx 在能力清单里但智能设备 Wi-Fi 模式下封禁（至少 0x9200 实测被拒）。WMU 的取景是完整子系统（见 `docs/reference/wmu_audit.md` Live View 章节），新一代操作码大概率在 0x95xx 段，需逆向。
8. **DevicePropDesc 数据集**：`[码u16][类型u16][GetSet u8][出厂默认值][当前值][表单标志]`——读当前值必须先跳过默认值（历史上参数显示错乱的根因）。
9. **遥控快门 0x100E**：空参可用；首拍成功、后续 DeviceBusy(0x2019)/GeneralError(0x2002)——**未解决，见第 7 节**。忙重试已加：CheckEvent 排水 + AF 驱动探测（0x90C3→0x9206 自适应）+ DeviceReady，窗口 25 秒。
10. **SDRAM 假说**：拍后相机可能把照片挂在固定句柄 **0xFFFF0001** 等主机取走，不取走快门持续被拒。忙重试第 6 次起探测该句柄并转发 objectAdded 事件（待真机验证）。
11. **高速下载**：0x9400~0x9406 三参数形态探测，**输出必须与 0x101B 逐字节一致才启用**（防下到坏文件），结果写日志。当前实测 2.4G AP 模式 ~2.4MB/s 已接近物理上限；建议用户检查相机端 5GHz 频段。
12. **权限坑**：WifiLock 需要 `WAKE_LOCK` 权限（曾致闪退，已修 + 服务内 runCatching 防御）。
13. **连接流程**：禁止裸 TCP 探测相机端口（会触发相机"连接失败"并拒绝后续握手）。`connectSmart()` = 网关直握手 → 失败重试一次 → 才做网段扫描兜底。

## 6. 已验证功能（真机通过）

Wi-Fi 智能直连（免配对）、快速枚举（1499 文件 256ms）、文件详情按需加载、缩略图网格+两级缓存、三档画质下载（原图/8M/2M，手机端缩放，仅 JPEG）、分块下载+降级链、SAF 自定义目录、MediaStore 落盘、下载去重、日期分组、滑动范围多选（锚点→当前，边缘自动滚动）、大图查看（翻页/缩放/EXIF）、手机页批量删除、能力清单 dump、盲拍遥控（首拍成功）、电量/保活/断线检测、全局错误捕获（堆栈进日志面板）。

**USB（2026-09-15 实测）**：PTP/USB 全链路——GetDeviceInfo/枚举/GetObjectInfo 1-2ms 一笔；
**GetObject 全量下载 174MB MOV 实测 27.1 MB/s，字节校验一致**（Wi-Fi 的 11 倍，30GB 卡约 19 分钟）。
活跃传输期间连接保持住；恢复机制（等设备重现+重授权+重试）实战验证可用。

## 7. 未解决问题与排查方向（2026-09-16 复核重写）

> ⚠️ 本节此前混着"**已经解决但没删**"的条目（实时取景、属性码），照它去排查会重复劳动。
> 下面每条都标了当前状态；带 ✅ 的只留结论，不要再开发。

### 7.0 USB 空闲期重枚举循环（已缓解，根因待除）
- 相机空闲时每 ~3.65s 从手机总线消失、~3.4s 后重挂（dumpsys `num_connects=661`，严格周期）。
- **活跃传输期间连接保持住**（174MB/7s 中途未断），恢复机制可兜底非活跃期。
- 判别已做：相机插电脑稳定（相机/线排除）、屏幕常亮无影响、上传优先/拍摄优先无差异
  → 收敛到手机侧 OTG 供电或 MTP 主机栈。**决定性实验：带外供电 OTG 集线器（约 20-30 元）**。
- 详见 docs/USB连接方案.md §7.2/§7.5。

### 7.0b ✅ 已解决：属性码映射（原文说的"尼康裁剪方言"是**错的**）

**以代码为准**：`CameraEngine.kt` 的 `PropDialect`（约 L1804-1825，注释里带真机证据）。

| 属性码 | 含义 | 实测特征 |
|---|---|---|
| `0x5007` | **光圈** | 只读，值 = 级数×100（170→f/1.7 … 1600→f/16）|
| `0x500D` | **快门** | 可写，值 = 1/10000 秒（3333 → 1/3s）|
| `0x500E` | **档位** ExposureProgramMode | 1=M 2=P 3=A 4=S；厂商扩展 32784=AUTO / 32792=SCN |
| `0x500F` | **ISO** | 可写，枚举 100…51200 |
| `0x5010` | 曝光补偿 | 1/1000 EV |

原文写的 `0x500D=光圈、0x500E=快门` 会把快门值当光圈显示成 "f/33.3"、把档位值当快门——
**这就是"参数显示错乱"的真根因**。属性写入走 `0x1016 SetDevicePropValue`（参数=属性码，数据=只有值）。

### 7.1 ⏳ 遥控拍摄第二张起持续忙碌（已实现解锁方案，待连拍验证）
- 现象：首拍成功（AF 驱动 0x90C3 可用、ObjectAdded 正常到达标准事件通道），**第二张起持续 DeviceBusy/GeneralError**，与拍摄模式无关。
- 已排除：事件队列排水（0x90C1/0x90C0 被相机直接拒绝，无响应）、模式切换影响、AF 缺失（0x90C3 拍前对焦有效）。
- **当前主假设（证据最强）**：相机要求主机把新照片"取走"（GetObject 全量读取）后才允许下一次快门——SnapBridge 每拍必拉的正是这个。已实现：拍后自动全量读取新照片（≤40MB，读走即解锁，同时用作高清预览）。待真机验证连拍是否恢复。
- 其他假设：厂商传输队列（0x9407/0x9408 该机不存在，新代等价物未知）；0xA004 OutOfFocus 响应码已识别（未对焦时快门被拒会返回它，已做即时终止+提示）。
- 若全量读取后仍卡忙：尝试 GetLargeThumb 读取是否足够解锁；再不行考虑 0x920A SDRAM 拍摄流程。

### 7.2 ✅ 已解决：实时取景

- `0x9201` 启动 / `0x9202` 结束 / `0x9203` 取帧 **全部可用**，点画面指定对焦 `0x9205` 可用。
  （原文"0x9200 被拒"说的是 **0x9200** 这个码本身，取景并不用它——别因此认为取景不可做。）
- 对焦倍数**自动解出**，不需要人工标定：取景帧头部 384B（大端 u16）里 `off 8/10` = 取景帧尺寸、
  `off 12/14` = 相机图像尺寸，倍数 = 后者 ÷ 前者，**x/y 各算一次**（Z50 II 实测 8.70 / 8.755）。
  实现见 `CameraEngine.parseLvHeader` / `afScaleFromHeader`，详见 §28。
- 遗留问题只有一条：**相机待机（屏幕灭）后取景通道失效**，见 §7.3。

### 7.3 ⛔ 结论已定：相机息屏后遥控失效（App 侧无法解决）

- 探针实测（2026-09-15 23:13）：`0xD064 MonitorOff` / `0xD062 MeterOff` / `0xD066 AutoOffTimers` /
  `0xD0B3 MonitorOffDelay` **全部"不支持"**——Z50 II 在 Wi-Fi 智能设备模式下不暴露任何息屏/待机属性，
  App 改不了。`0x90C8 DeviceReady` 4ms 就应答，但**点不亮屏幕**；"每 15 秒戳一次协议活动"实测也无效。
- **不要再试"从 App 唤醒相机"这条路**（已试遍）。App 侧能做的只有三件，且都已落地：
  1. 待机判定（`DeviceReady` 失败 / 重进取景失败即判待机）→ 故障卡片直接说"相机可能已进入待机"；
  2. 给出路：按相机按钮 / **相机菜单 → 自定义设定菜单 → c3「电源关闭延迟」调长** / 改用盲拍；
  3. 参数读取连续失败即提前预警（顶部横幅）。
- **注意**：待机时盲拍**同样拍不了**（`0x100E` 会连续回 DeviceBusy 直到预算耗尽），
  且表象与"未对焦"一模一样。历史上写过"盲拍不依赖取景、待机时仍可用"——那是错的，已更正。

### 7.4 ⏸ 用户同意搁置：Auto ISO 实时值

- 现象：相机屏幕显示 `ISO AUTO 2500` 时，属性 `0x500F` 读到 2000。
- 差分探针（调试面板「实时ISO」，5 次 ×8 秒）结果：`0x500F` 恒为 200；厂商段只读出 15/23；
  8 秒内唯一变化的是 `0x5007`（光圈 100→170）与 **`0x5008`（0→5600，可疑，标准 PTP 里它是焦距但
  该镜头应为 2400）**。
- 未定位"承载实时 ISO 的属性"。**用户已同意先不追**。三个探针入口保留着（「实时ISO」「取景头部」
  「读一次参数」），将来想追随时可接着查。

### 7.5 复制日志崩溃（未定位，保留全局捕获）
- 已加全局错误捕获：`FlutterError.onError` / `ErrorWidget.builder` / `PlatformDispatcher.onError` → 堆栈写入 AppLog → 用户复制日志即可反馈堆栈。
- 复现路径：设置页 → 长按日志选择复制。日志卡片已有明确"复制全部日志"按钮。

### 7.6 ✅ 已解决：Wi-Fi 方言的档位联动 / 属性 Dump

原 §7.4「待装机验证」与 §7.0b 的探针任务都已完成：属性码与档位码已确认（见 §7.0b 的表），
遥控页档位联动与参数编辑已真机验证可用。**不要再跑"属性码Dump"探针了。**

### 7.7 ⛔ 结论已定：无线下载速度没有可挖的空间（2026-09-16 研究）

完整报告见 **`docs/无线下载提速研究.md`**。要点（**别再重复研究**）：

- 真机日志 `速率 54 Mbps` 是决定性证据：**54 只属于 802.11g**（11n 在 20MHz 下是
  6.5/13/…/65/72.2，不含 54）→ 相机自建热点按 11g 工作 → **TCP 实际上限约 2.5~3.1MB/s**，
  实测 1.5~2.4MB/s 已达上限的 50~95%。**协议层没有可挖空间。**
- App 侧已查尽且都已到位：收 4MB/发 1MB 缓冲（在 connect 前设置）、`TCP_NODELAY`、
  keepAlive、WifiLock=`FULL_LOW_LATENCY`、分块 4MB（往返开销可忽略）。
- **并行请求不可行**：PTP/IP 单命令通道 + 相机同时只接受一个会话（释放窗口可达 3 分钟）。
- **0x94xx 不是卡内文件的高速通道**，那是 SDRAM（取景缓冲）语义。
- **唯一有量级意义的杠杆是 5GHz**：Z50II 规格含 **802.11a/ac**、5180–5825 MHz，
  5GHz EIRP 9.5 dBm（2.4GHz 仅 3.8 dBm）。但 AP 模式只跑 11g，要用 5GHz 必须让相机走
  尼康菜单的 **`Wi-Fi连接(STA mode)`**（相机加入用户路由器），手机连同一 5GHz SSID。
  ⚠️ 路由器**客户端隔离**会让手机与相机互相不可见（现象是"未发现相机"）。
- 新增仪器：调试面板「**无线测速**」探针（真传一遍但丢弃数据，报吞吐/频段/协商速率并判读）；
  链路日志已带频段。

## 8. UI 结构速查

- `HomeShell`（main.dart）：底部双 Tab——相机(ConnectPage) / 手机(DownloadsPage)，IndexedStack。
- ConnectPage：引导+智能连接；已连接面板有 浏览照片/遥控拍摄/断开；右上齿轮→SettingsPage（含嵌入式 DebugPanel）。
- GalleryPage：3 列网格、按需加载、类型/文件夹筛选、四种排序、长按滑动范围多选、右下圈选可点、底栏下载(画质切换)。
- 滑动选择算法：**锚点→当前索引连续范围**（微信式），行号 = (滚动偏移+局部y)/行高——勿删偏移项。
- DownloadsPage：日期分组（CustomScrollView+SliverMainAxisGroup 式分组）、命中测试式滑动选择（GlobalKey 表）、批量删除。

> 📄 **滑动选择的完整规则、验收清单与已知坑已单独成文：
> `docs/相册滑动选择-需求与实现方案.md`。** 要在别的页面复用、或改动选择相关逻辑时**先看它**——
> 本文档这一节只留一句概括，避免两处规则不同步。
>
> **跨项目复用版**收录在方案库 **`D:\dev_workplace\developSummary`**
> （GitHub：`chistoiy/developSummary`，见 `mobile/flutter-gallery-drag-selection.md`），
> 已去掉本项目专属措辞。规则以**方案库那份为准**，改规则时两边都同步。

## 9. 测试要求

- 真机：Z50 II（固件 1.02，DeviceId "Z50_2"）+ 小米手机（23127PN0CC，MIUI）。
- 相机路径：MENU → 扳手 → 连接至智能设备 → Wi-Fi 连接 → 建立连接（屏幕显示 SSID/密码）→ 手机连该热点。
- 相机热点无互联网：App 已做 socket 绑定 Wi-Fi 网络，蜂窝不受影响。
- MIUI 注意：会杀后台（有前台服务对抗）、拦 adb input（UI 自动化用 uiautomator 而非 `input tap`）。
- 日志获取：设置页 → 协议验证面板 → 复制全部日志（App 启动即记录，无需先进面板）。

## 10. 给下一个 AI 的工作流建议

1. 读本文档 + `docs/技术方案.md` + **`docs/代码审查与功能建议-2026-09-15.md`**
   （2026-09-15 全量代码审查：10 条未记录的问题 + 10 条功能建议，含文件行号）；
   跑 `flutter analyze`（应 0 error）与构建。
2. 任何协议改动先在 DebugPanel 加/用探针拿真机证据，**不要盲试厂商操作码**（有副作用风险，如 0x920A 会真拍照）。
3. 改完构建安装 → 用户真机验证 → 让用户复制日志反馈（日志含完整协议过程）。
4. 提交前跑 `flutter analyze`，保持 0 error/warning（info 级风格提示可容忍）。

## 11. 待办队列（2026-09-16 重排）

> 原队列里混着大量**已经做完**的条目（U1 验证、属性码 Dump、实时取景调测、提交等），
> 照它排期会重复劳动。已完成的移到「已完成」区，只作为"这些别再做了"的凭据保留。

### 已完成（勿重复劳动）

- [x] 连接稳定性第一轮（§19）：超时不再必然作废连接、迟到响应清理、事务号自检、保活事件驱动、自动重连
- [x] U1 + 遥控页真机验证：USB 连接/相册/下载/续传（27.1 MB/s）、Wi-Fi 遥控 AF 点选、参数编辑、档位显示
- [x] 属性码 Dump → 属性方言与档位码已确认（§7.0b）
- [x] 实时取景（Wi-Fi）已调通，对焦倍数改为**自动解出**（§7.2）
- [x] 参数写入真根因修复（PTP/IP 数据外发报文格式）+ 真机验证生效
- [x] RAW+JPEG 成对识别与联动下载（含 10 项单测）
- [x] 1.0.1 发布：提交、推送、标签 `1.0.1`、GitHub Release 三个分 ABI 附件
- [x] 2026-09-16 项目体检：18 项历史审查条目逐条复核（`docs/体检报告-2026-09-16.md`）
- [x] 2026-09-16 批次一/二/三修复：缩放丢 EXIF 方向、USB 下载持锁与真取消、索引通知条件、
      构建脚本、内存压力回收、死代码、权限与 USB 接入处理

### 待办（按建议顺序）

- [ ] **USB 空闲期重枚举根因**：带外供电 OTG 集线器实验（§7.0）
- [ ] **遥控连拍第二张**：拍后全量读取解锁已实现，待连拍真机验证（§7.1）
- [ ] **下载进度通知栏**：前台服务与通知权限都已就绪，只差 UI
- [ ] **USB 下载断点信息持久化**：目前中断会删半成品，无法跨次续传
- [ ] **UI 主题系统（白天/深色）**：设计稿 `docs/UI设计稿-2026-09-15.html` 已完成，
      落地要把写死的颜色字面量抽成语义令牌（约 15 个文件），建议单独一轮
- [ ] **体检报告里的中低优先级项**：拖动选择的命中测试优化（B5，需改成布局感知结构才有收益）、
      相册排序语义统一（B3）、待下载数量文案（B4）、设置键改 schemaVersion 迁移（N3）
- [ ] M3 候选：自动同步（ObjectAdded 已具备）、Wi-Fi 自动回连、筛选摘要行

### 已明确不做 / 不可为（省得再试）

- 相机息屏从 App 唤醒（§7.3）· Auto ISO 实时值（§7.4，用户搁置）
- RAW 转 JPEG（相机端拍 JPEG 或相机内转换即可）


---

## 12. 阶段 0 加固记录（2026-09-14，待真机验证）

本轮只做数据正确性与崩溃防护，未新增功能、未改协议行为。9 个文件 +417/−208。

### 已修的静默故障

| 问题 | 位置 | 影响 |
|---|---|---|
| 下载字节数不校验 | `PtpIpClient.getObjectToStream` 返回值 + `CameraEngine.download` | 此前用**请求的** size 上报成功：分块少传会静默截断，且被写进下载记录永久跳过。现在逐块比对声明长度与实际写入量，结束再校验总量，不等即抛错 → 自动降级整文件重试 |
| 降级条件漏 IOException | `CameraEngine.download` catch | 分块提前结束抛的是 IOException 而非 PtpException，"该降级却降不了"。现在任何异常都触发一次降级重试 |
| 包长度无上限 | `PtpWire.readPacket` | 损坏的长度会造成 2GB 分配或负长度。加 `MAX_PACKET_BYTES` 上限 |
| 数据集数组长度无上限 | `PtpWire.ByteReader.countOf` | 同上，按剩余字节数校验元素个数 |
| 事件线程抓不住 Error | `PtpIpClient.startEventReader` | 改为 `catch (t: Throwable)`。否则 OOM 逃逸 → 线程静默死亡 → UI 停在"已连接"却永远收不到事件 |
| 握手失败泄漏 socket | `PtpIpClient.connect/abortConnectLocked` + `CameraEngine.connect` | 上层会重试多次，泄漏会占满相机连接槽位 |
| 旧会话死亡回调污染新连接 | `CameraEngine.connect` | 回调内 `client === c` 判定归属；同时把 `client = c` 提到装回调之前，消除"握手刚完成就断线"的漏报窗口 |
| build 期原地排序全局列表 | `gallery_page.dart` `_filtered` | 默认筛选下直接排序 `model.files` 本体。改为始终复制 + 按通知失效的缓存 |
| 查看器索引与列表不一致 | `local_viewer_page.dart` | PageView 用过滤后列表、删除用未过滤列表索引 → 可能删错照片。统一为 `_visible` 单一来源 |

### 性能与交互

- `AppModel` 增加 150ms 通知节流（后台索引原本每完成一个文件就全量重建所有页面，1500 张 = 1500 次）
- `settings_page` 的 `DebugPanel` 固化为常量实例：外层 AnimatedBuilder 重建时 Flutter 按同一实例跳过 build，不再每次通知重建 677 行面板
- 缩略图/详情失败计数（上限 3 次）+ `needsLoad()` 前置判断，消除"失败即每次重建重发请求"的风暴；`loadFiles()` 时清零
- 滑动多选自动滚动：改用全局坐标换算行号（原来把局部坐标当全局用，边缘滚动时反复选中第 0 行），方向实时跟随手指
- 全选判定与切换改用同一集合（原来文案看 `_filtered.length`、切换看 `_selected.length`，含被筛掉句柄时永远无法"取消全选"）；模型变化时剪枝 `_selected`
- `downloads_page` 删除流程补 mounted 防护（逐个 await 期间返回上一页会 setState after dispose）

### 真机验证清单（按优先级）

1. **下载完整性**：连相机下载单张 JPEG / NEF / 视频各一，日志应出现 `下载完成：xxx（N 字节…）`。若出现 `传输不完整：期望 X 字节，实际收到 Y 字节`，说明该机型的 ObjectInfo size 与实际传输量存在系统性差异——把日志发回，据此把校验放宽为"不小于"或改用 StartData 的 total。
2. **降级链**：上述任一文件若走到 `改用整文件下载重试` 后成功，即为降级链生效。
3. **断线重连**：下载过程中让相机休眠/断电，应立刻出现"连接已断开"而不是等 30s，重连后不应出现假 disconnected，也不应再出现 `忽略非当前会话的断线通知` 之外的多余状态跳变。
4. **缩略图**：浏览大量照片时不再出现相机忙（请求风暴消失）；无缩略图的文件最多请求 3 次后停在占位图。
5. **滑动多选**：长按后拖到网格上/下边缘，应持续按手指所在行向后选中，手指移回中间方向立即反转。
6. **选择一致性**：勾选若干张后切换筛选条件，"已选 N"应自动剔除被筛掉的句柄，全选按钮文案与实际动作一致。
7. **本机查看器删除**：连续删除多张，删的应是当前显示的那张；删除最后一张应自动退出。

---

## 13. 阶段 1 架构收敛（2026-09-14，纯内部整理，不改外部行为）

目标是不改功能地消除重复与拆分大文件。analyze 达到 **No issues found**（此前有 2 条 info）。

### 新增的公共设施

| 文件 | 作用 |
|---|---|
| `lib/pages/widgets/drag_selection.dart` | **滑动多选状态机**（长按起选/锚点范围/边缘自动滚动）。两个页面此前各写一套，已在坐标换算上分叉出一个 bug；现在差异只有两处注入：`keyAt`（主键类型）+ `indexAt`（屏幕坐标→索引） |
| `lib/pages/widgets/app_widgets.dart` | `kAccent`（品牌色，原 13 处字面量）、`AppCard`、`EmptyState`、`DisconnectedView` |
| `lib/models/exif_summary.dart` | EXIF 摘要解析（两个查看器此前各一份，键名还不一致） |
| `lib/util/format.dart` | `formatBytes`（原 3 份实现） |

### 文件拆分

| 原文件 | 现状 |
|---|---|
| `pages/debug_page.dart` 677 行 | → `pages/debug/debug_page.dart`(612) + `debug_log_card.dart`(95) + `capability_sheet.dart`(73)。9 个探针包装方法 + 15 个按钮**收敛成一张 `_Probe` 表**；破坏性探针（会实拍）加了 `destructive` 标记 + 二次确认弹窗，此前与只读探针外观一致，误触会往用户卡里拍照 |
| `pages/gallery_page.dart` 729 行 | → `gallery_page.dart`(404) + `widgets/gallery_cell.dart` + `gallery_filter_bar.dart` + `gallery_status_bars.dart` + `gallery_options_sheet.dart` |
| `pages/downloads_page.dart` 406 行 | → 324 行（接入 DragSelection）。新增 `_entries` 缓存：`records.all` 每次调用都重排序，而拖动选择会高频读取它 |

### 顺带修掉的两处

- `RecordStore` 改为 `ChangeNotifier`，`AppModel` 转发其通知。此前删除记录不触发任何通知，本机查看器删完返回手机页仍显示旧条目（要等下一次引擎通知才刷新）。
- 相册页改筛选条件时把选择集收敛到新列表上，避免"已选 N"包含看不见的条目。

### 已完成（2026-09-14）

`CameraEngine.kt` 拆分为 **1164 行 + `CameraProbes.kt` 443 行**。探针段（9 个探针 +
`jpegDims` + `attempt_marker`，共 11 个函数）整体移出，`CameraEngine` 只留 9 行门面转发，
`NikonsyncPlugin` 的调用点无需改动。

**放宽为 `internal` 的成员**（共 4 个）：`client`、`need()`、`indexOfSoi()`、
`liveViewOn` 的 setter（原为 `private set`）。

**两个坑，第二次做时别再踩：**

1. **不能按行号范围一把切**。探针之间夹着三块**非探针**代码，一刀切会把事件排水机制一起搬走：
   - `drainCheckEvents` / `parseCheckEvents`（厂商事件队列排水，保活与拍摄路径在用）
   - `ptpValue` / `propDescCurrent` / `isManualFocus` / `afDriveBlocking` / `afDrive` / `shotParams`（对焦辅助与参数读取）
   正确边界是 `probeLvAf`(929–949) 与探针块(1068–1473) 两段，中间 951–1067 全部留在原地。
2. **`liveViewOn` 的 getter 公开但 setter 是 `private set`**。探针会写它（收尾时置 false），
   只放宽 getter 不够——编译器会明确报"it is private in CameraEngine"，照它改即可。

教训：这类搬迁靠"grep 函数名 + 猜行号"很容易错（我第一次就把范围划成了 928–996，
恰好吞掉整个排水机制）。**可靠做法是先把区间内所有 `fun` 定义列出来逐个判断归属**，
再动手；编译器能兜住引用错误，但兜不住"多搬了不该搬的东西"。

---

## 16. 对焦优先机型（未对焦不释放快门）的处理策略（2026-09-14）

### 用户现象

相机设为「未对焦时禁止拍摄」后，遥控点拍摄 → **长时间等待 → 多次重试 → 报异常**。

### 根因：重试循环本身在帮倒忙

原来的 `capture()` 在收到"忙"之后**每 500ms 重新按一次快门**，连试 25 秒。而对焦优先机型的行为是：

```
按下快门 → 相机开始 AF 搜索 → 返回 DeviceBusy
   ↑                                    │
   └────── 反复按快门会打断并重启 AF ──────┘
```

于是对焦**永远等不到稳定**，一直忙到 25 秒超时，最后抛出的却是
"相机持续忙碌，无法拍摄"——与真实原因（对焦没锁上）毫无关系。
用户既等得久，又拿不到可行动的结论。

另一个缺位：`afDriveBlocking()` 名字叫 blocking，但**只代表"AF 指令被接受"，
不代表"对焦已完成"**。镜头随后还要跑几百毫秒到几秒去合焦，而代码发完 AF 就立刻按快门。

注意区分：`0xA004`（OutOfFocus）那条分支原本就是**立即中止**的，
所以"长时间等待"一定发生在"忙"这条路径上。

### 处理策略（已实现）

先驱动 AF → **留出合焦时间** → 再按一次快门 → 忙则长间隔有限次重试 → 尽快给出真实结论。

| 措施 | 取值 / 做法 |
|---|---|
| 按快门前先驱动 AF 并等合焦 | `AF_SETTLE_MS = 1200ms`；`isManualFocus()` 为 MF 时跳过（手动对焦机型相机不检查对焦） |
| 忙重试改为**长间隔** | `BUSY_RETRY_MS = 1500ms`（原 500ms）。这是本次最关键的一处：短间隔会不断打断 AF |
| 忙等总预算大幅缩短 | `CAPTURE_BUDGET_MS = 8s`（原盲拍 25s / 取景 20s）。8s 足够覆盖一次正常合焦 |
| 失败时的结论要有信息量 | 抽出 `FOCUS_PRIORITY_HINT` 常量：说明原因 + 四条处理办法（对准有对比的目标 / 先用「对焦」按钮 / 相机改释放优先 a1·a2 → 选「释放」/ 切 MF） |
| 阶段上报 | 新增 `emitPhase()` → `capturePhase` 事件（af / shutter / done），遥控页把阶段显示在快门下方：**"正在对焦…（对焦优先机型需合焦才会释放快门）"** |
| 失败提示展示更久 | SnackBar 时长 8s（菜单路径较长，默认时长看不完） |
| 恢复路径相应前移 | SDRAM 待取图像探测由第 6 次改为第 2 次、退出取景恢复由第 8 次改为第 3 次——因为重试间隔变长，次数必须重新分配才落得进 8s 预算 |

`capture()` 与 `lvCapture()` 采用同一策略。

### 待真机验证

- 对焦优先开启、且对准**低对比目标**时：应在 ~8s 内给出带四条处理办法的提示（而非 25s 后一句"忙碌"）
- 对准**正常目标**时：应能一次成功，且等待期间显示"正在对焦…"
- 需要确认长间隔重试是否真的让合焦得以完成——若相机在 AF 期间对 0x100E 的响应不是 DeviceBusy
  而是长时间无响应，则超时会命中 §15 的"流失同步"路径，需要改用先探测对焦状态再拍的方式

### 未做（需要协议证据）

更彻底的做法是**读相机的对焦锁定状态**，在确认合焦后再按快门，而不是靠"试着拍"来判断。
当前不清楚该机型用哪个属性暴露合焦指示（0x500A 只是 AF/MF 模式，不是锁定状态）。
若上面第三点验证不通过，下一步应探针扫描厂商属性段找对焦状态位。


---

## 14. 遥控页取景与回看改造（2026-09-14，待真机验证）

用户反馈的六条里有两条是**显示缺陷**而非布局偏好，另有一条与布局问题同源。

### 关键关系：两个抱怨其实是一个

实测取景画面只占 265dp 高，而可用区有 559dp——`Center` 把横向画面居中，上下各空 147dp（就是第 12 节记的那 152dp 死区）。根因是**横向出片 + 竖持手机**：3:2 画面在竖屏里必然只能占满宽度。所以修好旋转（竖构图）之后，"取景框太小、浪费屏幕"随之消失，不需要单独"把框做大"。

### 已改（不依赖真机证据的部分）

| 改动 | 位置 |
|---|---|
| 盲拍回看去掉写死的 `width: 260`，改为铺满可用区 + 点击全屏（复用 `ZoomableImage`）+ 信息条（文件名/大小/像素/参数）+ "存到手机"直达 | `remote_page.dart` |
| 取景画面填满：`Stack(fit: StackFit.expand)` + `BoxFit.contain` | 同上 |
| 帧率三处浪费：`Timer.periodic(60ms)` → 自调度循环（拉完立刻发下一帧）；按显示尺寸 `cacheWidth` 解码；画面用 `ValueNotifier` 隔离重建（不再每帧 setState 整页）；画面角落显示实测 fps | 同上 |
| 拍摄参数加有效性区间，越界显示 `--`（实测出现过物理上不存在的 f/0.6） | 同上 |
| 模式切换改 SegmentedButton；"拍后自动下载"改 Switch；快门按钮加"拍摄"文字与 Semantics；全屏取景模式 | 同上 |
| EXIF Orientation 自动旋转（取景与回看各自独立）+ 手动旋转（点击循环 0/90/180/270，长按恢复自动） | `lib/util/jpeg_exif.dart` + `remote_page.dart` |
| 单元测试 10 条：大小端 TIFF、缺标签、截断、长度字段损坏、ICC、色彩空间、interop ASCII | `test/jpeg_exif_test.dart` |

### ⚠️ 改这一页时不要省掉那次原图读取

`remote_page.dart` 的 `_onNewPhoto` 里 `model.gateway.viewBytes(f)` 同时承担两件事：高清回看、以及**取走新照片以解锁下一次快门**（第 7.1 节的核心假设）。它现在两用，去掉会让遥控连拍退回卡忙。

### 待真机取证：旋转与色彩

诊断已内置在**正常使用路径**上，不需要进调试面板点探针——打开实时取景就会在日志面板留下：

```
取景帧诊断：73KB 1600×1064 orientation=6 colorSpace=sRGB interop=R03 ICC=无
回看照片诊断：…
```

判读方式：

- `orientation=6/8` → 帧里带了方向标记，自动旋转应生效。**若画面方向仍不对，说明解析或旋转量反了**，把日志发回。
- `orientation=无` → 帧里没有方向标记，自动旋转不可能生效。只能依赖手动旋转按钮，或去逆向厂商的方向属性。
- `interop=R03` 或 `colorSpace` 非 sRGB → 基本可以断定画面发闷是**色彩空间标记被解码端忽略**；`ICC=有` 说明还带 ICC 配置文件（Flutter 同样忽略）。两种情况都建议先确认相机端色彩空间设置，再决定是否需要应用侧做色域变换。

这两条都要**先拿证据再改**，不要凭猜（第 10 节的规矩）。旋转与色彩的取证顺带共用同一次解析。

### 真机取证结论（2026-09-14，Z50 II 固件 1.02）

```
取景帧诊断：33KB 640×424 orientation=无 colorSpace=无 interop=无 ICC=无
回看照片诊断：124KB 640×424 orientation=无 colorSpace=无 interop=无 ICC=无
```

**结论一：取景帧不带任何 EXIF 元信息 → 自动旋转对该机型不可能生效。**

没有 Orientation 标记，就没有可依赖的方向来源。相机自己的 LCD 能转正，靠的是机身方向传感器，
不是帧里的标记。因此**手动旋转是这台机器上的唯一正解**（已实现：取景画面左下角 `⟳ 旋转` 按钮，
点击循环、长按恢复自动）。自动识别逻辑保留着——换机型时若帧里带标记，它会自己生效。

**结论二："色彩空间标记被忽略"的假设被推翻。**

帧里 `colorSpace / interop / ICC` 全为「无」，没有任何色彩信息可供忽略。
画面观感差异的真正来源是**取景流的规格本身**：640×424、33KB。
而实测取景显示区约 1200 物理像素宽——等于把 640 宽的图放大近 2 倍显示，
加上 33KB 的强压缩（色度二次采样损失大），自然又糊又闷。
相机 LCD 上看到的是套用优化校准（Picture Control）与主动 D-Lighting 之后的渲染结果，
与这条预览流本就不是同一个东西。

**结论三：帧率上限远高于此前观测。**

`18:51:56.332` 发启动指令 → `18:51:56.353` 收到首帧，**整个往返 21ms**。
此前记录的 5–10fps 主要来自本侧（60ms 定时器量化 + 1500ms 超时 + 每帧整页重建）。
改掉这三处后实测 **16–24 fps**。

**结论四：相机主动推送我们显示的拍摄参数。**

日志里的 `DevicePropChanged 20487/20493/20494/20495` 换算为
`0x5007`(焦距) `0x500D`(光圈) `0x500E`(快门) `0x500F`(ISO)——正是界面显示的那几个。
标准事件通道**收得到** DevicePropChanged（第 5 节注 6 已记），而目前 App 只处理 ObjectAdded，
参数是轮询来的。改成事件驱动可以让参数随拨轮实时更新。
⚠️ 权衡：`shotParams` 一次要 4 个 PTP 事务，与取景帧循环共用同一条串行通道，
高频刷新会压低帧率，需要节流（建议 ≥2s）或仅在盲拍模式下刷新。

### 新增探针：取景帧尺寸（`试验:取景帧尺寸`）

在取景状态下逐个尝试候选帧通道（0x9203/0x9403/0x9202/0x9204/0x9205/0x9209，
**只含已验证的只读取帧操作**），报告字节数与 JPEG 像素尺寸。

用来定论"是否存在更大的取景帧"：若全部返回 640×424，说明这是相机在智能设备 Wi-Fi
模式下的硬上限，不必再追；若某通道返回更大尺寸，那就是清晰度与色彩观感的一次性改善机会。

### 日志刷屏已修

相机每秒推 1~3 次 DevicePropChanged，且多个属性码交替出现（连续重复折叠无效），
逐条记日志会在两分钟内刷满 300 条环形缓冲，把真正有用的协议日志挤掉。
现在在 `PtpIpClient` 侧按属性码聚合，最多每 2 秒汇总输出一行：

```
属性变化：0x5007×12 0x500D×3 0x500F×2
```

### 待查：一次 30 秒读超时导致的掉线

```
18:51:19.438  连接失效：Read timed out
18:51:25.293  连接 192.168.1.1 第 1 次失败：Connection reset
18:51:27.327  连接 192.168.1.1 第 2 次失败：socket EOF
18:51:29.748  扫描完成：未发现相机
```

主要怀疑单事务通道上的资源争抢：取景帧循环与保活探针（每 5 秒一次 DeviceReady）
共用一把事务锁，某次请求卡住时保活排在其后等到 30 秒超时，随后被判定链路已死。
与帧率属同一块问题，建议帧率稳定后再复现观察。

---

## 15. 事务超时导致流错位 → 断连（2026-09-14，已修，待真机复验）

### 现象（用户实测）

设置页连相机 → 点「试验:取景帧尺寸」→ 回主页用实时取景（16~31fps）→ 返回主页时
**相机取景窗关闭、屏幕熄灭，随后相机关闭热点、连接断开**。

### 根因：事务超时后命令流永久错位，且从未实现"恢复"

`transactShort` 的注释里早就写了这个隐患——"超时若发生在分包中间会破坏流框架，
调用方需容忍随后可能的重连"——**但全项目没有任何地方实现重连或流重建**。于是形成这条链：

1. 取景帧请求用的是 `transactShort(0x9203, 1500)`；
2. 某次请求超时 → TCP 流里残留半个包，**之后每个事务都解析错位**；
3. 错位状态下保活探针 `DeviceReady` 用 30 秒超时的事务读不到合法响应 →
   **30 秒后判"Read timed out"→ 断开**。第 14 节记的那次掉线就是这一幕；
4. 相机侧看到主机长时间不响应，退出智能设备模式、关闭热点。

**注意第 2 步的性质**：错位之后不是"报错"，而是**静默的错误结果**——比断开危险得多。

### 本轮改动加重了触发概率（已一并修正）

第 14 节把 `Timer.periodic(60ms)` 换成自调度循环，去掉了固定节拍。好处是消掉空转，
但请求速率从此完全跟着响应走：相机产出速率跟不上时请求会排队，**超时概率反而上升**，
而这个探针又恰好包含未知码、会踩到这条链。

### 修复

| # | 改动 | 位置 |
|---|---|---|
| 1 | **事务超时即作废连接**：`doTransactLocked` 捕获 `SocketTimeoutException` → 置 `streamDesynced`、写清日志、触发断线回调、抛出明确异常。此后所有事务一律拒绝，不再在错位的流上继续跑 | `PtpIpClient` |
| 2 | 重连时复位该标记 | `PtpIpClient.connect` |
| 3 | 取帧循环加**最小间隔 20ms**：恢复节流，避免把相机逼到超时 | `remote_page.dart` |
| 4 | 取帧循环在连接失效时**立即退出**：否则每次调用都立即抛异常，循环变成空转 | `remote_page.dart` |
| 5 | 帧请求超时 1500 → **3000ms**：既然一次超时就会作废连接，不能因取景热身期单帧慢而误杀 | `CameraEngine.liveViewFrame` |
| 6 | **探针收窄并加固**：只保留 `0x9203` / `0x9403`（有实测证据的只读取帧通道）；启动取景失败**不再被 `runCatching` 吞掉**（吞掉会在未知状态下继续发指令）；`finally` 里保证关闭取景；结果写日志 | `CameraEngine.probeLvFrames` |

第 6 条里我犯过一个错，记下来避免重犯：初版探针把 `0x9204/0x9205/0x9209` 也当成
"已验证的只读操作"放进去了，**但本项目审计里明确标注过 0x9204 属"未知码"**。
往相机发语义未知的操作码，与本项目"先取证再动"的规矩相悖。

### 复验要点

打开实时取景 → 正常出帧 → **返回上一页** → 观察：
- 日志应出现 `实时取景已关闭`，且**不应**出现 `命令通道读超时`
- 相机屏幕应回到拍摄界面（不熄灭）、热点保持、App 仍是已连接状态
- 若出现 `命令通道读超时（操作 0x9203）：流已失同步`，说明帧请求仍在超时，
  需要把 `_minFrameGapMs` 再调大，或查明相机为何不返回帧

### 遗留

- 连接因超时作废后，App 目前只提示断开、需要手动重连。可考虑加一次自动重连
  （`connectSmart` 已具备重试能力），但要注意相机侧需要时间从异常状态恢复。
- 根因是"超时无法安全恢复"。理论上可以在超时后扫描 SOI/包长度做流重同步，
  但 TCP 上半包位置无法可靠推断，性价比低；现有做法（明确作废 + 重连）更稳妥。


---

## 17. USB U0：源码研读 + 读缓冲修复（2026-09-14，待复测）

**成果：定位并修复了一个一直存在的自伤 bug——之前 GetDeviceInfo"被相机稳定拒绝"
的结论是错的，真因是探针用 12 字节缓冲读 USB 容器头。**

USB 是包式协议：数据相位第一个包是完整 512B 高速整包，12 字节的 URB 装不下 →
EOVERFLOW 丢包且不给 ACK → 设备永远重发同一包。这统一解释了全部旧现象：
12 字节响应（OpenSession/CloseSession）秒回、数据阶段颗粒无收、"瞬间 -1"、
1.8s 后的 0x2007（相机放弃后回的错误响应）。详见 `docs/USB连接方案.md` §7.3/§8。

本轮做的事：

1. **克隆参考源码**（`docs/reference/`，gitignored）：libmtp 全量、libgphoto2 全量
   （浅克隆大仓库会报 fetch-pack 错，重试可过；curl zip 在本机网络不通）。
2. **研读事务层**：`libgphoto2/camlibs/ptp2/usb.c`、`libmtp/src/libusb1-glue.c`、
   `gphoto2_port/libusb1/libusb1.c`。关键结论整理成 USB连接方案.md §8 的表：
   首包按 maxPacket 整包读、超时 20s、ZLP 补零、错误分类后才允许清一次 halt、
   Android 上单次读 ≤16KB（AOSP MtpDevice 注释）。
3. **修复 `PtpUsbProbe.kt`**：`readFully` 改为"缓冲 ≥ maxPacket 整包读 + inLeftover
   余料缓冲（跨容器背靠背到达的字节不丢）"，`drainInput` 同时清余料。
   编译通过（`flutter build apk --debug`）。
4. **记录构建环境坑**：本机 `FLUTTER_STORAGE_BASE_URL` 指向清华镜像，缺当前引擎的
   `flutter_embedding_debug` jar（404，构建挂在 `:jni` 依赖解析）。构建时覆盖
   `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` 即可。

教训（值得记住的推理错误）：九轮真机排查都把矛头指向相机/系统，没有早一步对照
业界实现逐行审自己的读写路径。"12 字节头在 TCP 上没问题"掩盖了"在 USB 上根本收不到数据"。
**协议排障时，先逐行核对参考实现的读写原语，再怀疑对端。**

下一步（按 USB连接方案.md §7.5 顺序）：① 相机复测 USB 探测看 GetDeviceInfo 能否
收到完整 DeviceInfo；② 相机插电脑判别重枚举归属；③ 关相机「USB 供电」再测。

### 17.1 复测结果（2026-09-15）：读缓冲修复验证通过，协议层全通

修复版（versionCode 2027，pubspec 版本号因工作区曾回退到 +1 而提到 2027）装机复测：

- OpenSession → SessionAlreadyOpen（沿用残留会话）
- **GetDeviceInfo 完整收到并解析**：Nikon Corporation Z50_2 vV1.02、
  操作集 126、事件集 26、0x92xx 段 12 个操作——§7.3 卡点正式消除
- 探测全程未被打断，无重枚举痕迹——§7.2 的"相机等不到主机 ACK"推断得到支持，
  但待长会话（整卡下载）继续观察
- 唯一没跑成的是测速：**存储卡为空**。卡里放入照片（JPEG+NEF）再跑探测即可拿到
  GetObject 吞吐数字，那是 U1 决策的最后一块证据

（装机插曲：手机上原装 versionCode 2026 来自一次未提交的 pubspec 本地改动，
工作区清理后回到 +1，直装报 INSTALL_FAILED_VERSION_DOWNGRADE；pubspec 提到
+2027 后正常。）


### 17.2 第二天战报（2026-09-15 凌晨）：代码链路全通，只剩环境在杀连接

四轮真机日志（logcat 全量，比卡片摘要多出命令级细节）把问题逐层剥完：

1. **01:24** 读缓冲修复验证通过（§17.1）。
2. **01:36** 发现"有照片却报卡空"的第二个 bug：GetObjectHandles 只列根目录，
   根下只有 DCIM 文件夹（size=0），照片在子目录——`findBiggestObject` 改为
   沿关联对象（format=0x3001）递归。又发现第三个 bug：174MB 视频的数据容器头
   len=174MB+12 被 MAX_PAYLOAD(64MB) 误杀——上限应把守在分配点（readPayload）
   而不是容器头校验。两处修复后：**GetObject 被相机接受、数据相位开始**。
3. **01:52** 设备 12 秒后从总线**消失**（VID/PID 都找不到，不是换址）。
4. **01:59** 恢复机制实战通过：等设备重现→重新授权→继续；其中一轮
   **GetObject 接受、数据相位第一个包（12B 头+500B 数据）到手后相机静默 3s**。

**结论：协议与代码层已 100% 打通（含 174MB 大文件数据相位），唯一卡点是
连接在传输中被环境杀掉。** 三个待排除的环境因素，按成本排序：

- MIUI 熄屏后 USB autosuspend（测试时保持屏幕常亮 + 给 App 关电池优化）
- 相机「USB 供电」设置（尼康系已知该设置会致数据不稳）
- com.android.mtp 主机栈干扰（无 root 挡不住，只能靠证据确认）

本轮代码改动（`PtpUsbProbe.kt`/`PtpDatasets.kt`，均已编译+装机）：
- findBiggestObject 递归目录 + 失败原因上卡片 + 走 commandRecovering
- 容器头校验去掉 64MB 上限；readPayload 把守分配上限；payloadLen 改 Long
- readFully 的 URB 尺寸取整到 maxPacket 整数倍（尾部溢出隐患）
- reopenAfterEnumeration：轮询等待设备重现 10s + 主动请求授权
- timedDownload：GetObject 发送失败自动重开重试 ×3；中断时已收 >1MB
  则按部分数据报告速度
- 附：pubspec 版本号提到 1.0.0+2027（此前 2026 是未提交的本地改动）


### 17.3 结案（2026-09-15 凌晨）：U0 完成，实测 27.1 MB/s

判别测试全部落地：相机插电脑稳定（相机/线排除）、屏幕常亮无影响（熄屏挂起排除）、
上传优先/拍摄优先无差异（相机状态机排除）。随后一次探测跑通全链路：

**GetObject 全量下载 174MB 的 DSC_3825.MOV，实测 27.1 MB/s，字节校验一致
（JPEG/MP4 特征验证 + 与 ObjectInfo 声明长度一致）。** Wi-Fi 2.4 → 27.1 MB/s，11 倍。

dumpsys usb 实锤空闲态重枚举循环仍在：host_manager `num_connects=661`，
严格周期断 3.4s / 挂 3.65s；**活跃传输期间连接保持住**（7 秒下载未中断），
循环定性为空闲态行为。恢复机制（等待重现 10s + 重新授权 + GetObject 重试）
在此前的轮次里已实战验证可用。

**U0 至此结案，方案进入 U1（传输层产品化）。** 详细结论已写入
`docs/USB连接方案.md` §1/§6/§7.5。U1 设计要点：把"中断续传"当一等公民；
并行验证带外供电 OTG 集线器能否根除空闲循环（大概率与 OTG 供电管理有关）。

---

## 18. U1 传输层产品化 + 遥控页增强（2026-09-15，已开发完成，待真机验证）

### 18.1 U1：双传输层架构（已构建，USB 全流程待用户验证）

- **`PtpSession` 接口**：CameraEngine 依赖面抽象。`client` 字段、`need()`、
  `describeCamera`、`readHandles/getObjectInfo/propDescCurrent/afDriveBlocking` 全部改型。
  `DlMode`/`TransactResult` 迁到接口层（PtpIpClient 内保留 typealias 兼容旧引用）。
- **`PtpIpClient`（Wi-Fi）**：实现接口 + 新增 `transactWithDataOut`
  （data-OUT 帧：OperationRequest(dataPhase=2) → StartData(total) → Data(offset+data)… → EndData(offset)）。
  ⚠️ doTransact 增加第 4 参后，**所有调用点的尾随 lambda 必须写成显式实参**，
  否则 lambda 会绑到 dataOut 上（已全部改掉，新代码注意）。
- **`PtpUsbClient`（USB）**：U0 全部经验产品化（详见 USB连接方案.md §7/§8）——
  整包读 + 余料、事务串行 + 单调事务号、恢复（等重现 10s + 重授权 + 重试一次）、
  GetObject 流式下载（64KB 块 + 1MiB 步进进度）、**断点续传**（中断后重开 +
  GetPartialObject 从断点续传，4GB 内有效，响应参数与实际写入量必须一致）、
  中断端点事件线程（0x83 轮询 300ms，事件容器跨包拼接 + 余料）。
- **语义对齐**：非 OK 响应抛 `PtpException`（不触发 USB 重枚举恢复——相机明确拒绝不是传输故障）；
  传输 IOException 才走恢复。保活的 `notifyLinkDead` 提升到接口。
- **入口**：`CameraEngine.connectUsb()`（cameraIp="usb://机型"）→ 插件 `connectUsb` →
  连接页「USB 数据线连接（高速下载，实测 27 MB/s）」按钮。
- **方言码表**：`CameraEngine.PropDialect`——USB 用标准 PTP
  （fNumber=0x5006 / exposureTime=0x500C / iso=0x5007 / mode=0x500D），
  Wi-Fi 用实测方言（0x500D/0x500E/0x500F，mode 待探针确认填入）。

### 18.2 遥控页增强（同批构建）

- **参数描述符**：`shotParams()` 升级——每参数返回
  `{code, dtype, writable, value, values[](枚举表), range[min,max,step]}`，
  完整解析 GetDevicePropDesc 的 FormFlag。**注意 Dart 侧取值改为 `desc['value']`**。
- **参数设置**：`setShotParam(name, value)` → SetDevicePropDesc（data-OUT，按 dtype 编码），
  设置后立即回读返回新描述符（UI 即时回显真值）；相机拒绝（档位限制）抛 PtpException 由 UI 提示。
- **档位联动置灰**（Dart `_paramEditable`）：M=全部可改，A=仅光圈，S=仅快门，P/AUTO/未知=只读；
  叠加属性的 writable 标志。规则只是引导，相机是最终裁判。
- **UI**：参数行 = 档位 chip + 三个参数 chip（蓝框=可编辑、灰=只读）+ 电量；
  点 chip 弹枚举列表或 ±步进器；**取景画面点击任意位置 = AF**（原"对焦"按钮保留）。
- **调试面板新增「属性码Dump」探针**（probeProps）：0x5001-0x5017 + 0xD100-0xD11F
  全量 GetDevicePropDesc dump——Wi-Fi 档位码确认后填入 PropDialect 即完成闭环。

### 18.3 本轮踩坑记录（新代码注意）

1. doTransact 尾随 lambda 绑定陷阱（见 18.1）。
2. `r.u8()` 返回 Int，when 分支不能写 `1L`。
3. putU16 的 value 是 Int、putU32 是 Long（CameraEngine setShotParam 编码时注意）。
4. PtpWire 补了 `putU64`（PTP/IP StartData 的总长字段）。
5. pubspec 版本 1.0.0+2027（此前 2026 是未提交的本地改动，工作区曾回退到 +1 导致
   INSTALL_FAILED_VERSION_DOWNGRADE）。构建必须带
   `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（§3）。

### 18.4 待真机验证清单（用户操作）

**USB 流程**（相机 USB 连手机 → 连接页点「USB 数据线连接」→ 弹窗允许）：
1. 连接成功、相册缩略图加载（走 USB 缩略图通道）；
2. 下载照片/视频（大文件优先——中断续传只有在真被重枚举打断时才触发）；
3. 若报"传输不完整"= 续传版未装（旧版行为），换装最新包再测。

**Wi-Fi 遥控页**：
4. 实时取景中**点击画面** → 相机 AF 动作；
5. 转相机拨盘 P/A/S/M → 档位 chip 与置灰联动（⚠️ Wi-Fi 档位码未确认前，档位 chip 可能显示 "--"，
   属预期）；USB 连接下档位识别应直接工作（标准码）；
6. A 档改光圈 / M 档改 ISO → 生效且回显；P 档点参数 → 置灰不可点；
7. 调试面板跑「**属性码Dump**」→ 把输出发回来 → 填入 PropDialect.mode 完成最后闭环。

**全部通过后提交**（当前未提交内容：PtpSession/PtpUsbClient/两传输层 data-OUT/CameraEngine
接入/遥控页 UI/断点续传/调试探针/本文档更新）。

---

## 19. 第二轮：取景对焦 + 连接稳定性（2026-09-15 晚）

### 19.1 用户反馈与日志给出的两条线索

| 现象 | 日志证据 |
|---|---|
| 无线连接后，取景中**点击画面不生效**，提示"对焦失败或不支持"（相机在 AUTO 档） | `18:12:08 AF 驱动 0x90C3 被拒绝，跳过` |
| 空闲一段时间后**相机热点没关、手机 Wi-Fi 也正常，App 却显示断开**；再点连接报"未发现相机"，几分钟后才恢复 | `18:14:55 实时取景已关闭` → `18:15:00 命令通道读超时（操作 0x9201）` → `18:15:08/10 连接失败：Connection reset` → `18:15:12 扫描完成：未发现相机` → `18:18:06` 才握手成功 |

### 19.2 根因

**A. 取景对焦失败：用错了操作码**

1. `0x90C3` **不是尼康的 AF Drive**。`docs/reference/wmu_audit.md` 的 Remote Capture 表里，
   **AF Drive = 0x9125**（WMU ✅，aero-shutter 的两个客户端 ❌）——0x90C3 是社区猜出来的码。
   取景态被拒是必然结果。
2. 更早版本还有第二个 bug（上一轮已修）：AF 失败会写进 `afDriveOp = -1` **永久缓存**，
   一次失败就毒化整个会话的 AF。
3. **AUTO / 场景自动档下对焦由相机接管**，"点画面即对焦"本身就不会有动作。
   只回一句"对焦失败或不支持"是不可行动的——必须把档位与 MF 这两条讲清楚。

**B. 连接掉线：一次超时 = 整条连接作废 + 相机三分钟不认新连接**

时间线还原（关键在最后一步）：

```
18:14:55  实时取景已关闭
18:15:00  命令通道读超时（操作 0x9201）→ 流已失同步 → 连接作废
18:15:03  属性变化：0x500E×1        ← 事件通道仍然活着！
18:15:08  开始握手 → 第 1 次失败：Connection reset
18:15:10  开始握手 → 第 2 次失败：Connection reset → 扫描 254 个地址 → 未发现相机
18:16:05  属性变化：0x500C…          ← 事件通道还活着
18:18:06  握手成功                    ← 相机会话自己释放后才放行，窗口约 3 分钟
```

1. **`doTransactLocked` 无法区分"超时在包边界"与"半个包留在流里"**，于是任何超时都按
   "流已错位"处理 → 作废连接。而 0x9201 / 0x9203（取景帧）/ 各探针**全部是短超时事务**，
   取景一热身就踩中。这是本次断线链的起点。
2. **相机仍持有上一个会话**：PTP/IP 同一时刻只允许一台主机，在相机自己释放之前，
   对 15740 的每一次新连接都被 RST。原自动重连 3 次共 17.5 秒，**必然撞在窗口内**；
   而"扫描 254 个地址"在这种状态下毫无意义，只会给出与真实原因无关的"未发现相机"。
3. 保活探针**单次失败即判死**，空闲期误报"断开"的概率不低。

### 19.3 本轮修复

| # | 改动 | 位置 |
|---|---|---|
| 1 | **超时不再必然作废连接**：新增 `PacketTimeoutException(partialBytes)` 与 `PtpWire.readPacketTracked`。`partialBytes == 0` = 超时落在**包边界** → 放弃这笔事务、记下事务号、**保留连接**；`> 0`（半个包）才作废并触发断线回调 | `PtpWire.kt` / `PtpIpClient.kt` |
| 2 | **迟到响应的清理与归属**：下一笔事务开始前 `drainAbandonedLocked` 读掉上一笔的迟到响应（预算 1.2s，等不到就继续）；运行时用**事务号校验**丢弃不匹配的 OperationResponse。两道保险合起来，既不把别人的响应当自己的，也不为一次慢应答把连接判死 | `PtpIpClient.kt` |
| 3 | **事务号回显自检**：首次响应即判定相机是否回显事务号，写进日志。不回显时（理论上的旧固件）自动退回"超时即作废"的老行为，**不引入新风险** | `PtpIpClient.kt` |
| 4 | **`liveViewStart` 不再吞异常**：两次尝试都失败就抛出真实原因；`liveViewOn` 只在成功时置位。原实现失败也返回 ok，导致遥控页永远停在"等待取景画面…" | `CameraEngine.kt` |
| 5 | **保活改为事件驱动 + 一次失败不判死**：相机空闲也在推 DevicePropChanged（事件即存活证据），8 秒内有事件就不发探针（顺带减少取景期的事务争抢）；探针失败先复探一次，复探也失败才判死 | `CameraEngine.kt` |
| 6 | **自动重连拉长到覆盖相机释放窗口**：退避 2/4/8/15/20/30/30/30/30 秒（累计约 2.8 分钟，实测窗口约 3 分钟）；期间上报 `{attempt, total, nextInMs}`；**失败后保留 cameraIp**，用户再点一次「连接相机」直接打已知地址 | `CameraEngine.kt` / `app_model.dart` |
| 7 | **连接失败给可行动的结论**：失败原因是 `Connection reset`/`socket EOF` 时**跳过 254 地址扫描**（注定白等），直接提示"相机还在释放上一个会话，请等 30 秒~3 分钟" | `CameraEngine.kt` |
| 8 | **AF 操作码按证据排序**：取景态优先 `0x9125`（WMU 的 AF Drive，新增常量 `OP_NIKON_AF_DRIVE`），盲拍先 `0x90C3`；失败原因（含响应码名）返回给 UI，并附档位/MF 的处理办法 | `CameraEngine.kt` / `Ptp.kt` / `remote_page.dart` |
| 9 | **对焦状态可见**：对焦指令在途时取景画面显示"AF 对焦中…"、控制条按钮转圈。AF 在途没有画面变化，没有提示用户会以为点击没生效 | `remote_page.dart` |
| 10 | **重连进度可见**：连接页出现重连进度卡片（第 N/M 次 + 倒计时 + 为什么会被相机拒绝）；相册页/遥控页的占位文案区分"主动连接中"与"自动重连中" | `connect_page.dart` / `app_model.dart` |

### 19.4 复验要点（用户操作）

**连接稳定性**（本次主线）
1. 连上后**让相机空闲 5~10 分钟**（不进取景、不拍照）：不应再出现"断开连接相机"；
   若断线，应看到「正在自动重连（第 N/9 次）」并自行恢复，而不是立刻报错。
2. 复现旧故障路径：进实时取景 → 退出 → 再进（制造一次 0x9201 慢应答）。日志里应出现
   `命令通道读超时（操作 0x9201）：超时在包边界，放弃该事务、连接保留`，
   随后 `已清理上一笔超时事务（0x…）的迟到响应`，**而不是** `流已失同步，连接作废`。
3. 若仍出现"未发现相机"：新日志会给出 `跳过网段扫描：相机仍在释放上一个会话`，
   说明自动重连 9 次（约 2.8 分钟）没覆盖住 —— 把日志发回，我据此再加长或改为监听式重试。

**取景对焦**
4. 取景中点画面：应看到"AF 对焦中…"，然后画面合焦。日志 `AF 驱动 0x9125 记录为可用`。
5. 若仍失败，日志会是 `AF 驱动 0x9125 被拒：PTP xxxx: 操作 0x9125` —— **把这个响应码发回**：
   - `OperationNotSupported` → 该机型的 AF Drive 需要先进入某种遥控/拍摄模式（WMU 有
     Remote Mode Start），下一步按这个方向找码；
   - `ParameterNotSupported` / `InvalidParameter` → 参数形态问题，探针里加参数组合试；
   - `NotLiveView` → 要先确保取景已真正启动（当前 0x9201 成功但帧未到也可能算未启动）。
6. AUTO 档下若相机接管对焦，界面会明确提示"切到 P/A/S/M 再试"，属预期行为。

### 19.5 本轮涉及文件

`Ptp.kt`（+AF Drive 常量）、`PtpWire.kt`（PacketTimeoutException / readPacketTracked）、
`PtpIpClient.kt`（超时恢复 + 迟到响应清理 + 事务号自检）、`CameraEngine.kt`（保活 / 自动重连 /
connectSmart / liveViewStart / AF）、`app_model.dart`（重连状态）、`nikon_engine.dart`（afDrive 返回原因）、
`remote_page.dart`（对焦反馈）、`connect_page.dart`（重连卡片）、`gallery_page.dart`（文案）。

---

## 20. 第三轮：厂商操作码全面校正 + 属性方言纠正（2026-09-15 晚）

### 20.1 起因：两份真机证据

1. **点击取景框对焦失败**的提示是 `PTP ParameterNotSupported: 操作 0x90C3`
   —— `ParameterNotSupported` 的含义是"操作**认识**，但参数不对"，而不是"不支持该操作"。
   这是第一个决定性线索。
2. **「属性码Dump」26 组输出**（见 §20.3）——第一次拿到全部属性的类型/当前值/枚举表。

### 20.2 操作码错配表（按 libgphoto2 `ptp.h` 尼康段校正）

`docs/reference/libgphoto2/camlibs/ptp2/ptp.h` 的尼康段**逐个码都带参数个数注释**，是本次的权威依据。
错配的后果不是"报错"而是"做了别的事"，很难从现象反推：

| 码 | 本项目此前认为 | **实际（libgphoto2 ptp.h）** | 造成的后果 |
|---|---|---|---|
| `0x90C1` | CheckEvent 事件排水 | **AfDrive（无参数）** | 每次保活/拍摄都在**驱动对焦**（排水从未发生） |
| `0x90C2` | DeviceReady 保活 | ChangeCameraMode（1 参数） | 保活探针恒被拒（被当成"相机忙、链路仍在"） |
| `0x90C3` | AF 驱动 | **DelImageSDRAM（1 参数）** | 无参调用必 `ParameterNotSupported` → 对焦永远失败 |
| `0x90C4` | GetLargeThumb | GetLargeThumb ✅ | 唯一正确的是它 |
| `0x90C7` | — | GetEvent（无参，数据入） | 事件排水的正解 |
| `0x90C8` | — | DeviceReady（无参） | 保活探针的正解 |
| `0x90CB` | — | AfCaptureSDRAM（无参） | AF+拍摄到 SDRAM |
| `0x9201` | LV 启动 | StartLiveView ✅ | 正确（实测也吻合） |
| `0x9202` | — | **EndLiveView** | 退出取景的正解 |
| `0x9203` | 取景帧 | GetLiveViewImg ✅ | 正确 |
| `0x9205` | — | ChangeAfArea（2 参数 x,y） | 点击画面指定对焦点 |
| `0x9206` | LV 结束 | **AfDriveCancel** | 从未真正结束取景，只取消了 AF |
| `0x9207` | 相机端缩放 | **InitiateCaptureRecInMedia（拍摄！）** | 探针里当成只读操作反复试，语义是"拍摄" |
| `0x920F` | — | **GetFhdPicture（1 参数，返回 ≤1920×1028）** | 查看器"中"等画质的正解 |
| `0x9405` | 取景中拍摄 | **MeasureSpotWb（点测白平衡）** | 拍摄失败时会去启动白平衡测量 |
| `0x9125` | AF 驱动（上一轮我按 wmu_audit 加的） | **佳能 EOS 的 BulbStart** | 尼康上不生效（该审计表那行括号注释误导） |
| 事件 `0x400B~0x400E` | StorageInfoChanged/CaptureComplete/… | DeviceReset/**StorageInfoChanged**/**CaptureComplete**/UnreportedStatus | 整体错位两格；真机日志里 `0x400D` 被显示成 "UnreportedStatus"，掩盖了"相机其实会主动上报拍摄完成" |

**教训**：`wmu_audit.md` 里的括号码值不可当依据（它描述的是功能清单）；**码值只认 libgphoto2 ptp.h**。

### 20.3 属性方言：Wi-Fi 根本不是"裁剪方言"

Dump 输出的关键几行（原样抄录）：

```
0x5007 只读 当前=710  枚举[170,180,200,220,250,280,320,350,400,450,500,560,630,710,800,900,1000,1100,1300,1400,1600]
0x5008 只读 当前=5600 范围[5600,5600,1]
0x500D 可写 当前=3333 枚举[2,3,4,5,6,8,10,12,15,20,25,31,40,50,62,80,100,125,166,200,250,333,400,500,666,769,1000,1250,1666,2000,2500,3333,4000,5000,6250,7692,10000,…,300000]
0x500E 只读 当前=4    枚举[1,2,3,4,32784,32792,32848,32849,32850]
0x500F 可写 当前=2500 枚举[100,125,160,200,250,320,400,500,640,800,1000,1250,1600,2000,2500,3200,4000,5000,6400,8000,10000,12800,16000,20000,25600,32000,40000,51200]
0x5010 可写 当前=0    枚举[60536,60870,…,64536,64870,65203,0,333,666,1000,…5000]
0x5013 可写 当前=1    枚举[1,2,32784,32785,32793,33039,33054]
```

对照 libgphoto2 `/ 标准 PTP`：
`0x5007=FNumber`、`0x5008=FocalLength`、`0x500D=ExposureTime`、`0x500E=ExposureProgramMode`、
`0x500F=ExposureIndex(ISO)`、`0x5010=ExposureBiasCompensation`、`0x5013=StillCaptureMode`。

**结论：Wi-Fi 智能设备模式用的就是标准 PTP 属性码**，此前记录的"尼康裁剪方言
（0x500D=光圈 / 0x500E=快门 / 0x500F=ISO）"是错的。旧映射的后果（截图实证）：
UI 把 `0x500D=3333`（快门 1/3s）当光圈显示成 **f/33.3**，把 `0x500E=4`（档位）当快门显示成
**1/2500s**——两个数都错，而且"看着很合理"所以一直没被发现。已修正为
`PropDialect(0x5007, 0x500D, 0x500F, 0x500E)`，Wi-Fi 与 USB 共用。

**档位枚举顺序无法只靠 Dump 断定**，因此 `_modeName()` 加了自校准：用"光圈/快门哪个可写"
反推（都可写=M、仅快门=S、仅光圈=A、都不可写=P/AUTO），与数字名冲突时按可写性显示并写日志。
本次 Dump 的 `0x500D 可写 + 0x5007 只读` ⇒ **相机当时在 S 档**，与用户"不是 AUTO 档"一致。

### 20.4 本轮功能（用户点名 + 审查文档建议）

| 功能 | 说明 | 位置 |
|---|---|---|
| **查看器画质三档** | 默认**中**（相机端 FHD 图 0x920F ≤1920×1028），可切低（大缩略图）/原图；右上「显示原图」按钮按需升级**当前这一张**；角标实时显示生效档位与文件大小 | `viewer_page.dart` / `settings_page.dart` |
| **查看器内存上限** | 字节缓存 LRU（3 张）+ 本地查看器同样处理——此前只增不减，翻十张就是 OOM（审查文档 A3） | `viewer_page.dart` / `local_viewer_page.dart` |
| **相机剩余容量** | `GetStorageInfo(0x1005)` 解析 PTPStorageInfo → 连接页与相册页显示"卡剩余 XGB · 可拍 N 张"，连接后自动拉取 | `CameraEngine.storageInfo` / `connect_page` / `gallery_page` |
| **相机端文件管理** | 相册选择栏加"保护 / 取消保护 / 删除相机上的原片"——原生 `protectObject`/`deleteObject` 早已实现但**没有任何 UI 入口**（审查文档 C1） | `gallery_page.dart` |
| **曝光补偿** | 遥控页新增 EV chip（0x5010，1/1000 EV，INT16 补码归一化），P/S/A 可调 | `remote_page.dart` |
| **档位显示** | 0x500E 可读 → 此前恒显示 "--" 的档位 chip 现在能显示 M/P/A/S（自校准） | `remote_page.dart` |

### 20.5 待验证（需要真机操作，见 §21 调测清单）

1. 取景中点击画面 → 日志应出现 `AF 驱动：0x90C1 记录为可用`；
2. 查看器"中"档 → 日志出现 `中等图（0x920F）…`；若回退会写明原因；
3. 存储卡容量数字是否与相机菜单显示一致；
4. 退出取景：日志会写明是 `0x9202` 还是 `0x9206` 生效。

---

## 21. 第三轮真机验证结果（2026-09-15 21:44~21:51，Wi-Fi）

### 21.1 全部生效（对照 §20.5 的清单）

| 验证项 | 日志原文 | 结论 |
|---|---|---|
| 卡容量 | `存储卡：1 个，剩余 105GB / 可拍 7491 张` | ✅ F4 可用 |
| AF 驱动 | `AF 驱动：0x90C1 记录为可用` | ✅ **0x90C1 是正解**，点击取景框能对焦 |
| 结束取景 | `实时取景已关闭（0x9202）` | ✅ 0x9202 = EndLiveView 生效 |
| 拍完事件 | `相机事件：CaptureComplete(拍摄完成) 3688` | ✅ 事件表校正生效，相机确实主动上报 |
| 中等图 | `探针 0x920F [句柄] → OK 881058B（JPEG 偏移 0） 1620×1080` | ✅ 可用 |
| 画质阶梯（实测） | 低=`0x90C4` **640×424/133KB**、`0x100A` 160×120/9KB；中=`0x920F` **1620×1080/881KB** | 已按实测改写设置页文案（原写"约 1600 像素"是想当然） |
| 超时不再杀连接 | `命令通道读超时（操作 0x920F）：超时在包边界，放弃该事务、连接保留` → 后续 `下载完成：DSC_5586.JPG …（8816816 字节，1.5 MB/s）` | ✅ **第二轮的核心修复被真机证明**（旧行为这里必然掉线+3 分钟不可用） |
| 取景中拍摄 | `取景中快门已触发（0x100E）` + `ObjectAdded 689608159` + `CaptureComplete` | ✅ |
| 新兜底路径 | `取景中 0x9207（对焦后拍摄到卡）尝试 → DeviceBusy` | ✅ 按设计只在 0x100E 被拒后触发（相机忙） |

### 21.2 本轮新发现并修复的三个问题

**① 厂商事件队列的格式此前一直读错（现在才真正可用）**

日志里反复出现 `CheckEvent 数据无法解析（count=1074135044）：04 00 06 40 A2 D1 00 00 …`。
把 hex 按结构对齐后真相很清楚：

```
04 00 | 06 40 A2 D1 00 00 | 06 40 BB D1 00 00 | 06 40 …
 ↑count=4   ↑0x4006 param=0xD1A2（厂商属性变化）   ↑0x4006 param=0xD1BB
```

**格式 = `[u16 条数] + N × ([u16 事件码][u32 参数])`**，条数是 **u16**。旧代码按 u32 读，
于是把 `0x4006` 和参数高 16 位拼成了 1074135044 这种垃圾值——等于这条通道一直没在用。
修正后 `parseCheckEvents` 才真正排水（并顺带成为 0x4006 之外的 ObjectAdded 兜底来源）。
日志策略：0x4006 只计数不逐条记（空闲时 1 秒好几条，会刷屏）。

**② 0x920F 会超过 30 秒才应答 → 查看器卡 30 秒**

`中等图（0x920F）不可用：事务 0x920F 超时（…），回退大缩略图`。0x920F 是相机**现渲染**这张图，
用默认 30s 超时会让查看器干等半分钟再回退，比直接给缩略图更差。已改为：
6 秒专用超时 + 连续两次失败则在本次会话内不再尝试（避免每张都等 6 秒）。

**③ 数据相位大的操作被放弃后，迟到响应可能混进后续下载**

0x920F 单张 881KB，超时后它的响应会稍后涌入；原来清理预算统一 1.2s，草率放弃就可能让这 881KB
被算进紧接着开始的下载。现在按被放弃操作的数据量分级：数据相位大的（GetObject /
GetPartialObject / 0x920F / 0x9400 族）给 4 秒，**等不到就明确作废连接**——宁可让用户重连，
也不把数据混进大文件；小操作（探针/取景帧）仍是 1.2s 软放弃（最坏多一帧旧画面）。

**附带**：`NikonsyncPlugin` 的异常出口补了一行日志。此前的现象是"8.4MB 下载卡住 28 秒，
logcat 里一行痕迹都没有"——因为 `CameraEngine.download()` 内部没有 catch，异常直接穿到
Dart 层。现在任何原生方法失败都会留下 `✗ 方法 download 失败：xxx`。

### 21.3 关于 21:48:56 那次"掉线"（不是 App 的 bug）

```
21:48:56 连接 192.168.1.1 第 1 次失败：Connection reset
21:48:59 第 2 次失败：socket EOF → 跳过网段扫描：相机仍在释放上一个会话   ← 本轮新增的诊断生效
21:49:19 连接失败：… from /192.168.31.173 …   ← 源地址已变成家庭网段
21:49:46 握手成功（源 192.168.1.2）
```

日志里的源 IP 从 `192.168.1.2`（相机热点）变成了 `192.168.31.173`（家庭 Wi-Fi），
说明**手机当时离开了相机热点**——这种情况下 App 报断开是正确的，且新加的"跳过 254 地址扫描"
避免了 2.4 秒白等，直接给出了可行动的结论。真正要留意的是：若手机 Wi-Fi 在相机热点与家庭网
之间来回切（部分 ROM 在相机热点"无互联网"时会把流量切回蜂窝/家庭网），需要用户端固定。

### 21.4 仍未解决

1. 21:48:28 那次 8.4MB 下载卡住（`开始下载` 之后没有 `下载完成`，28 秒后用户重连）。
   当时没有任何原生痕迹；2030 版已补失败日志，**下次复现请把这行日志发回**。
2. `0x9400` 三参数形态返回 `OutOfFocus`（按 libgphoto2 它是 GetPartialObjectHiSpeed，
   参数应为 `[handle, transferSize, terminate]`）——高速下载通道仍未打通，
   当前 Wi-Fi 实测 1.5MB/s。
3. 相机热点下手机 Wi-Fi 抖动导致的重连体验（§21.3）。

---

## 22. 第四轮：用户实测反馈修复（2026-09-15 晚）

### 22.1 又一个码义错配：`0x1016` 是 SetDevicePropValue，不是 SetDevicePropDesc

用户反馈「A/S/P 档修改参数报错」。核对 libgphoto2 `ptp.c:2824`：

```c
ptp_setdevicepropvalue (params, propcode, value, datatype) {
    PTP_CNT_INIT(ptp, PTP_OC_SetDevicePropValue, propcode);   // 参数 = 属性码
    size = ptp_pack_DPV(params, value, &data, datatype);      // 数据 = 只有值
    ptp_transaction(params, &ptp, PTP_DP_SENDDATA, size, &data, NULL);
}
```

而项目此前把 `0x1016` 当成 SetDevicePropDesc 用：**不传参数**，数据里塞
`[code u16][dtype u16][值]` → 相机一律拒绝。已改为
`transactWithDataOut(0x1016, params=[code], data=<按 dtype 长度编码的值>)`。

这也解释了为什么 §18.2 记录的"参数设置已实现"从来没被真机验证过就报错。

### 22.2 点击画面指定对焦：以前只驱动 AF，没指定区域

用户反馈「点击屏幕指定对焦不成功」——因为当时的实现是"点哪儿都驱动中心的 AF"。
现在接上 `0x9205 ChangeAfArea`（libgphoto2：**2 参数 x, y**）：

- 屏幕点击点 → 去掉 BoxFit.contain 的 letterbox → 反旋转回**相机帧坐标**（`_framePointFor`）；
- 帧尺寸从每帧 JPEG 的 SOF 段读（`jpegDimensions`，只取一次）；
- 发了 0x9205 之后再驱动 AF（0x90C1），一步到位；
- 相机若拒绝坐标（InvalidParameter 等），**如实上报并回退为当前 AF 区域**，
  日志会给 `指定对焦区域 [x,y] 被拒：…`——坐标空间对不对，一次就能看出来；
- UI 加了对焦点方框（1.4 秒淡出），点哪儿标哪儿。

### 22.3 档位名补上厂商扩展值

A/S/P 显示正确（1=M 2=P 3=A 4=S 已被用户确认），但 AUTO/SCN 落到了数字上。
按用户实测补：**32784=AUTO、32792=SCN**。其余厂商值仍显示数字（不自作主张猜 U1/U2/U3）。

### 22.4 查看器「显示原图」= 下载并落盘（不再重复传输）

用户指出："点了原图就等于已经下载了，应该显示下载，而不是还得专门点一次下载。"
原实现是"内存取一次原图显示"，和下载是两条路。现在合并成一条：

```
点「显示原图」 → model.download([f], variantOverride:'original', onSaved:(f,uri))
              → 原生流式落 MediaStore/SAF + 写去重记录
              → 用返回的 uri 读本地字节显示（不再走网络）
```

- `CameraGateway.downloadFiles` 新增 `onSaved(f, uri)` 回调；
- `AppModel.download` 新增 `variantOverride`（查看器要强制原图，不受"下载画质"设置影响）与 `onSaved` 透传；
- 已经是下载记录里的图 → 直接从本地 uri 读，不重新下载；
- 落盘失败（被跳过等）→ 退回内存取图，保证用户仍能看到原图（并写应用内日志）。

### 22.5 下载速度 1.5MB/s 的结论（未改代码）

同一台机器上一轮测到 2.4MB/s、本轮 1.5MB/s，波动来自信号/干扰。Wi-Fi 是相机自建 AP
（2.4GHz 单天线），**这个量级已接近该模式上限**，不是 App 的分块策略问题：
4MiB 分块的往返开销在 2.7s/块面前可以忽略。真正快的路径是 USB（实测 27.1MB/s）。

顺带修正了高速通道探针的参数形态（`0x9400` 应为
`[句柄, 传输长度, 结束标志]`，不是 `[句柄, 偏移, 长度]`），连接后自动跑并写日志；
但**只试结束标志=0**——置 1 会让相机认为"传完即结束"，自动探针不能有这种副作用。
若探针确认 0x9400 可用，再实现真正的 HiSpeed 下载（需要与 0x101B 逐字节比对后才启用）。

## 23. 第五轮：进度可见性 + 链路可观测性（2026-09-15 深夜，APK 2033）

用户的四条反馈本质是同一件事：**"我做了一个操作，但不知道它现在是什么状态"**。

### 23.1 原图加载有进度了（此前只有一个转圈）

问题：点「显示原图」后一直转圈，无法区分"正在传 20MB"与"已经卡死/断线"。

新增原生 `fetchOriginal(handle, size)`（`CameraEngine.kt`）：用**下载同一条流式通道**
（`PtpSession.getObjectToStream`）取回内存，逐块发 `progress` 事件；返回
`{bytes, bytesWritten, ms, speedMBps}`；`written != size` 由底层直接抛异常——
绝不返回截断 JPEG。Dart 侧 `NikonEngine.fetchOriginal`。

UI（`viewer_page.dart`）在原图上叠加进度卡片：
百分比 + `已接收/总量` + `MB/s` + `已用 Ns`；每秒一拍统计**连续无新数据的秒数**，
≥8 秒时卡片变暖橙并提示"相机可能未响应、也可能链路已断"。

顺带修掉一个进度粒度假象：分块下载 4MiB/块，在 1.5MB/s 下每块要 2.7 秒，
原先**只在整块结束时才报一次进度**，进度条会长时间不动——看起来就像卡死。
现在 `PtpIpClient.writeChunk` 按 1MiB 在块内也上报（`base + written`，单调递增）。

### 23.2 「显示原图」是否保存到手机 → 设置开关（默认关）

- 关（默认）：`fetchOriginal` 仅取回内存显示，不落盘、不写下载记录；
- 开：走原生下载（流式落 MediaStore/SAF + 写去重记录），再用返回 uri 读本地字节
  ——一次传输完成"看"与"存"，同一张图只传一遍。

理由：看一张图和"把这张收进手机"是两件事，默认落盘会让相册悄悄多出用户没打算要的文件。
设置页 `SwitchListTile「查看原图时保存到手机」`，持久化键 `viewerSaveOriginal`。

### 23.3 链路健康显示：信号强度 + 相机活性

回答"是卡住了、断开了、还是别的原因"，给两层证据：

| 层 | 数据 | 来源 |
|---|---|---|
| 链路 | RSSI / 0~4 格 / 链路速率 Mbps | `wifiInfo()` 新增字段（`WifiManager.connectionInfo`） |
| 协议 | 距上次收到相机消息多久、保活探针往返耗时 | 保活循环**每 5s 必发**的 `health` 事件 |

- 保活循环此前"有事件就跳过探针"，于是空闲期 UI 完全看不到活性信息；
  现在**无论发不发探针都上报一次 health**，空闲与失联因此可区分（此前两者长得一样）。
- `camProbeOk=false` 时信号格转暖橙，`linkHealthText` 给出可行动文案。
- `lib/pages/widgets/link_status.dart`：AppBar 上的 `LinkStatusButton`（信号格，点开详情
  对话框：信号/速率/距上次消息/探针往返 + 一段"怎么读这块信息"）。已接入连接页、
  相册页、遥控页；连接页的"Wi-Fi 已连接"那一行也可点。
- USB 连接时信号格显示"不适用"——**不拿家庭 Wi-Fi 的格数冒充相机链路**。
- 每 4 秒刷新一次（`AppModel._startSignalWatch`），仅连接期间运行，断开即停并清空。

### 23.4 待验证

1. 连接后日志出现 `链路信号：N/4 格（-xx dBm）· 速率 x Mbps`（连上时上报一次）；
2. 点大图「显示原图」→ 进度卡片百分比/速率/已用时长是否连续走动；
3. 故意在传输中断开相机 Wi-Fi → 卡片应在 8 秒后转为暖橙提示；
4. 点 AppBar 信号格 → 详情里的格数是否与系统 Wi-Fi 设置里的信号一致。

## 24. 第六轮：参数写入真根因 + 对焦显示/标定 + 取景中断恢复（APK 2034）

### 24.1 「改参数失败」的根因是 **PTP/IP 数据外发报文的载荷格式**

真机日志：`✗ 方法 setShotParam 失败：PTP TransactionCancelled: 操作 0x1016`。

`TransactionCancelled(0x2017)` 的含义是"这笔事务的报文自相矛盾"。核对 libgphoto2
`ptpip.c` 的 `ptp_ptpip_senddata()`，**数据外发（PTP_DP_SENDDATA）的报文应当是**：

| 包 | 载荷 |
|---|---|
| StartData | `[事务号 u32][总长度 u32][未知 u32=0]`（整包 20 字节）|
| Data / EndData | `[事务号 u32][数据]`；**最后一块必须是 EndData** |

而原实现写的是 `[总长度 u64]` 和 `[偏移 u32]`——相机读到的"事务号"分别是数据长度与 0，
与请求里的事务号对不上，于是**一律回 TransactionCancelled**。

> 注意 `dataPhaseInfo` 本身没错：libgphoto2 在 `PTP_DP_SENDDATA` 时写 **2**（数据出）、
> 否则写 **1**（数据入），与我们的 `if (dataOut != null) 2 else 1` 一致。
> 错的是**数据包内部的字段**——这类"格式差一个字段"的问题从现象完全反推不出来，
> 只能逐字段对照参考实现。

**这也是"改光圈/快门/ISO 永远失败"的真正原因**：0x1016 的码义（上一轮修好）只是
必要条件，报文格式才是充分条件。USB 传输层用的是标准 PTP 容器格式
（`[长度][类型][码][事务号][数据]`），**本来就是对的**，因此 USB 下的参数写入此前可用。

### 24.2 取景对焦点：手机端现在显示，且坐标可标定

用户反馈："相机取景窗会显示焦点位置，但手机端不显示，点击后跟相机端不一致。"

1. **对焦框改成常驻**（原来是 1.4 秒淡出）：相机的对焦框一直亮着，手机端一闪而过
   就会被理解为"没显示"。颜色即状态：白=指令在途 / 黄=已指定 / 橙=相机接受指令但拒绝
   坐标（回退到当前 AF 区域）/ 红=对焦失败；被拒时还会把**实际发出的坐标**摆出来。
2. **坐标空间标定**：`0x9205 ChangeAfArea` 只写了"2 参数 x, y"，没有文档说坐标系。
   我们按取景帧像素（实测 640×424）发送时相机**接受**了坐标但对焦点落到别处——典型的
   "同比例不同尺度"。因此：
   - 新增设置项 `afAreaScale`（默认 1.0），点击坐标乘上它；
   - 取景区加了「🎯 标定对焦」入口（也可长按画面）：滑动系数 → 「发送测试点」→
     看相机屏幕上的对焦框是否落在**画面 1/4 处** → 保存。全过程不需要改代码；
   - 同一面板里的「跑标定探针」会调 `probeAfArea`：先用 `0x90CA GetVendorPropCodes`
     列出相机支持的厂商属性码，再读 AF 相关属性（0xD05D/0xD061/0xD08D/0xD108）的
     类型与取值表，最后按 ×1 / ×3 两种缩放各发一个 1/4 点——**属性表里若出现坐标范围，
     那就是第一手答案**。

### 24.3 取景中断不再"无限转圈 + 刷屏日志"

真机日志（22:28~22:29）暴露：相机离开取景态后 `0x9203` 持续回 `NotLiveView`，
而单独重发 `0x9201` 会返回"成功"却不出帧（`liveViewOn` 被置真，后续启动被短路），
取帧循环于是每帧写一条错误日志——**每秒 8 条，把 logcat 缓冲整个冲掉**，
真正的证据反而丢了。

修复：
- 新增 `CameraEngine.liveViewRestart()`：`0x9202`（真的结束）→ 等 250ms → `0x9201`，
  忽略缓存的取景标志；
- 取帧失败区分 `NotLiveView` 与其他；每 5 次失败触发一次强制重进（3 秒节流）；
- 连续 25 次失败（约 3 轮）→ **暂停循环**，显示故障卡片："相机没有提供取景画面。
  请确认相机不在回放/菜单界面、屏幕亮着未休眠…" + 「重新进入取景」按钮；
- `NikonsyncPlugin` 对高频方法（`liveViewFrame`）的失败日志限流到 5 秒一条。

### 24.4 UI 设计稿（白天/深色两套主题）

`docs/UI设计稿-2026-09-15.html`（自包含单文件，右上角切换主题）：
13 个语义色令牌 + 字阶/间距/圆角规范 + 11 个页面/弹窗的静态稿与标注 +
四态约定（加载/空/失败/离线）+ 落地到 Flutter `ThemeExtension` 的映射表。

**关键约束**：品牌黄在白底上不能当文字用（浅色主题下文字类强调改用深琥珀
`accent-text`）；取景与大图容器始终黑底，不随主题变。当前实现所有颜色都写死在
Dart 字面量里且只有深色一套，落地时需要先抽令牌。

## 25. 第七轮：相机息屏导致遥控失效 + 参数同步加固（APK 2035）

### 25.1 真机反馈与日志证据

用户反馈三条，其中前两条**可能是同一个根因**：

1. 点取景画面，相机的对焦点**不生效**；
2. S 档改快门生效，但相机的自动 ISO 变化**不同步**到手机；
3. 相机空闲十几秒就息屏，**必须手动按相机快门才醒**，遥控拍摄彻底不可用。

日志（22:51）显示：`0x9205 已指定对焦区域` 返回成功、但同一时段 `0x9203` 持续
`NotLiveView`，且反复重启取景。**相机屏幕已经息屏**——此时：
`0x9201` 仍返回"成功"、`0x9205` 仍被接受，但都不会真的生效。所以 1 与 3 很可能
是同一件事：**息屏后取景/对焦通路实际已不可用，而相机仍然"礼貌地"回 OK**。

### 25.2 保持相机清醒（本轮新增）

依据 libgphoto2：

- `0x90C8 DeviceReady` 就是"你准备好了吗/醒一醒"的语义（`nikon_wait_busy` 反复调它
  等相机从忙/休眠恢复）→ 新增 `wakeUp()`，并在 `liveViewRestart()` 里**先唤醒再重进取景**；
- `PTP_DPC_NIKON_MonitorOff(0xD064) "LCD Off Time"` 与 `MeterOff(0xD062)` 都是**可写**属性
  → 新增 `keepAwake(true/false)`：读描述符 → 取枚举/范围里的**最大值**写入 →
  **记住原值，退出遥控时还原**（不偷偷改用户设置）。

进入实时取景时自动开启常亮，退出/离开页面时还原；相机不允许修改时如实提示
"请在相机菜单把电源关闭延迟调长"，绝不假装成功。

### 25.3 参数同步加固

- 事件侧的 `DevicePropChanged` 转发本来是通的（相机确实推 0x5007/0x500D/0x500E/0x500F），
  但刷新是"事件驱动 + 1.5 秒节流 + 静默失败"，任何一次失败都不会留下痕迹。
- 现在：监听码加上 **0x5007**；**2.5 秒轮询兜底**（`shotParams` 共 4 个事务，对取景帧率
  影响可忽略）；失败不再静默，并在值变化时记录 `参数同步：ISO 100→3200`。
- **新增 `logToNative`**：release 包里 Dart 侧日志只在应用内面板，真机上"界面为什么没
  刷新"这类问题外部毫无证据。关键路径（参数同步、常亮、取景状态）现在用
  `AppLog.addKey()` 同时写进 logcat（前缀 `[ui]`），排查不必再靠用户口述。

### 25.4 文档与方案

- `docs/RAW+JPEG成对照片方案.md`：三个方案对比，**推荐方案 A**（一条一文件 + 成对标记
  + 联动选择 + `RAW+JPEG` 下载档），含需先跑的真机探针清单。**待用户确认后再开发**。
- `docs/UI设计稿-2026-09-15.html` 补三处：USB 连接四步向导、遥控**盲拍模式**
  （不进取景通道、息屏时的兜底）、相册的**拖动多选**与**按日期整选**。
  ⚠️ 后两个能力**代码里早已实现**（`DragSelection` / `_groupedGrid` / 筛选条「按日期」），
  只是入口不够显眼——不要再重复实现。

### 25.5 构建提示

release 构建**第一次偶发失败**（无错误输出的 gradle 失败），**直接重跑即可成功**；
若要看真实原因，不要用 `grep "Built|FAILED"`（会把错误吞掉），改用
`./gradlew :app:compileReleaseKotlin` 或完整 `tail`。

## 26. 第八轮：对焦坐标空间定标 = ×16 + 待机问题的结论（APK 2036）

### 26.1 对焦点**确实在动**——只是坐标空间不同（这是好消息）

用户用「🎯 标定对焦」做了一次标定：把系数设为 ×8，点「发送测试点」（即"画面 1/4 处"
= 160×8, 106×8 = **1280, 848**），相机上的对焦框落在**画面约 1/8 处**。

按线性关系反推：

```
1280 / W_cam = 1/8   →  W_cam ≈ 10240  = 640 × 16
 848 / H_cam = 1/8   →  H_cam ≈  6784  = 424 × 16    （宽高比 1.5094，与取景帧一致）
```

与探针的两个点也吻合：×1 的 (160,106) 落在 1.6%、×3 的 (480,318) 落在 4.7%
——都在左上角，正是用户看到的"探针一直停在左上角"。

**结论：`0x9205` 的坐标空间约为取景帧（640×424）的 16 倍，且同比例、原点在左上。**
`afAreaScale` 默认改为 **16**（设置键改用 `afAreaScaleV2`，避免沿用"×1 时代"的旧值）；
标定面板的滑杆扩到 1~24，并给出 ×1/×8/×16/×20 一键切换 + "点画面正中"验证法
（中心对任何等比缩放都是不变量，用它判断有没有偏移）。

### 26.2 相机待机（息屏）问题：**改不了，只能绕**

休眠探针真机结果：

```
0xD064 MonitorOff       → 不支持
0xD062 MeterOff         → 不支持
0xD066 AutoOffTimers    → 不支持
0xD0B3 MonitorOffDelay  → 不支持
0x90C8 DeviceReady      → OK 4ms（但仍叫不醒屏幕）
```

也就是说**这台机器在 Wi-Fi 智能设备模式下不暴露任何息屏/待机属性**，App 无法修改，
`DeviceReady` 也无法把屏幕叫亮。因此本轮的做法是"承认 + 绕开"：

1. 故障卡片把话说全：按相机任意按钮唤醒 / 相机菜单把「电源关闭延迟」调长 /
   **或改用「盲拍」**（`0x100E`，不依赖取景通道）；
2. 卡片上直接给两个按钮：「唤醒并重进」与「切到盲拍」；
3. 新增**实验开关**「防待机试探」：取景中每 15 秒发一次**无副作用**的协议活动
   （`0x90C8 DeviceReady` + 重发上次对焦点 `0x9205`，**不重发 0x9201**——那会打断帧流），
   日志记录每次戳的时间，用于判断相机是否因此推迟待机。默认关。

### 26.3 ISO 不同步：先分清"没刷新"还是"读到的值不是实时的"

日志证实**参数同步机制本身是工作的**（`[ui] 参数同步：光圈 280→200，快门 80→40`、
`ISO 200→2000`），并且发现两件事：

- 事件与轮询会同时触发，300ms 内跑过 **8 次** `shotParams` → 已加**防重入守卫**；
- 但相机屏幕显示 `ISO AUTO 2500` 时，读到并缓存的 `0x500F` 是 **2000**。
  两种可能：(a) `0x500F` 在 Auto ISO 下报的不是实时值（而是 ISO 设定/上限）；
  (b) 那个时刻界面已离开遥控页、轮询已停（轮询只在遥控页挂载时运行）。

为了区分，取景帧现在会打一行**头部 hex**：

```
取景帧头部 <n>B：XX XX …（请对照相机屏幕上的 ISO/光圈/快门）
```

尼康取景帧在 JPEG SOI 之前有一段头部，社区的实现里这一段带**实时拍摄信息**。
把它与相机屏幕对齐即可确认头部里是否有真实的实时 ISO——若有，以后遥控页的
参数显示直接读它，不再依赖在 Auto 档下不靠谱的 `0x500F`。

## 27. 第九轮：对焦倍数改为点点选标定 + 待机结论落地 + RAW+JPEG 成对（APK 2037）

### 27.1 对焦倍数：两次口径不一致，所以改成"点选式标定"

用户先后给过两个口径（"×4 一致" 与 "×8 一致"），差整整一倍——**口头估计不可靠**。
因此不再猜：标定面板改成一个三步点选向导：

1. 面板里显示当前帧尺寸与测试点坐标，点「发送测试点」→ 固定发**画面 1/4 处**（`fw/4, fh/4`）；
2. 用户看**相机屏幕**，在对焦框落点里点一项：正中(1/2) / 1/4 / 1/8 / 1/16 / 1/32 / 顶在最边上；
3. App 直接算倍数 = `0.25 / 落点比例` 并写入设置（另有滑杆可微调、`恢复 ×4` 一键回默认）。

设置键改为 `afAreaScaleV3`（V2 存的是 ×16 的错误结论），默认 ×4。
`probeAfArea` 同步更新为发三个点：**中心**（任何等比缩放的不变量，用于验证原点有没有偏移）、
1/4 处与 3/4 处，并新增读回 `0xD08D AF Area Point` 的尝试——
**若该属性可读，就能"发一个坐标→读回落点"自动解出倍数**，彻底不靠肉眼。

> 关于"能否读取相机取景框长宽自行计算"的结论：**不能**。本机不提供任何
> AF 坐标空间尺寸属性（`0xD0xx`/`0xD0B3` 等探针全"不支持"），
> 取景帧 JPEG 固定 640×424，而相机内部的 AF 空间是另一个尺度——只能实测。

### 27.2 待机问题：结论落地（改不了，但说清楚 + 提前预警）

- `probeSleep` 已实测：`0xD064/0xD062/0xD066/0xD0B3` **全部"不支持"**，`0x90C8` 虽 4ms 应答
  但**叫不醒屏幕**；"防待机试探"（每 15s 发 DeviceReady + 重发对焦点）实测**同样无效**，
  → 该开关已从界面撤掉（留一个没用的开关比没有更糟），改为在标定面板里写清事实与出路：
  **MENU → ✏️自定义设定菜单 → c3「电源关闭延迟」调长**。
- `liveViewRestart` 加长：EndLiveView 后等 600ms，再用 4s/8s/8s 三次尝试（250ms 太短，
  真机上出现过 End 之后立刻 Start 被忽略）。
- **提前预警**：参数读取连续 3 次失败即判定"相机可能已待机"，遥控页顶部出现横幅
  +「尝试唤醒」。待机与"未对焦"的表象一样，等用户按了快门才发现就太晚了。

### 27.3 盲拍拍不了：原因是**相机待机**，不是盲拍本身

真机日志（23:28）：

```
相机忙（DeviceBusy）第 2~6 次，已 7s
✗ capture 失败：快门在 9s 内始终未被释放（相机一直处于忙碌/未对焦）
```

相机待机时 `0x100E` 会持续回 DeviceBusy，直到预算（9s）耗尽，而报出来的却是"未对焦"
——**两者表象完全一样**。修复：

1. `capture()` 开头先 `wakeUp()`（4ms 成本，真机上息屏后它仍能应答）；
2. 失败文案新增 `STANDBY_HINT`（待机/唤醒路径）并排在 `FOCUS_PRIORITY_HINT` 之前；
3. 故障卡片里更正原先的说法——**盲拍在待机时同样拍不了**（之前写的"通常仍可用"是错的）。

### 27.4 ISO 不同步：新增差分探针

`0x500F` 在 Auto ISO 下报的不是实时值（相机屏幕 2500、读到 2000）。新增
`probeLiveIso()`（调试面板「实时ISO」）：读 `0x500F` 的 ISO 取值表 → 读标准段
`0x5001~0x5017` 与厂商段（`0x90CA` 列表）全部当前值 → 等 8 秒（Auto ISO 自己会变）
→ 再读一遍 → **报告哪些属性变了**，并把新值落在 ISO 取值表里的码标出来。
另外取景帧现在**每次会话都会打一行头部 hex**（含 `soi==0` 的情形），
用于确认取景帧头部里是否带实时 ISO。

### 27.5 RAW+JPEG 成对（方案 A，已实现）

- `CameraFile`：新增 `pairHandle` / `isPaired` / `baseName` / `pairKey`；
- `AppModel`：`_pairIndex`（目录+基名 → 文件）+ `_pairOne()`，随索引增量配对（O(1)），
  重新枚举时 `_rebuildPairIndex()`；配套 `pairOf()` / `isPairDownloaded()`；
- 相册格子：右上角 `R+J` 角标；左下角下载状态**分列显示 J/R**（实心绿勾=已下载）；
- **成对联动**：`DragSelection.onChanged` 里统一 `_syncPairs()`——所有选择入口
  （点选、勾选热区、长按滑动、全选、按日期整组）都会走这个回调，只实现一处就不会半生效；
  设置项 `linkRawJpegPairs`（默认开）可关；
- 筛选条新增「成对 N」chip；
- **未采用的简化**：原方案里的下载档 `RAW / RAW+JPEG` 两档没有加——"成对一起下"由
  联动选择覆盖，"只要 JPEG"由关掉联动 + 类型筛选覆盖，避免把画质档位与文件类型两个维度
  混在同一个下拉里（见 `docs/RAW+JPEG成对照片方案.md` 的后续说明）。

### 27.6 文案修正

连接向导补全相机菜单路径：**MENU → 网络菜单 → 连接至智能设备 → Wi-Fi 连接（AP 模式）**
→「建立连接」→「开始」；USB 向导明确**先关闭「连接至智能设备」**、
再把 **MENU → 网络菜单 → USB** 设为 **MTP/PTP**（不关掉的话相机会一直找手机热点，
USB 不会进 PTP）。应用内连接页与设计稿同步更新。

## 28. 第十轮：取景帧头部解出对焦倍数（自动）+ 连接页重构（APK 2038）

### 28.1 **找到了**：对焦倍数可以直接读出来，不用肉眼估

真机日志里取景帧头部第一次被完整打出来（**384 字节**，大端 u16），按字段读：

```
off  2: 376
off  8: 640      off 10: 424     ← 取景帧尺寸（与 JPEG SOF 一致）
off 12: 5568     off 14: 3712    ← 相机图像尺寸（Z50 II 有效像素）
off 16: 5568     off 18: 3712    ← 重复一次
off 20: 2784     off 22: 1856    ← 相机图像的一半
off 24: 288      off 26: 319
off 28: 5160     off 30: 3331    ← AF 覆盖范围（≈93% × 90%）
```

**`0x9205 ChangeAfArea` 的坐标空间就是"相机图像尺寸"**：

```
倍数 x = 5568 / 640  = 8.70
倍数 y = 3712 / 424  = 8.755     ← x/y 并不相等，必须各算一次
```

证据：用户实测"×8 大致与相机一致"（真值 8.70，差 8% 肉眼难辨）；
日志里还出现过 x=5831 > 5568 的坐标——超出会被夹到最近对焦点而不是报错。

实现：`CameraEngine.parseLvHeader()` 自动解析（找"取景帧尺寸"后第一对更大的合法尺寸），
`afScaleFromHeader()` 交给 Dart；遥控页首帧后取一次，**自动优先**，人工值仅在
"头部解析失败"或"用户手动覆盖"时生效（面板里可看当前是自动还是人工、可一键回自动）。

### 28.2 待机：`DeviceReady` 失败就是"睡着了"的可靠信号

本轮日志补上了关键一条：息屏后

```
00:03:04  唤醒尝试：PTP DeviceBusy: 操作 0x90C8
00:04:45  唤醒尝试：事务 0x90C8 超时（相机未在超时内应答）
```

——**DeviceReady 会失败（Busy/超时）**，而重进取景（0x9201）也超时。
所以"重进取景失败"直接判定为待机，故障卡片标题换成
**「相机可能已进入待机（屏幕灭）」**（此前只在参数读取连败 3 次时才判定，来得太晚）。
`wakeUp()` 的返回值语义也修正：**失败即失败**（原来把 `PtpException` 当成"链路还活着"返回 true）。

### 28.3 RAW+JPEG 角标"看不到"是正常的（卡里只有 JPEG）

用户反馈"相册里没有 R/J 角标"——当前卡里只有 JPEG，没有 RAW，**自然配不出对**
（这正是正确行为：宁可没有，也不要乱配）。为了让这条逻辑不靠真机才能验证，把配对规则
抽成纯函数 `lib/models/pair_linker.dart` 并补了 **10 条单测**（`test/pair_linker_test.dart`）：

- 同目录同基名的 JPG+NEF 互配；只有 JPEG → 不配；
- 同名同类（两张 DSC_1234.JPG）→ 不配；
- 目录不同 → 不配；基名大小写不同 → 仍配；NRW → 认作 RAW；
- 视频不参与；详情未加载时不配，索引补全后增量补上；
- 重复配对先清旧配对（换卡/删文件不残留）。

> 跑测试的命令要清代理：本机沙箱的 `HTTP_PROXY` 会让 `flutter_tester` 起不来
> （`Invalid WebSocket upgrade request`）。用法：
> `HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY=* flutter test`

### 28.4 ISO：差分探针结论 + 下一步的判定方法

5 次差分（每次 8 秒）结果：

```
0x500F 当前=200，取值表 28 项（最小 100 最大 51200）
第一遍读取 15/23 个厂商属性
8 秒内变化 2 项：0x5007 100→170 | 0x5008 0→5600     ← 第 1 次
之后各次：没有任何厂商属性变化
```

两点观察：

1. **厂商段只读出 15/23**，说明不少厂商码不支持 `GetDevicePropValue(0x1015)`（要读描述符）；
2. **`0x5008` 从 0 变成 5600** 很可疑：标准 PTP 里 0x5008 是焦距，但用户的镜头是
   24mm f/1.7（焦距应为 2400），5600 更像是 **ISO**。若成立，则
   **0x500F 是 ISO 设定值、0x5008 才是实际感光度**。

**判定方法（一次就能定论）**：让相机 LCD 显示一个好认的数字（例如手动固定 ISO **6400**），
然后跑调试面板的「**取景头部**」探针（dump 384 字节全部字段）与「**读一次参数**」，
把输出发回来——`0x1900`(6400) 出现在哪一节，实时 ISO 就在哪。
取景帧头部带实时拍摄信息（用户日志已证实头部存在且带多组尺寸），这是最可能的落点。

### 28.5 连接页重构（按钮优先）

用户反馈：一打开只看到大段指导，得往下滑才找到连接按钮，"很多人没意识到要滑"。重排为：

1. **方式切换**（Wi-Fi | USB，默认 Wi-Fi）；
2. **主按钮**紧随其后（Wi-Fi→「连接相机」，USB→「连接 USB 相机」），不滚动即可点；
3. 状态卡（Wi-Fi 显示当前网络/信号格；USB 提示"需先关闭连接至智能设备"）；
4. **指导默认折叠**（一句话摘要 + 展开看全部步骤，展开内容随方式切换）。

### 28.6 新增调试入口

- 调试面板「**读一次参数**」：读 0x5007/0x500D/0x500F/0x5010/0x500E 的当前值与可写性，
  用于**与相机屏幕当场比对**；
- 调试面板「**取景头部**」：dump 取景帧头部 384 字节逐字段（找实时 ISO）。

## 29. 第十一轮：启动图标（APK 2039）

### 29.1 设计

**同步环 + 镜头筒 + 对焦点**（原创标记，不含任何相机厂商的商标图形）：

| 元素 | 含义 |
|---|---|
| 外圈两段带箭头的弧（顺时针、左右留缺口） | 无线**传输**（对应成对下载/同步） |
| 内圈圆环 | **镜头**（对应"相机"这件事） |
| 中心实心点 | **对焦点**（对应"点画面指定对焦"这个核心交互） |

配色沿用 App 主题：`#FFE100`（与 `kAccent` 一致）＋深色渐变底 `#262A33 → #101216`。
48dp 下仍能辨认（见 `docs/icon/preview.png`）。

### 29.2 为什么用几何绘制而不是 AI 生成

启动图标在 48dp 上最容易糊成一团：AI 生成的位图细节会粘连，而几何形状 + **4× 超采样**
再 LANCZOS 缩小，边缘干净、像素可控，颜色也能与主题精确对齐。生成器是
`tools/gen_launcher_icon.py`（用系统 Python 3.11，它自带 Pillow 12.1；
托管 Python 3.13 环境里没有 PIL，也不必装）。

### 29.3 落地产物

```
mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png            传统图标（48/72/96/144/192）
mipmap-*/ic_launcher_foreground.png                    自适应前景（108dp 画布，透明底）
mipmap-anydpi-v26/ic_launcher.xml                      自适应图标声明（background/foreground/monochrome）
drawable/ic_launcher_background.xml                    自适应背景（竖向渐变 shape）
```

`<monochrome>` 复用前景图，Android 13 的"主题图标"会自动取 alpha 上色。
重新生成：`python tools/gen_launcher_icon.py`（同时输出 `docs/icon/preview.png` 预览）。
