# GPS 轨迹与 GPX

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文定义录音期间的位置记录、存储、隐私与 GPX 导出。产品决策见 `../decisions/0005-gps-tracking.md`；24h 组合门禁见 `24h-feasibility.md`。
>
> 实现状态（2026-10-29）：Watch 5 分钟采样、JSONL 落盘与启动续写、iPhone 导入校验与 GPX 导出已实现；FR-024 设置页提供全局定位开关（iPhone↔Watch 以 `updatedAtMs` 最后写入优先）、Watch 权限状态与轨迹占用显示；轨迹可单独删除，写 `location` 墓碑并经 WatchConnectivity 让 Watch 停止定位写入、删除轨迹文件，音频不受影响；`TrackImporter` 同时检查 session/location 墓碑与 DataEpoch；会话详情内嵌系统 MapKit 轨迹预览（折线 + 起终点，自动取景），坐标仅在本地读取。真机后台定位、离线地图瓦片、G-002 组合续航未验证。

## 1. 目标与非目标

**目标**

- 在录音会话期间记录位置轨迹，与音频时间轴对齐。
- 首次授权后，定位**默认随录音开启**；设置中可全局关闭；不每次询问。
- 轨迹默认只存本地，用户可按需导出 GPX 1.1。
- 定位失败、权限被拒、室内无信号时，录音不受影响，UI 明确降级。
- 控制功耗，避免 GPS 成为 24h 目标的主要瓶颈。

**非目标（MVP）**

- 实时位置共享、云端轨迹、地理围栏。
- 地点自动命名（家/公司/餐厅）。
- 轨迹回放动画、热力图。
- 用 iPhone 全程替代 Watch GPS。

## 2. watchOS 平台约束

以下结论来自 Apple 文档与开发者社区，**最终以目标 watchOS 版本真机实测为准**。

### 2.1 授权

- watchOS 实际上没有可用的 “Always” 授权流程；不要请求 `requestAlwaysAuthorization()`。
- 使用 **When In Use** 授权；权限被拒时录音继续，轨迹标记为不可用。
- 不要在启动时反复弹权限；只在用户首次开启定位或主动进入设置时请求。

### 2.2 后台定位

- 需要声明 Location Updates 后台能力，并设置 `allowsBackgroundLocationUpdates = true`。
- 定位 **MUST** 在应用前台启动；后台只能延续。
- 在后台不能随意停止并重启定位；需要按会话持续运行。
- 若目标系统提供 `CLBackgroundActivitySession`，在**前台**创建；应用被后台重启时立即重建。具体可用性以目标 SDK 为准。
- `HKWorkoutSession` 可以延长后台与高精度定位，但会影响 Activity 圆环与审核解释；**不作为默认方案**，仅在 G-002 失败且用户确认后评估。

### 2.3 模拟器

模拟器可以模拟位置，但不能验证真实 GPS 功耗、信号遮挡、后台调度与热行为。**G-002 必须真机。**

## 3. 采样策略

目标是“足够还原一天的行踪”，不是运动级轨迹。

| 场景 | 采样 | 精度 | 说明 |
| --- | --- | --- | --- |
| 移动/静止 | **每 5 分钟一个点** | `kCLLocationAccuracyBest` | 高精度、低频率（Q-019） |
| 低电量模式 | 每 5 分钟 | `kCLLocationAccuracyHundredMeters` | 保持频率，降低精度 |
| 热状态 `serious` | 每 5 分钟 | `HundredMeters` | 防热保护 |
| 热状态 `critical` | 暂停定位，录音按策略处理 | — | 安全优先 |

规则：

- 采用 5 分钟定时采样；`distanceFilter = kCLDistanceFilterNone`，不按距离触发。
- 只存储 `horizontalAccuracy.isFinite && horizontalAccuracy >= 0 && horizontalAccuracy <= 100` 的点；负值/NaN/无穷视为无效，直接丢弃；`50–100m` 标记为低置信度。
- 时间戳用 UTC 毫秒；GPX 输出 ISO 8601。
- 位置点与录音会话共用开始时间；录音暂停时暂停定位，恢复时继续。
- 定位不可用时，轨迹状态为 `degraded` 或 `unavailable`，不伪造点。

## 4. 数据模型与存储

### 4.1 LocationTrack（元数据）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 主键 |
| `sessionID` | UUID | 外键 → RecordingSession，一对一 |
| `startedAt` / `endedAt` | Date | 轨迹起止 |
| `source` | String | `watch` / `iphone`（MVP 仅 watch） |
| `state` | TrackState | 见 §4.3 |
| `pointCount` | Int | 点数 |
| `distanceMeters` | Double? | 估算总距离 |
| `relativePath` | String | JSONL 相对路径 |
| `createdAt` / `updatedAt` | Date | 审计字段 |

### 4.2 LocationPoint（JSONL 行）

```json
{"t":1761700000000,"lat":31.2304,"lon":121.4737,"alt":12.3,"hAcc":8.5,"vAcc":4.0,"speed":1.4,"course":87.2}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `t` | Int64 | UTC 毫秒 |
| `lat` / `lon` | Double | WGS84 |
| `alt` | Double? | 海拔（米） |
| `hAcc` | Double | 水平精度（米） |
| `vAcc` | Double? | 垂直精度（米） |
| `speed` | Double? | 米/秒 |
| `course` | Double? | 度，0–360 |

### 4.3 TrackState

```text
recording ──stop──> completed
    │
    ├──permissionDenied──> unavailable
    ├──noFix/indoors──────> degraded
    ├──interrupted────────> interrupted ──resume──> recording
    └──fatal──────────────> failed
```

- `degraded`：仍有少量点，但覆盖不足；UI 显示“轨迹不完整”。
- `unavailable`：无权限或定位服务关闭；录音继续。
- `interrupted`：后台定位被系统暂停；恢复后继续写，不补造点。

### 4.4 文件布局

```text
<Application Support>/AkaMemo/
└── location/
    └── 2026/10/28/<sessionUUID>.jsonl
    └── 2026/10/28/<sessionUUID>.gpx    # 导出缓存，可删除
```

- JSONL 追加写入；每条一行，崩溃后最多丢失最后一行。
- 写入用 `FileHandle`，每 10 个点或每 60s `synchronize` 一次；会话结束时关闭并 rename `.part`。
- 文件名只含 UUID；**MUST NOT** 含地点名、地址或用户内容。

## 5. 传输

- Watch 端轨迹文件在**会话结束后**通过 `WCSession.transferFile` 传输；长会话可每 5 分钟传一次增量快照（实现时二选一，需评估复杂度）。
- 元数据包含：`sessionID`、`sessionStartedAt`、`trackID`、`pointCount`、`startedAt`、`endedAt`、`checksum`。
- iPhone 收到后校验行数、时间单调性、经纬度范围；重复文件按 `trackID + checksum` 去重。
- `TrackImporter` **MUST** 在导入前依次检查：
  1. `DeletionTombstone(entityType=session)`（按 sessionID）；
  2. `DeletionTombstone(entityType=location)`（按 sessionID/trackID）；
  3. `DataEpoch`（按 `sessionStartedAt < epoch`）。
  任一命中则丢弃并回执，不得重建。
- 删除轨迹时写 location 墓碑并发送删除指令；Watch 删除本地轨迹与传输队列条目，重连后不得补传。
- 传输失败不影响录音；Watch 保留文件直到确认。
- 删除确认后，Watch 可清理轨迹文件；未确认不清理。

## 6. GPX 导出

- 导出时从 JSONL 生成 GPX 1.1；不把 GPX 作为唯一存储。
- 结构：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="AkaMemo"
     xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>AkaMemo 2026-10-28 08:00</name>
    <time>2026-10-28T00:00:00Z</time>
  </metadata>
  <trk>
    <name>AkaMemo 2026-10-28 08:00</name>
    <trkseg>
      <trkpt lat="31.2304" lon="121.4737">
        <ele>12.3</ele>
        <time>2026-10-28T00:00:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
```

- 文件名：`AkaMemo-<yyyyMMdd-HHmm>-<sessionUUID 前 8 位>.gpx`；不含地点。
- 导出前 **MUST** 显示隐私提示：GPX 会暴露你去过的地方，分享前请确认。
- 导出通过系统分享面板；应用不自动上传。
- Q-021 已定：GPX 导出按选中会话/片段的**开始与结束时间裁剪**，不导出会话外轨迹；首点允许 ≤5 分钟延迟。

## 7. 权限与隐私

- 需要 `NSLocationWhenInUseUsageDescription`，文案具体说明“录音时记录位置，默认只存本机”。
- 首次授权后，定位**默认随录音开启**；**不每次询问**；设置中 **MUST** 提供全局关闭开关。
- 关闭全局开关后，**当前会话 MUST 立即停止新增位置点**，所有新会话 **MUST NOT** 采集；已有轨迹保留，直到用户删除。
- 录音界面 **MUST** 显示定位状态（开启/关闭/无权限/降级），避免用户不知情。
- 不申请 “Always”；不申请精确位置以外的无关权限。
- 定位只在录音会话期间运行；不在后台常驻追踪。
- 轨迹属于**极高敏感**数据：与录音同级。
- 日志、分析、崩溃上报 **MUST NOT** 包含经纬度、地点、轨迹文件内容。
- 删除录音时级联删除 JSONL、GPX 缓存与数据库元数据。
- 默认不上传；若未来引入云端，需单独 ADR 与隐私评估。
- App Store 隐私标签需如实披露位置数据（仅本地 vs 云端路径要区分）。

## 8. 失败与降级

| 情况 | 行为 |
| --- | --- |
| 用户拒绝定位权限 | 录音继续；轨迹 `unavailable`；UI 提示可在设置开启 |
| 定位服务关闭 | 同上 |
| 室内/地下无信号 | 轨迹稀疏或为空；状态 `degraded`；不报错刷屏 |
| 后台定位被系统暂停 | 记录 `interrupted`；恢复后继续；UI 显示缺口 |
| 磁盘满 | 停止写轨迹；录音按录音策略处理；提示清理 |
| 轨迹文件损坏 | 保留可解析部分；标记损坏；不删除录音 |
| 传输失败 | Watch 保留；退避重试；不阻塞录音 |
| 已删除轨迹补传 | TrackImporter 检查 session/location 墓碑与 DataEpoch；拒绝并回执；不重建 |

## 9. G-002 门禁：24h 录音 + GPS

### 9.1 通过标准

在 G-001（24h 录音）通过的基础上，同时满足：

| # | 标准 | 判定 |
| --- | --- | --- |
| 1 | 音频仍满足 G-001 | 24h 连续、0 丢失/损坏、设备未关机 |
| 2 | 户外移动轨迹覆盖 | 每 5 分钟至少 1 点；移动中缺口 ≤6 分钟；户外移动窗口覆盖 ≥90% |
| 3 | 精度 | 水平精度中位数 ≤ 30m；90 分位 ≤ 100m |
| 4 | GPX 有效 | 能被常见 GPX 查看器解析；时间单调；坐标合法 |
| 5 | 电量 | 24h 结束电量 ≥ 5% **且**设备未关机 |
| 6 | 文件规模 | 24h 轨迹 JSONL ≤ 20 MB；GPX 可正常导出 |
| 7 | 可复现 | 主设备至少 1 次通过；至少 2 种设备/系统组合通过 |

任一失败 → G-002 失败，按 §10 处理。

### 9.2 测试条件

- 户外路线：包含步行、停留、室内进出、城市峡谷/树荫。
- 至少一段 2 小时连续户外移动。
- 对比组：关闭 GPS 的 G-001 结果。
- 低电量模式一组。
- iPhone 在旁 / 不在旁各一组。
- 24h 测试期间不充电。

### 9.3 结果记录

```text
日期：
设备/系统/电池健康：
路线与时长：
GPS 开关 / 低电量模式 / iPhone 在旁：
录音结果：时长 <> / 丢失 <> / 损坏 <>
轨迹结果：点数 <> / 覆盖 <>% / 缺口 <> / 精度中位数 <> / 90 分位 <>
GPX：可解析 / 否；大小 <>
电量：开始 <>% / 结束 <>%
结论：通过 / 失败
备注：
```

## 10. 失败处理

1. 记录失败点：功耗、后台调度、权限、信号、热、存储。
2. 逐项缓解（一次只改一个变量）：
   - 降低采样频率与精度；
   - 静止时改为 5–10 分钟心跳；
   - 关闭低价值日志/动画；
   - 评估 `CLBackgroundActivitySession`；
   - 评估 Workout Session（需 ADR 与用户确认）；
   - 评估 iPhone 辅助定位（Watch 无 GPS 时）。
3. 仍失败：写入 ADR-0005，由用户决定是否把 GPS 改为可选、降低 24h 组合目标或引入外接电源。
4. **不得**通过减少轨迹点却仍宣称“全程轨迹”来通过门禁。

## 11. 验证矩阵（真机）

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 户外步行 30 分钟 | 每 5 分钟有点，精度 ≤ 30m 中位数 |
| 2 | 室内 30 分钟 | 轨迹稀疏/为空，状态 `degraded`，录音正常 |
| 3 | 隧道/地下通道 | 缺口可解释，恢复后继续 |
| 4 | 城市峡谷/树荫 | 精度下降但可接受；无异常耗电 |
| 5 | 拒绝定位权限 | 录音正常，轨迹 `unavailable`，UI 提示 |
| 6 | 飞行模式 | 定位按系统能力工作/降级；录音正常 |
| 7 | 低电量模式 | 保持 5min 频率，精度降为 HundredMeters |
| 8 | 锁屏/后台 2 小时 | 定位延续或标记 `interrupted`，不伪造点 |
| 9 | iPhone 不在旁 | 轨迹仍由 Watch 记录 |
| 10 | 24h 录音 + GPS（G-002） | 按 §9.1 通过 |
| 11 | GPX 导出 | 按会话起止裁剪、时间正确、无地点名 |
| 12 | 删除录音 | JSONL、GPX、元数据全部删除 |
| 13 | 默认开启 / 设置中全局关闭 | 授权后默认记录；关闭后当前会话立即停止、新会话不采集；状态可见 |
| 14 | 无效坐标（负精度/NaN/无穷） | 丢弃，不写入轨迹 |

## 12. 验收标准

- 每 5 分钟至少 1 点；移动中缺口 ≤6 分钟；户外移动窗口覆盖 ≥90%。
- 水平精度中位数 ≤ 30m；90 分位 ≤ 100m；负值/NaN/无穷精度的点被丢弃。
- GPX 导出按会话起止裁剪；首点允许 ≤5 分钟延迟。
- 拒绝定位权限时录音不受影响，UI 明确提示。
- 首次授权后默认开启；设置中全局关闭后，当前会话立即停止新增点、新会话不再采集；状态在录音界面可见。
- 删除录音后，轨迹文件、GPX 缓存与元数据全部消失。
- 日志中无经纬度、地址或轨迹内容。
- G-002 通过前，不对外承诺 24h + GPS。

## 13. 参考资料

- Apple Documentation: [Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- Apple Documentation: [Core Location](https://developer.apple.com/documentation/corelocation)
- Apple Developer Forums: [watchOS background location authorization discussion](https://developer.apple.com/forums/profile/bmt22033/replies?sortBy=newest)
- `geolocator_watchos`: [watchOS authorization notes](https://pub.dev/packages/geolocator_watchos)

> 以上资料用于说明约束，不作为验收依据；最终以目标系统版本真机结果为准。实测结论必须回写本文与 ADR-0005。
