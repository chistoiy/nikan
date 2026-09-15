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

## 7. 未解决问题与排查方向（按优先级）

### 7.0 USB 空闲期重枚举循环（已缓解，根因待除）
- 相机空闲时每 ~3.65s 从手机总线消失、~3.4s 后重挂（dumpsys `num_connects=661`，严格周期）。
- **活跃传输期间连接保持住**（174MB/7s 中途未断），恢复机制可兜底非活跃期。
- 判别已做：相机插电脑稳定（相机/线排除）、屏幕常亮无影响、上传优先/拍摄优先无差异
  → 收敛到手机侧 OTG 供电或 MTP 主机栈。**决定性实验：带外供电 OTG 集线器（约 20-30 元）**。
- 详见 docs/USB连接方案.md §7.2/§7.5。

### 7.0b Wi-Fi 方言的档位属性码（遥控页置灰联动的前提）
- Wi-Fi 智能设备模式的属性码是尼康裁剪方言（实测 0x500D=光圈、0x500E=快门、0x500F=ISO，
  与标准 PTP 不同）。**档位（拨盘 P/A/S/M）对应的方言码未确认**。
- 已实现「属性码Dump」探针（调试面板）：读 0x5001-0x5017 + 0xD100-0xD11F 全部属性
  的类型/当前值/枚举表，跑一次即可确认。USB 传输层用标准 PTP 码（0x5006/0x500C/0x5007/0x500D），
  理论直接可用。

### 7.1 遥控拍摄第二张起持续忙碌
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

### 7.4 待装机验证
- U1 + 遥控页增强已装机（versionCode 2027+，2026-09-15），**验证清单见 §18.4**。

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

## 11. 待办队列（2026-09-15 重排）

- [ ] **U1 + 遥控页真机验证**（清单见 §18.4）：USB 连接/相册/下载/续传；Wi-Fi 遥控页 AF 点击、档位联动、参数编辑
- [ ] **跑「属性码Dump」探针**（调试面板）→ 确认 Wi-Fi 方言档位码 → 填入 CameraEngine.PropDialect → Wi-Fi 下档位联动生效
- [ ] 全部验证通过后提交（U1 + 遥控页 + 断点续传，当前未提交）
- [ ] 遥控拍摄第二张卡忙：拍后全量读取解锁已实现，待连拍验证
- [ ] 实时取景（Wi-Fi）按 7.2 调测；USB 实时取景（0x92xx 12 个操作 USB 下可用）U3 探索
- [ ] 带外供电 OTG 集线器：验证空闲重枚举根因（§7.0）
- [ ] U1 余项：下载进度通知栏（前台服务已就绪）、USB 下载断点信息持久化（跨次恢复）
- [ ] M3 候选：自动同步（ObjectAdded 已具备）、Wi-Fi 自动回连、连接页三步向导（UI 设计稿 §2.2）、筛选摘要行（§2.1）

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
