# USB 连接模式方案（重点：高速下载）

> 日期：2026-09-14 · 状态：待验证 · 前置结论见第 1 节
> 目标读者：接手开发的人。第 1 节给出结论，第 2 节说明为什么成立，第 3 节给可执行的阶段划分。

---

## 1. 结论先行

**值得做，而且这是唯一能把"传照片"从"等"变成"几秒完事"的路径。**

| | 现在的 Wi-Fi 路线 | USB 路线（预估） |
|---|---|---|
| 实测/预估吞吐 | **2.4 MB/s**（README 记载，已接近 2.4G 热点物理上限） | **25–35 MB/s**（USB 2.0 高速理论 480Mbps） |
| 传 30MB 的 NEF | ~12 秒 | ~1 秒 |
| 传满 1500 张 / 约 30GB | **~3.5 小时** | **~20 分钟** |
| 会话稳定性 | 单会话、超时即作废（见交接文档 §15） | 无握手、无会话竞争 |
| 相机操作集 | 126 个操作（智能设备模式被裁剪） | 可能更大，**实时取景等 Wi-Fi 下被封禁的能力有机会解锁** |

**复用边界极其有利**：`Ptp.kt`（操作码/响应码常量）、`PtpDatasets.kt`（数据集解析）、
`PtpWire.kt`（ByteReader）**全部与传输层无关，可以原样复用**。
要新写的只有传输层本身，以及把 `CameraEngine` 对客户端的依赖抽成接口。

这正是技术方案 §8 里写的兜底路径——"协议事务层代码完全复用，仅换传输层"。

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

1. **相机 USB 模式设为 PTP**：尼康机身在菜单里有 USB 连接模式选项。若停留在 MTP，
   Android 会把它当媒体设备交给 MediaProvider，我们拿不到接口。
2. **退出"连接至智能设备"模式**：Wi-Fi 与 USB 是两条互斥的连接路径，
   需要用户在相机上切过去（App 里要给明确引导）。
3. **Android 侧**：需要 `android.hardware.usb.host` 特性；minSdk 29 已足够，
   `UsbManager` / `bulkTransfer` 从 API 12 就有。

---

## 3. 分阶段计划

每阶段都有明确的 Go/No-Go，避免在错误方向上堆代码。

### U0 · 打通与测速（1–2 天）· 决策点

**唯一目标：拿到真实的 MB/s，以及确认能否 PTP 会话。**

> **状态：已实现，待测。** 入口在设置页 → 高级 → 开发者选项 → `USB:吞吐测速`。
> 一次运行会把下面四项结论全部写进日志，复制日志即可判断方案是否成立。

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
1. 相机菜单把 USB 模式设为 **PTP**（不是 MTP），并退出「连接至智能设备」
2. 用**数据线**（非纯充电线）连接手机，App 会自动弹出
3. 设置页 → 高级 → 开发者选项 → `USB:吞吐测速`，点系统弹窗的「允许」
4. 复制日志发回

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

- 新增 `PtpUsbClient`：12 字节容器头的编解码、事务串行（沿用 `PtpIpClient` 的
  `txnLock` 思路）、分块下载、超时与错误处理
- **复用**：`Ptp.kt` 全部常量、`PtpDatasets.parseDeviceInfo`、`PtpWire.ByteReader`
- 分块下载用标准 `GetPartialObject(0x101B)`；USB 下不必再探测 0x94xx 高速通道
  （那是 Wi-Fi 的补偿手段）
- 把交接文档 §15 学到的教训直接落地：**事务超时即判定传输作废 + 重连**，
  不要在错位的流上继续跑

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
| 该机身 USB 只是全速（12Mbps ≈ 1MB/s），速度优势不成立 | **高** | U0 先测速再投入；不达标就转去做 Wi-Fi 高速通道与 5GHz |
| 相机不给 PTP，只暴露 MTP | **高** | U0 确认；MTP 也能读文件但与 PTP 语义不同，等于另做一套，先不做 |
| MediaProvider / 系统 MTP 服务抢占接口 | 中 | `claimInterface(force = true)`；必要时监听 `ACTION_USB_DEVICE_DETACHED` 重试 |
| USB OTG 供电：手机作为主机不充电，长传输耗电 | 中 | 引导文案提示；长任务配合前台服务与 WakeLock（已具备） |
| 相机需要先退出 Wi-Fi 智能设备模式 | 低 | 引导页写清菜单路径，与现有 Wi-Fi 引导对称 |
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

USB 的价值最大，但**先把 U0 做完再决定是否继续**——速度是唯一的意义，而速度只能实测。
U0 只依赖一台相机和一根 USB 线，不需要动现有架构。

若 U0 测出来是 25MB/s 以上，建议立刻按 U1→U3 推进，这会成为这个 App 最有说服力的功能：
**插上线，整卡备份，二十分钟。**
