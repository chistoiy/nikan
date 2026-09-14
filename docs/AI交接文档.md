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

⚠️ **versionCode 陷阱**：pubspec.yaml 里是 `1.0.0+1`（versionCode=1），但手机上装的是带
`--build-number` 的 release 包（曾为 2001，现为 2002）。直接 `flutter build apk` 产出的包
versionCode=1，会被系统以 `INSTALL_FAILED_VERSION_DOWNGRADE` 拒绝。

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

### 仍未做

- **`CameraEngine.kt` 拆分（1431 行）**。探针段（约 330 行）占了近四分之一，但它与外层共享私有可变状态（`client`、`liveViewOn`，以及 `attempt_marker` 等辅助函数）。
不能像页面那样靠参数注入切干净——移出去需要把 4~6 个闭包穿过每个探针，属于换一种耦合，且只能在无真机的情况下靠编译验证。建议单独一次专门做，方案是：把这些共享成员放宽为 `internal`，探针搬到同包的新文件里直接引用 `CameraEngine.xxx`，门面方法保留一行转发。

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

