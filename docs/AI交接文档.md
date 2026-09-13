# AI 开发交接文档（HANDOFF）

> 本文档面向接手本项目的 AI/开发者。读完即可继续开发，无需重新摸索。
> 最后更新：2026-09-13 · 版本状态：M2 功能全量完成，M2.x 修复迭代中

---

## 1. 一句话现状

尼康 Z50 II 照片无线传输 App（Flutter UI + Kotlin PTP/IP 引擎，仅 Android），已完成：Wi-Fi 直连、快速枚举、按需缩略图浏览、范围滑动多选、三档画质下载、日期分组、大图查看（EXIF）、自定义保存位置、盲拍遥控、下载管理页。**进行中**：遥控拍摄偶发卡忙（已加多重缓解待验证）、实时取景被相机拒绝待逆向、高速下载通道待探针日志确认。

## 2. 核心链路（必须先理解）

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

## 7. 未解决问题与排查方向（按优先级）

### 7.1 遥控拍摄第二张起持续忙碌（核心阻塞）
- 现象：首拍成功（AF 驱动 0x90C3 可用、ObjectAdded 正常到达标准事件通道），**第二张起持续 DeviceBusy/GeneralError**，与拍摄模式无关。
- 已排除：事件队列排水（0x90C1/0x90C0 被相机直接拒绝，无响应）、模式切换影响、AF 缺失（0x90C3 拍前对焦有效）。
- **当前主假设（证据最强）**：相机要求主机把新照片"取走"（GetObject 全量读取）后才允许下一次快门——SnapBridge 每拍必拉的正是这个。已实现：拍后自动全量读取新照片（≤40MB，读走即解锁，同时用作高清预览）。待真机验证连拍是否恢复。
- 其他假设：厂商传输队列（0x9407/0x9408 该机不存在，新代等价物未知）；0xA004 OutOfFocus 响应码已识别（未对焦时快门被拒会返回它，已做即时终止+提示）。
- 若全量读取后仍卡忙：尝试 GetLargeThumb 读取是否足够解锁；再不行考虑 0x920A SDRAM 拍摄流程。

### 7.2 实时取景（用户已要求调测）
- 0x9200 被拒。方向：a) 扩展探针到 0x9204~0x920F（0x920A/0x920B 是真拍摄，慎用）；b) 研究 0x95xx 段（SnapBridge 新协议）；c) 参考 `docs/reference/wmu_audit.md`（WMU 取景是完整状态机：Start→GetImage 流→AF→End，还有 Prohibition 检查）。
- UI 已预留：遥控页"盲拍/实时取景"切换的位置（当前只有盲拍）。

### 7.3 复制日志崩溃（Null check operator，未定位）
- 已加全局错误捕获：`FlutterError.onError` / `ErrorWidget.builder` / `PlatformDispatcher.onError` → 堆栈写入 AppLog → 用户复制日志即可反馈堆栈。
- 复现路径：设置页 → 长按日志选择复制。日志卡片已有明确"复制全部日志"按钮。

### 7.4 待装机
- 最新 APK **已构建未安装**（手机断开 USB）：`build/app/outputs/flutter-apk/app-debug.apk`。装机后才能验证：全局错误捕获、SDRAM 探测、事件排水解析、复制按钮。

## 8. UI 结构速查

- `HomeShell`（main.dart）：底部双 Tab——相机(ConnectPage) / 手机(DownloadsPage)，IndexedStack。
- ConnectPage：引导+智能连接；已连接面板有 浏览照片/遥控拍摄/断开；右上齿轮→SettingsPage（含嵌入式 DebugPanel）。
- GalleryPage：3 列网格、按需加载、类型/文件夹筛选、四种排序、长按滑动范围多选、右下圈选可点、底栏下载(画质切换)。
- 滑动选择算法：**锚点→当前索引连续范围**（微信式），行号 = (滚动偏移+局部y)/行高——勿删偏移项。
- DownloadsPage：日期分组（CustomScrollView+SliverMainAxisGroup 式分组）、命中测试式滑动选择（GlobalKey 表）、批量删除。

## 9. 测试要求

- 真机：Z50 II（固件 1.02，DeviceId "Z50_2"）+ 小米手机（23127PN0CC，MIUI）。
- 相机路径：MENU → 扳手 → 连接至智能设备 → Wi-Fi 连接 → 建立连接（屏幕显示 SSID/密码）→ 手机连该热点。
- 相机热点无互联网：App 已做 socket 绑定 Wi-Fi 网络，蜂窝不受影响。
- MIUI 注意：会杀后台（有前台服务对抗）、拦 adb input（UI 自动化用 uiautomator 而非 `input tap`）。
- 日志获取：设置页 → 协议验证面板 → 复制全部日志（App 启动即记录，无需先进面板）。

## 10. 给下一个 AI 的工作流建议

1. 读本文档 + `docs/技术方案.md`；跑 `flutter analyze`（应 0 error）与构建。
2. 任何协议改动先在 DebugPanel 加/用探针拿真机证据，**不要盲试厂商操作码**（有副作用风险，如 0x920A 会真拍照）。
3. 改完构建安装 → 用户真机验证 → 让用户复制日志反馈（日志含完整协议过程）。
4. 提交前跑 `flutter analyze`，保持 0 error/warning（info 级风格提示可容忍）。

## 11. 待办队列

- [ ] 安装最新 APK（已构建）并验证：全局错误捕获、SDRAM 探测、排水解析、复制按钮
- [x] 对焦优先相机（未对焦禁止拍摄）处理：拍摄前 AF 阻塞驱动 + MF 检测（0x500A）+ 对焦/非对焦原因区分报错（2026-09-14，待真机验证）
- [ ] 遥控拍摄第二张卡忙：已实现拍后全量读取解锁，待真机连拍验证
- [ ] 遥控拍摄：0xA004 未对焦即时终止已实现，待验证
- [ ] 实时取景：按 7.2 调测（用户已要求）
- [ ] 高速下载：看连接后日志的探针结果决定接入
- [ ] 相机端对焦优先设置的用户引导（"未对准焦不能拍照"时提示/AF 按钮已预留 tryAfDrive）
- [ ] M3 候选：通知栏下载进度、自动同步（ObjectAdded 已具备）、Wi-Fi 自动回连（WifiNetworkSuggestion）
