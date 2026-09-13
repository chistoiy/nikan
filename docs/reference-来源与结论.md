# 协议参考资料（不入库）

本目录下的第三方参考文件**不提交到仓库**（已加入 .gitignore），仅本地保留。
如需重新获取，可从以下来源下载：

| 文件 | 来源 |
|---|---|
| wmu_audit.md | https://github.com/subhashraveendran/aero-shutter/blob/main/WMU_PARITY_AUDIT.md |
| internal_ptpip_*.go / gateway.go / scan.go / internal_camera_profile.go | https://github.com/subhashraveendran/aero-shutter/tree/main/internal （ptpip / camera 目录）|
| mobile_src_lib_ptpip_*.ts | https://github.com/subhashraveendran/aero-shutter/tree/main/mobile/src/lib/ptpip |

## 本地已实测确认的关键结论（摘录）

- Z50 II 智能设备 Wi-Fi 模式操作码映射：
  - `0x9201` 启动取景态 / `0x9206` 关闭 / `0x9203` 取景帧（40~73KB JPEG）/ `0x9405` 取景中拍摄（对焦优先检查）
  - `0x90C3` AF 驱动（非取景态）/ `0x9400` 三参数返回 0xA004 OutOfFocus（疑似带对焦检查的拍摄类）
  - `0xA004`=OutOfFocus、`0xA00B`=NotLiveView（厂商响应码）
  - 标准事件 socket 可收到 ObjectAdded/DevicePropChanged；厂商队列 0x90C0/0x90C1 被拒绝
- 完整背景见 `docs/AI交接文档.md` 第 5/7 节。
