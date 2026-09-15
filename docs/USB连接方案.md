# USB 连接模式方案（重点：高速下载）

> 日期：2026-09-14 · 状态：**U0 已完成——实测 27.1 MB/s，方案成立，进入 U1** · 过程记录见 §7-§8
> 目标读者：接手开发的人。**先读 §7（U0 实测记录）**，再看 §1–§6 的方案与 §8 的源码结论。

---

## 1. 结论先行

> ✅ **2026-09-15 结案：GetObject 全量下载 174MB 文件，实测 27.1 MB/s，字节校验一致。**
> Wi-Fi 2.4 MB/s → USB 27.1 MB/s，**11 倍**；传满 30GB 卡约 19 分钟（Wi-Fi 约 3.5 小时）。
> 唯一遗留：相机在**空闲态**会周期性重枚举（§7.2），活跃传输期间连接保持住，
> 恢复机制可兜底；建议 U1 按"传输中也可能断"设计，并实测带外供电 OTG 是否根除循环。

| | 现在的 Wi-Fi 路线 | USB 路线（**已实测**） |
|---|---|---|
| 实测吞吐 | **2.4 MB/s**（README 记载，已接近 2.4G 热点物理上限） | **27.1 MB/s**（174MB 全量、字节校验一致） |
| 传 30MB 的 NEF | ~12 秒 | ~1.1 秒 |
| 传满 1500 张 / 约 30GB | **~3.5 小时** | **~19 分钟** |
| 会话稳定性 | 单会话、超时即作废（见交接文档 §15） | 无握手、无会话竞争；空闲期有重枚举循环（§7.2），恢复机制已实战可用 |
| 相机操作集 | 126 个操作（智能设备模式被裁剪） | 同为 126 个；0x92xx 段 12 个操作在 USB 下可用，实时取景等能力待 U3 验证 |

**复用边界极其有利**：`Ptp.kt`（操作码/响应码常量）、`PtpDatasets.kt`（数据集解析）、
`PtpWire.kt`（ByteReader）**全部与传输层无关，可以原样复用**。
要新写的只有传输层本身，以及把 `CameraEngine` 对客户端的依赖抽成接口。

这正是技术方案 §8 里写的兜底路径——"协议事务层代码完全复用，仅换传输层"。
**U0 已用实测证实了这条复用判断**：帧格式一次写对、逐字节验证通过，
真正耗掉九轮的是环境问题而非协议问题（见 §7）。

---

## 2. 为什么可行：PTP/USB 与 PTP/IP 的差别

同一条协议，两种承载。差别只在**帧封装与会话建立**：

| | PTP/IP（现状） | PTP/USB |
|---|---|---|
| 承载 | TCP 15740 | USB Bulk 端点 |
| 建立会话 | 必须先 InitCommandRequest 握手，**且要伪装尼康官方 App 的 GUID** 才放行完整操作集 | **无需握手、无需伪装**，直接 OpenSession |
| 帧头 | 4B 长度 + 4B 类型 | 12B 容器头：类型 u32 + 码 u16 + 事务号 u32（小端） |
| 数据方向 | 命令/事件双 TCP 通道 | Bulk OUT 发命令；数据与响应走 Bulk IN（或按阶段改向 Bulk OUT） |
| 事件 | 独立 TCP 事件通道 | 中断端点（若相机提供）或轮询 |

**注意第一行的差别**：Wi-Fi 下那套"伪装 WMU GUID"是必需的（否则只能拿到受限操作集，
参见技术方案 §2 的 libgphoto2 #1135 证据）；**USB 下不需要**。
这不仅省掉一层脆弱依赖，也意味着 USB 模式下的操作集不受"智能设备模式"裁剪——
这解释了上表最后一行为什么有机会解锁实时取景。

### 相机侧前置条件（必须确认）

1. **相机 USB 设置选「MTP/PTP」档位**——尼康 Z 机身的 USB 设置只有这一个合并档位，
   **没有单独的 PTP 选项**（已实测确认）。这不影响方案：
   MTP 是 PTP 的超集（USB 设备类上同为 Still Image，class 6 / subclass 1），
   主机端自行决定说 PTP 还是 MTP，libgphoto2 连尼康相机就是在这一档下直接跑 PTP 的。
   代码里的接口匹配因此先按 `class6/sub1/proto1` 精确找，找不到再放宽到 `class6/sub1` 任意 protocol。
2. **退出"连接至智能设备"模式**：Wi-Fi 与 USB 是两条互斥的连接路径，
   需要用户在相机上切过去（App 里要给明确引导）。
3. **Android 侧**：需要 `android.hardware.usb.host` 特性；minSdk 29 已足够，
   `UsbManager` / `bulkTransfer` 从 API 12 就有。

---

## 3. 分阶段计划

每阶段都有明确的 Go/No-Go，避免在错误方向上堆代码。

### U0 · 打通与测速（1–2 天）· 决策点

**唯一目标：拿到真实的 MB/s，以及确认能否 PTP 会话。**

> **状态：已实现并实测，但未能完成（2026-09-14）。**
> **速度数字没拿到**——阻塞在环境层（相机连接无法保持），不是协议层。
> 完整实测记录见 §7，务必先读那一节再动手。

已实现的内容（`android/.../PtpUsbProbe.kt`）：

- `AndroidManifest` 加 `android.hardware.usb.host`（`required=false`，无 OTG 的机型仍可只用 Wi-Fi）
- `res/xml/device_filter.xml` 按尼康厂商 ID（0x04B0）匹配，插入相机即拉起应用
- 找 PTP 静态接口（class 6 / subclass 1 / protocol 1）→ `requestPermission`（等用户点一次）
  → `claimInterface(force = true)`（系统自带 MTP 服务可能已占用）→ 定位 Bulk 端点
- 实现 12 字节 PTP/USB 容器（`长度 u32 + 类型 u16 + 码 u16 + 事务号 u32`），
  命令/数据/响应三段；Bulk 读循环补齐（部分读是常态）
- `OpenSession` → `GetDeviceInfo`（**复用 `PtpDatasets.parseDeviceInfo`**）
- **实测吞吐**：找最大的对象做 `GetObject`，只统计字节数不落内存（避免大文件 OOM），
  并校验头两字节是 JPEG SOI——防止"测得很快但数据是错的"
- 操作集对比：统计 `0x92xx` 段（实时取景族）在 USB 下是否放行

**测试步骤**：
1. 相机菜单把 USB 设置选为 **「MTP/PTP」**（尼康只有这一档，没有单独的 PTP），
   并退出「连接至智能设备」
2. 用**数据线**（非纯充电线）连接手机，App 会自动弹出
3. 设置页 → 高级 → 开发者选项 → `USB:吞吐测速`，点系统弹窗的「允许」
4. 复制日志发回。日志会列出**每个 USB 设备的每个接口**的
   `class/sub/proto` 与端点数——即使匹配失败也能据此判断该按什么匹配

⚠️ **运行时会占用 USB 接口并打开 PTP 会话**。若此时 Wi-Fi 已连接，相机可能因
"同时只允许一个会话"而断开 Wi-Fi——所以按钮标签里写了"会中断 Wi-Fi"。
测 USB 时请不要先连 Wi-Fi。

**Go 条件**：能 OpenSession + 能读出文件 + 吞吐 ≥ 10MB/s。
**No-Go 应对**：若拿不到接口，先排查 MediaProvider 抢占与相机 USB 模式；
若吞吐远低于预期，说明该机身 USB 只有全速（12Mbps），则本方案价值不成立，
应改为优化 Wi-Fi（5GHz / 厂商高速通道 0x94xx，见交接文档 §7）。

> ⚠️ 这一阶段要务实：**先测速再写架构**。10 倍速度是这个方案的全部意义，
> 拿不到速度就不值得投入 U1–U3。

### U1 · 传输层（2–3 天）

> ⚠️ **2026-09-14 修订：原计划"手写 PtpUsbClient"建议改为"移植 libgphoto2 的 ptp2 模块"。**
> 理由见 §7.6——手写这条路 U0 用了九轮仍未完成，其中三次因错误推断走弯路；
> 业界现成的 Android DSLR 应用走的是 libgphoto2 + NDK 这条路。
> **但前提仍是 §7.5 的判别测试通过：连接保持不住的话换实现也没用。**
> 参考源码已克隆到 `docs/reference/libgphoto2`、`docs/reference/libmtp`，研读结论见 §8。

原计划（保留以记录）：

- 新增 `PtpUsbClient`：12 字节容器头的编解码、事务串行（沿用 `PtpIpClient` 的
  `txnLock` 思路）、分块下载、超时与错误处理
- **复用**：`Ptp.kt` 全部常量、`PtpDatasets.parseDeviceInfo`、`PtpWire.ByteReader`
- 分块下载用标准 `GetPartialObject(0x101B)`；USB 下不必再探测 0x94xx 高速通道
  （那是 Wi-Fi 的补偿手段）
- 把交接文档 §15 学到的教训直接落地：**事务超时即判定传输作废 + 重连**，
  不要在错位的流上继续跑

若坚持手写，§7.4 的六个坑必须先读——尤其是"绝不对 IN 端点 clearHalt"
和"重读间隔不能短"，这两条各花了一轮才找到。

### U2 · 接入与自动选择（2 天）

- 抽出 `PtpSession` 接口（`transact` / `transactStream` / `getObjectToStream` /
  `close` / `deviceInfo` / `eventHandler` / `disconnectHandler`），
  `PtpIpClient` 与 `PtpUsbClient` 各实现一份
- `CameraEngine` 按"有没有 USB PTP 设备"选择传输层；两套共用枚举/下载/遥控的**上层逻辑**
- Dart 侧：连接页增加 USB 入口与引导（相机菜单怎么设）；连接成功后的页面无差别

### U3 · 高速与体验（2–3 天）

- 大块下载 + 流水线（USB Bulk 的连续传输特性适合放大块）
- 断点续传：USB 比 Wi-Fi 稳定，但大文件仍值得做
- 通知栏进度（前台服务与权限已就绪）
- 探索 USB 下的实时取景：若操作集放行 0x92xx，取景画质可能远超现在的 640×424
  （Wi-Fi 下取景流被压在 640×424/33KB，见交接文档 §14）

---

## 4. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| **手机只有一个 USB-C 口**：插上 OTG 设备后无法同时连电脑，adb 断开 | **高（已实际发生）** | 这不是故障。验证只能靠 App 内日志面板（这正是日志面板的用途）。若必须看 logcat，需用无线 adb（`adb tcpip 5555`）或等测完再插回电脑 |
| **小米/部分 ROM 有独立 OTG 总开关**，默认可能关闭且会自动关闭 | **高** | 设置 → 更多设置 → OTG 连接。关着时 USB 主机侧枚举不到任何设备，与"应用没反应"的现象完全相同——探针已对"设备数为 0"给出这条分诊提示 |
| 部分 ROM 不自动拉起 `USB_DEVICE_ATTACHED` 意图 | 中 | 不影响测速：探针主动枚举 `UsbManager.deviceList`，与自动拉起无关，手动打开 App 点按钮即可 |
| 相机停留在「连接至智能设备」模式，USB 口只供电 | 中 | 需退回普通拍摄模式；该模式下不会暴露 PTP 接口 |
| 该机身 USB 只是全速（12Mbps ≈ 1MB/s），速度优势不成立 | 高 | U0 先测速再投入；不达标就转去做 Wi-Fi 高速通道与 5GHz |
| 相机不给 Still Image 接口（只暴露厂商私有类） | 中 | U0 会打印每个设备的每个接口的 class/sub/proto，据此调整匹配；当前匹配已放宽为 class6/sub1 任意 protocol |
| MediaProvider / 系统 MTP 服务抢占接口 | 中 | `claimInterface(force = true)`；必要时监听 `ACTION_USB_DEVICE_DETACHED` 重试 |
| USB OTG 供电：手机作为主机不充电，长传输耗电 | 中 | 引导文案提示；长任务配合前台服务与 WakeLock（已具备） |
| 尼康是否要求 USB 下也有厂商握手 | 中 | U0 直接试标准 OpenSession；不通再查 libgphoto2 的 nikon usb 实现 |

---

## 5. 与现有代码的关系

- **不动**：枚举、下载去重、MediaStore/SAF 落盘、UI、诊断日志、遥控逻辑（都是传输无关的）
- **抽接口**：`CameraEngine` 里对 `PtpIpClient` 的直接依赖（`client` 字段的多处使用）
- **新增**：`PtpUsbClient`、USB 权限与设备监听、连接页的 USB 入口
- **可删的复杂度**：USB 路径不需要 `parseCheckEvents` 排水、不需要 `resolveDlMode`
  的 0x94xx 探测、不需要握手重试与 GUI D 伪装——这些全是 Wi-Fi 智能设备模式的补偿

---

## 6. 我对优先级的建议

> ✅ **2026-09-15 更新：判别测试与测速均已完成，本节早期的保守建议已过时，保留以记录判断过程。**

原建议：*USB 的价值最大，但先把 U0 做完再决定是否继续——速度是唯一的意义，而速度只能实测。*

**实测结果（判别测试 + 测速全部完成）**：

- **相机插电脑（同线）连接稳定** → 相机与线材无问题；
- **手机屏幕常亮**与否无影响 → 排除熄屏 autosuspend；
- **相机的「上传优先 / 拍摄优先」模式无差异** → 排除相机侧状态机；
- **实测吞吐 27.1 MB/s**（174MB 全量、字节校验一致）→ **速度问题彻底回答，U1 值得做**；
- 遗留：手机侧空闲期的重枚举循环仍未根除（dumpsys num_connects=661，
  严格周期 3.4s 断 / 3.65s 挂），疑与 OTG 供电有关，**待带外供电 OTG 集线器验证**；
  活跃传输期间连接保持住，恢复机制（等重现/重授权/重试）已实战可用。

**当前建议**：直接推进 U1/U2（传输层产品化），传输设计上把"中断续传"当作一等公民；
并行验证带外供电 OTG 是否根除空闲循环。

---

## 7 · U0 实测记录（2026-09-14）· 必读

**一句话：协议帧格式已验证正确；GetDeviceInfo 收不到数据是探针自己的读缓冲 bug（已修复待复测）；
真正的环境级卡点只剩相机每 ~3.6 秒重枚举。**

排查共九轮真机日志 + 一轮源码研读（结论见 §8）。下面把"已经验证正确、别重做"
和"卡在哪、下一步做什么"分开写清楚。

### 7.1 已验证正确（这些不用再怀疑）

| 项 | 实测结论 |
|---|---|
| 相机是否暴露 PTP | ✅ **是**。`vid=0x04B0 pid=0x0455`，接口 `class=0x06 sub=0x01 proto=0x01`——「MTP/PTP」档位下就是标准 PTP Still Image 接口 |
| 接口占用 | ✅ `claimInterface(force=true)` 成功，系统 MTP 服务未阻止 |
| 端点布局 | `0x81` Bulk IN(512) / `0x02` Bulk OUT(512) / **`0x83` Interrupt IN(8)**。中断端点即事件通道，USB 下事件监听应走它，不必占用 Bulk IN |
| **容器帧格式** | ✅ **逐字节验证正确**，原始字节见下 |
| 会话控制 | ✅ `OpenSession` / `CloseSession` 往返 **1 毫秒**，响应正确 |

帧格式原始日志（发 OpenSession）：

```
→ 10 00 00 00 01 00 02 10 01 00 00 00 01 00 00 00
   └ 长度16 ┘ └类型1┘ └码0x1002┘ └事务号1┘ └参数1 ┘
← 0C 00 00 00 03 00 1E 20 01 00 00 00
   └ 长度12 ┘ └类型3┘ └码0x201E=SessionAlreadyOpen┘ └事务号1┘
```

12 字节容器头 `长度 u32 + 类型 u16 + 码 u16 + 事务号 u32`（小端），类型 1=命令 2=数据 3=响应 4=事件。
**这一层完全正确，不要再动。**

### 7.2 卡点一：相机每 ~3.6 秒重新枚举（最致命）

`dumpsys usb` 的 host_manager 里能看到严格周期的换址：

```
003 脱离 t=739181 → 004 挂上 t=742559 (+3378ms) → 004 脱离 t=746221 (+3662ms)
→ 005 挂上 t=749581 (+3360ms) → 005 脱离 t=753238 (+3657ms) → 006 挂上 …
```

**挂上后稳定 3.6 秒脱离，脱离后稳定 3.4 秒重挂，周期约 7 秒，误差仅几十毫秒。**
地址一路从 003 涨到 008。这么规整的周期排除了供电异常（供电问题不会这么准），
是**超时驱动的重试循环**——相机在等一个握手，等不到就断开重来。

后果有两条，都很致命：

1. **任何 `UsbDeviceConnection` 都活不过一个窗口**。设备地址一变，句柄即失效，
   所有 `bulkTransfer` 返回 `-1`，且**清除端点 STALL 无效**（因为不是端点问题）。
2. **Android 的 USB 授权绑定在设备实例上**。每次重枚举都要重新授权——
   这可能就是每次探测窗口都不够用的原因。

> **2026-09-15 复测补注**：读缓冲修复后的首次完整探测**全程未被打断**（日志里没有出现
> 重枚举恢复的痕迹，OpenSession → GetDeviceInfo → 枚举存储一气呵成）。这与"周期性断开
> 是相机等不到主机 ACK 的表现"的推断一致——主机真正开始收数据后，循环就停了。
> 但单次成功还不能下结论，需要后续长会话（下载整个卡）继续观察。

### 7.3 卡点二：GetDeviceInfo"被稳定拒绝"——真因已定位（是我们自己的 bug）

当时的记录与解读：

```
→ 发命令 0x1001 txn=2（GetDeviceInfo）
   ……每 200ms 重读一次……
← 1.8 秒后 收容器 len=12 code=0x2007（IncompleteTransfer），**且完全没有数据阶段**
```

当时怀疑相机拒绝，或 `com.android.mtp`（Android 的 MTP 主机栈）在抢 IN 端点。

**2026-09-14 对照 libgphoto2/libmtp 源码重审后，真因定位：探针读容器头用的是 12 字节缓冲。**

USB 是包式协议：数据相位的第一个 USB 包是完整的一个高速整包（**512 字节**）。
主机的 URB 缓冲只有 12 字节时整包装不下 → 控制器报 babble/overflow，**包被丢弃、
不给设备 ACK，设备收不到 ACK 会永远重发同一个包**。由此所有旧现象都有了统一的解释：

- `OpenSession`/`CloseSession`（响应恰好 12 字节）能 1ms 秒回——包装得下；
- 所有需要数据阶段的操作（GetDeviceInfo 等）一个字节都收不到；
- "瞬间返回 -1"正是 overflow 立即完成 URB 的表现，不必再归因于 mtp 抢端点；
- 1.8 秒后的 `0x2007`：相机等不到 ACK、自己放弃数据阶段后回的错误响应（12 字节，恰好装得下）；
- 参考实现（libgphoto2 `ptp_usb_getpacket`、libmtp 同族函数）**首包一律按 maxPacket 整包读**，
  读多出的字节缓存起来供下一轮使用——正因如此它们从不会踩这个坑。

**修复**（`PtpUsbProbe.kt` 的 `readFully`）：任何一次 `bulkTransfer` 的缓冲都不小于
端点 maxPacket（512B）；一次收到但超出本次所需的字节（跨容器背靠背到达）存入余料缓冲按序续用。

**✅ 2026-09-15 复测通过**：修复后首次实测，GetDeviceInfo 完整收到并解析出
机型（Nikon Corporation Z50_2 vV1.02）、126 个操作集、26 个事件集、0x92xx 段 12 个操作——
**本卡点消除，协议层全通**。九轮真机排查的方向性错误到此闭环：
问题从来不在相机侧，也不在系统 MTP 栈，在我们自己的读缓冲。

### 7.4 七个坑（都踩过，按重要性）

1. **读缓冲必须 ≥ 端点 maxPacket（最重要，最后才发现）。** USB 是包式协议，
   12 字节缓冲永远装不下 512 字节的数据包 → 丢包 + 设备永远重发。
   详见 §7.3。此前九轮排查一直以为问题在相机侧或系统侧，方向就错了。
2. **绝不能对 IN 端点做 clearHalt。** `CLEAR_FEATURE(ENDPOINT_HALT)` 会复位端点并
   **丢弃设备正在发送的数据**，相机随即回 `0x2007 IncompleteTransfer`。等于"清一次丢一次"。
   （注：libgphoto2 在能区分出 STALL/IO 错误时会清一次并重试一次；Android 的
   `bulkTransfer` 无法区分错误类型，一律返回 -1，所以我们保持"从不清 IN"更安全。）
3. **重读间隔不能短。** `bulkTransfer` 底层是 `USBDEVFS_BULK` ioctl，在上一笔传输未完成时
   立刻再发会中止那个 URB。实测：间隔 150ms → +153ms 收到响应；改成 20ms 密集重试 →
   **2 秒一个字节都收不到**。用 **200ms 间隔**。
4. **事务号不能归零。** PTP 里 `OpenSession` 自己就占一个事务号，
   归零会让紧随其后的操作与它**撞号**，相机以 `IncompleteTransfer` 拒绝。
   同一连接内保持单调递增。
5. **`CloseSession` 会扰动 USB 端点**，之后下一笔命令可能直接发送失败（-1）。
   能不调就不调；仅在必要时作为降级路径。
6. **`bulkTransfer` 在无数据时立刻返回 -1，并不遵守传入的超时**（实测传入 5000ms，
   实际 2ms 就返回）。**重读循环才是真正的等待机制**，不能靠超时判定失败。
7. **响应码名称表曾与标准不符**（0x2007 被标成 "ParameterBad"）。
   按 ISO 15740：0x2007 = `IncompleteTransfer`、0x2008 = `InvalidStorageId`、
   0x200D = `ObjectWriteProtected`、0x201D = `InvalidParameter`。已修正，排查时以标准码为准。

### 7.5 判别测试结果（2026-09-15，全部完成）

**① 复测 USB 探测——✅ 完成，且拿到最终数字。**
修复三连（读缓冲→目录递归→大文件容器头）后，
**GetObject 全量下载 174MB 的 DSC_3825.MOV：实测 27.1 MB/s，字节校验一致**。
U0 的唯一关键问题"USB 到底快不快"就此回答：**值得做**。

**② 相机插电脑（同线）——✅ 稳定。**
相机与线材排除，问题收敛到手机侧。dumpsys 实锤空闲态重枚举循环：
`num_connects=661`，严格周期 3.4s 断 / 3.65s 挂；
**但活跃传输期间连接保持住**（174MB / 约 7 秒中途未断）——循环是空闲态行为。

**③ 相机「上传优先 / 拍摄优先」模式 A/B——无差异**，相机侧状态机排除；
手机屏幕常亮与否也无影响（熄屏 autosuspend 排除）。

**剩余嫌疑（U1 期间并行验证）**：手机 OTG 供电管理（MIUI 类机型的 OTG
自动关闭/电流保护）——**带外供电 OTG 集线器是决定性实验，也顺带成为
实际使用时的推荐配置**；MTP 主机栈干扰（无 root 不可控，恢复机制已可兜底）。

### 7.6 工作量重估（U1 方案需要改）

**手写 PTP-over-USB 的成本远超最初的估计。** U0 定位是"1–2 天的决策点"，
实际用了九轮仍未完成，期间三次因错误推断走弯路（事务号归零、clearHalt、密集重试）。

原 U1 计划是"新增 `PtpUsbClient`"。**建议改为移植 libgphoto2 的 `ptp2` 模块（NDK 编译）**：
它是跨尼康多机身验证过的实现，现成的 Android DSLR 应用（qDslrDashboard、Helicon Remote）
走的正是这条路，会把会话怪癖、重连逻辑、实时取景、厂商操作码一起带过来，
把"协议正确性"这个风险整体转移掉。代价是引入 C 依赖、构建链路变复杂。

**但前提是 §7.5 的判别测试通过**——连接保持不住的话，换实现也没用。

### 7.7 本轮产出的可复用资产

- `PtpUsbProbe.kt`：设备枚举 / 权限 / claim / 12 字节容器收发 / 逐字节十六进制取证，
  以及重枚举恢复（`reopenAfterEnumeration`）与带恢复的命令执行（`commandRecovering`），
  这些与"速度"无关但都是 U1 需要的基础件。
  **2026-09-14 修复**：`readFully` 改为按 maxPacket 整包读 + 余料缓冲（§7.3），
  这是后续一切测试的前提。
- `Ptp.kt` 的响应码名称表已按 ISO 15740 修正
- 诊断入口：设置页 → 高级 → 开发者选项 → **USB 连接（实验）**，
  结果直接显示在卡片里并可一键复制
- **无线 adb 工作流**：手机只有一个 USB-C 口，插相机时电脑 adb 必断。
  用 `终端开启无线调试` 后 `adb connect <手机IP>:<端口>`，
  之后装机（`adb -s <ip:port> install`）与读日志（`adb -s <ip:port> logcat -s NikonSync`）
  都走 Wi-Fi，不必再拔插电脑线。**这个工作流强烈建议保留。**
- **参考源码已就位**：`docs/reference/libmtp/`、`docs/reference/libgphoto2/`（均 gitignored），
  研读结论见 §8。

---

## 8 · 源码研读结论（2026-09-14）

读了三份业界实现的事务层：`libgphoto2/camlibs/ptp2/usb.c`（688 行）、
`libmtp/src/libusb1-glue.c`、`libgphoto2/libgphoto2_port/libusb1/libusb1.c`（错误映射）。
这些是 qDslrDashboard、Windows/Linux 全平台 gphoto2 共用的代码，权威性足够。

### 8.1 事务层的参考数字（U1 手写或移植都以它为准）

| 事项 | 参考实现的做法 | 对我们的意义 |
|---|---|---|
| 首包读取 | 按 **maxPacket 整包**读，多余字节缓存下轮用 | 已照抄进 `readFully`（§7.3） |
| 读超时 | libmtp 默认 **20 秒**、长传输 60 秒 | 我们的 3 秒重读窗口偏紧，但探测阶段够用 |
| 读取分块 | libgphoto2 512KB 且按 maxPacket 对齐；长度未知（0xffffffff）时逐 512 读到短包为止 | U3 大文件下载照此设计 |
| 发送终止 | 发送总长恰好是 maxPacket 整数倍时**补一个零长包**（ZLP） | U1 做上传（SendObject）时必须 |
| 错误分类 | libusb 能区分 TIMEOUT / PIPE(STALL) / OVERFLOW / NO_DEVICE；**只有非超时 IO 错才清一次 halt 重试一次**，超时从不清 | 印证"不清 IN 端点"；也说明 Android 的 `-1` 无差别返回是信息损失，NDK+libusb 有额外价值 |
| 类请求 | Cancel=0x64、GetExtEvent=0x65、DeviceReset=0x66、GetDeviceStatus=0x67 | Android 上用 `controlTransfer` 即可发，U1 可用 |
| 事件端点 | 中断端点 150ms 快速超时轮询 | 与我们 Wi-Fi 事件通道思路一致 |

另外 AOSP 自带 MtpDevice 源码里有句注释："**USB reads greater than 16K don't work**"——
在 Android 上单次 bulk 读别超过 16KB 为稳（libgphoto2 的 512KB 大块在桌面 Linux 无碍，
在 Android 上要保守些；U3 测速时用 16KB 与更大块各测一轮对比）。

### 8.2 走 NDK + libgphoto2 的接入要点（非 root）

- libusb ≥ 1.0.24：`LIBUSB_OPTION_NO_DEVICE_DISCOVERY` + `libusb_wrap_sys_device(fd)`
  直接接管 Android `UsbDeviceConnection` 传来的文件描述符（issue #683 定稿的方案）；
- 依赖 libltdl（libtool），PR #918 附了四架构构建脚本；Manifest 需 `extractNativeLibs=true`；
- 把 fd 交给 `gp_port_usb_set_sys_device(fd)` 后再 `gp_camera_init()`；
- 现成参考：`thebino/libgphoto2android`（构建 walkthrough）、qDslrDashboard 的
  `DslrDashboardServer`（PTP/USB 帧转发实例）。

### 8.3 环境注记（Windows 构建机）

本机 `FLUTTER_STORAGE_BASE_URL` 指向清华镜像，而**该镜像缺当前引擎版本的
`flutter_embedding_debug` jar（404）**，构建会挂在 `:jni` 依赖解析上。
临时解法：构建前覆盖为官方中国镜像——

```bash
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn flutter build apk --debug
```

若后续换 Flutter 版本再遇到，先 `curl -sI` 验一下镜像上有没有对应 jar。
