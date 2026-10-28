# 低电量告警与 Live Activity

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文定义 Watch 电量 5% 时的 iPhone 高优先级通知、低电量 Live Activity/灵动岛、以及自动暂停策略。产品决策见 `../decisions/0006-low-battery-alerting.md`。
>
> 实现状态（2026-10-28）：Watch 电量监测、5% 事件、3% 安全停止、iPhone 本地 Time Sensitive 通知、前台 Live Activity 与应用内横幅已实现；20%/10% 仅 Watch 应用内文本，未使用 `applicationContext` 快照发布；G-003 未通过。免费个人团队无法配置 Time Sensitive capability，本地真机若使用空 entitlements，系统可能按普通通知处理。

## 1. 目标与非目标

**目标**

- Watch 电量降到 5% 时，让 iPhone 尽快显示高优先级通知。
- 低电量期间，在 iPhone 锁屏/灵动岛尽量展示录音与电量状态。
- 告警不影响录音；失败可见、可诊断、可降级。
- 不引入后端，不泄露音频、转写或位置内容。

**非目标（MVP）**

- 保证 iPhone 被强制退出或不可达时仍即时送达（需要后端 APNs）。
- 承诺 24 小时常驻 Live Activity（系统限制约 8 小时）。
- 未经 Apple 批准使用 Critical Alerts。
- 通过通知控制 Watch 停止录音（可作为后续 App Intent 能力评估）。

## 2. 阈值与状态机

| 阈值 | 行为 |
| --- | --- |
| 20% | 应用内提示，建议充电；录音继续 |
| 10% | 强提示；GPS 降为低电量采样；录音继续 |
| **5%** | **发送 iPhone 高优先级通知；启动/更新 Live Activity；录音继续** |
| 3% | 安全停止：封口当前分片 → 暂停录音；再尝试通知 |
| >10% 且充电 | 重置告警状态，结束 Live Activity |

```text
normal ──20%──> warned ──10%──> low ──5%──> critical ──3%──> stopping ──> stopped
                                                        │
charging >10% <──────────────────────────────────────────┘
```

规则：

- 5% 告警每次跨过阈值只发一次；不要在每次电量变化时重复。
- 充电回到 10% 以上后重置；再次降到 5% 可再次告警。
- 3% 是安全底线；无论用户设置如何都应停止，避免设备突然关机导致分片损坏。
- 5% 只告警、不暂停；MVP 不提供“5% 自动暂停”选项。

## 3. Watch 端监测

- **MUST 先设置 `WKInterfaceDevice.current().isBatteryMonitoringEnabled = true`**，再读取 `batteryLevel`（0–1）与 `batteryState`（unknown/unplugged/charging/full）；在 App 启动/录音开始时设置一次。
- 轮询间隔 60 秒；在录音开始、停止、充电状态变化时立即检查一次。
- 若监测未启用/电量未知：UI 显示“电量监测不可用”，记录日志并重试；**MUST NOT** 静默跳过告警路径。
- 同时读取 `ProcessInfo.processInfo.isLowPowerModeEnabled`，用于降频策略。
- 电量不可用（unknown/负值）时显示“电量监测不可用”、记录并重试开启监测；不得静默跳过告警或误报。
- Watch 本地：
  - 5% 时显示明确警告，并播放触觉提示；
  - 显示“录音继续 / 已暂停”的真实状态；
  - 提供“停止录音”和“继续录音”入口（按策略）。

## 4. Watch → iPhone 传输

- 首选 `WCSession.sendMessage`（iPhone 可达时）；不可达时使用 `transferUserInfo` 排队。`applicationContext` 由 `WatchStatePublisher` 统一写入（心跳+电量+录音状态合并为单一快照）；电池模块 **MUST NOT** 单独写 context。
- 消息负载：

```json
{
  "type": "batteryAlert",
  "eventID": "UUID",
  "sessionID": "UUID",
  "stateVersion": 7,
  "batteryLevel": 0.05,
  "batteryState": "unplugged",
  "recordingState": "recording",
  "alertLevel": 5,
  "recordedAt": 1761700000000,
  "ttlMs": 300000
}
```

- **告警事件与状态快照分开**：事件按 `eventID` 去重；`stateVersion` 只用于快照排序，**MUST NOT** 用于判断告警事件是否过期。
- 告警有效性按 `eventID`（未处理）+ `recordedAt/ttlMs`（未过期）+ **处理时刻最新快照**（电量/充电/录音状态）判断；不同传输通道的到达顺序不可依赖。
- 例：5% 告警 v7 仍在 TTL 内、最新快照仍是 5% 且录音中，即使心跳 v8 先到，也 **MUST** 处理 v7；若最新快照已显示充电/停止/3%，则丢弃。
- `stateVersion` 按 `recording-health.md` §3.3.1 的契约持久化/递增；同一会话跨 Watch 重启不得归零，新会话使用新 `sessionID`。
- 5% 告警 TTL 默认 5 分钟；超过 TTL、或最新快照已出现停止/充电/3% 时，丢弃旧告警，不补发“录音仍在继续”，不启动过时 Live Activity。
- 重连时由 `WatchStatePublisher` 提供最新 `applicationContext` 快照；`transferUserInfo` 中过期告警直接丢弃，不回放历史告警。
- Watch 在状态变为充电/停止/3% 时 **MUST** 取消尚未送达的 5% 告警。
- 消息 **MUST NOT** 包含音频、转写、位置、文件名等敏感内容。
- 传输失败：Watch 保留最新状态并重试；Watch 本地警告仍然显示。

**送达限制（必须向用户说明）**

- 没有后端/APNs 时，这是“Watch 消息 → iPhone 本地通知”，不是远程推送。
- iPhone App 被强制退出、iPhone 不可达、通知权限被拒时，送达可能延迟或不可用。
- 不得在 UI 或营销中承诺“必定送达/警报级”。

> 录音中断/恢复通知复用同一 NotificationService 与 Time Sensitive 通道；见 `recording-health.md`。

## 5. iPhone 通知

### 5.1 权限与级别

- 首次进入设置/引导时请求通知权限（`.alert`、`.sound`）。
- 默认使用 **Time Sensitive**：`content.interruptionLevel = .timeSensitive`。
  - 需要 Time Sensitive Notifications capability；
  - 无需 Apple 单独批准；
  - 可在用户允许时穿透专注模式，但**不绕过静音开关**。
- **MVP 不申请 Critical Alerts entitlement**；统一使用 Time Sensitive。**MUST NOT** 在文案中称其为“警报/关键警报”。
- 后续如确需绕过静音/专注，必须新写 ADR 评估申请；未获批前不得启用或宣传。

### 5.2 内容

- 标题：`Apple Watch 电量仅 5%`
- 正文：`录音仍在继续。请尽快充电，或打开 AkaMemo 停止录音。`
- 3% 版本：`Apple Watch 电量仅 3%，录音已暂停并保存。`
- 分类动作：`打开 AkaMemo`；如后续支持，可增加 `停止录音`。
- **MUST NOT** 包含音频内容、转写文本、位置、文件名。

### 5.3 权限被拒

- 不反复弹窗；设置中显示“通知已关闭”和开启入口。
- 应用内显示低电量横幅；Watch 端警告仍然有效。
- 不得静默失败。

## 6. Live Activity / 灵动岛

### 6.1 属性

```swift
struct BatteryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var batteryLevel: Double
        var batteryState: String
        var recordingState: String
        var startedAt: Date
        var lastUpdated: Date
    }

    var sessionID: UUID
}
```

### 6.2 展示

- 灵动岛紧凑：电池图标 + `5%`。
- 灵动岛展开：`Watch 电量 5%`、`录音中 03:12`、`未充电/充电中`。
- 锁屏：与展开态一致，低电量使用警告色；不使用红色以外的误导性“警报”标识。
- 无灵动岛的设备：使用锁屏 Live Activity；不支持 Live Activity 的系统：使用通知。

### 6.3 启动条件（关键限制）

- `Activity.request` **只能在前台调用**；后台调用会抛 `ActivityAuthorizationError.visibility`。
- 因此：
  - iPhone App 在前台收到 5% 状态：立即启动。
  - App 在后台：先发 Time Sensitive 通知；用户点击通知打开 App 后启动。
  - App 被强制退出：不保证能启动；以通知为准。
- **点击通知后 MUST 重新读取最新状态**（`stateVersion/recordedAt/TTL`）：TTL 过期、录音已停止或充电 >10% 时 **MUST NOT** 启动 Live Activity，只显示当前状态。
- 未来若引入后端，可用 APNs push-to-start；MVP 不做。
- **MUST NOT** 承诺“5% 时自动在灵动岛出现”。

### 6.4 更新与结束

- 更新时机：电量 5/4/3%、录音开始/暂停/停止、充电状态变化。
- 后台更新是 best-effort；App 被挂起时可能延迟，以通知为准。
- 结束条件：录音停止、会话结束、充电后电量 >10%、用户关闭 Live Activity、系统约 8 小时上限。
- 系统约 8 小时后会结束 Live Activity；**不得把它当作 24 小时常驻通知**。
- 8 小时后如仍需展示，只能在前台重新启动；否则依靠通知与 App 内状态。

### 6.5 隐私

- 锁屏/灵动岛内容可能被他人看到；只显示电量与录音状态，不显示音频、转写、位置。
- 用户可在系统设置关闭 Live Activities；应用需提供说明，不得反复引导开启。

## 7. 能力与配置

- iOS target：
  - `NSSupportsLiveActivities = YES`；
  - Widget Extension target（`AkaMemoWidgets`）承载 Live Activity UI；
  - Time Sensitive Notifications capability；
  - 通知权限请求；
  - MVP 不申请 Critical Alerts，不添加 entitlement。
- Watch target：
  - 无需额外推送能力；
  - 使用 WatchConnectivity（已有）。
- 不引入远程推送/后端；若未来引入，单独 ADR 与隐私评估。

## 8. 失败与降级

| 情况 | 行为 |
| --- | --- |
| iPhone 不可达 | Watch 本地警告；只保留最新状态；到达后仅补发未过期快照，过期告警丢弃 |
| iPhone App 被强制退出 | 不保证唤醒；下次启动补发；Watch 警告可见 |
| 通知权限被拒 | 应用内横幅 + Watch 警告；设置中提供开启入口 |
| 通知被 Focus/静音拦截 | Time Sensitive 在用户允许时可穿透 Focus；静音不绕过 |
| Live Activity 不支持/被关闭 | 保留通知 + 应用内横幅；不显示灵动岛 |
| 后台启动 Live Activity 失败 | 通知附带“打开查看”动作；用户点击后启动 |
| 8 小时上限 | Live Activity 结束；通知与 App 内状态继续 |
| 电量读取失败 | 显示“电量监测不可用”；记录并重试开启监测；不静默跳过、不误报 |
| 重复消息 | 按 eventID 去重；告警有效性按 TTL + 最新快照判断；stateVersion 不用于告警排序 |

## 9. G-003 门禁

### 9.1 通过标准

| # | 标准 | 判定 |
| --- | --- | --- |
| 1 | 5% 通知送达 | iPhone 可达时，60 秒内收到 Time Sensitive 通知 |
| 2 | 内容正确 | 标题/正文含 5%、录音状态；无音频/转写/位置 |
| 3 | 去重 | 同一次跨阈值只收到 1 条；重复消息不重复通知 |
| 4 | 权限被拒降级 | 应用内横幅与 Watch 警告仍可见，不崩溃 |
| 5 | Live Activity 前台启动 | App 前台收到 5% 时启动并显示 |
| 6 | Live Activity 点击启动 | App 后台时点通知可打开并启动 |
| 7 | 更新与结束 | 4%/3%/停止/充电后正确更新或结束 |
| 8 | 8 小时限制 | 达到系统上限后正常结束，无崩溃；通知可用 |
| 9 | 录音不受影响 | 告警期间音频连续，3% 安全停止不丢分片 |
| 10 | 无敏感内容 | 通知、Live Activity、日志均不含音频/转写/位置 |
| 11 | 过期/乱序 | TTL 过期的 5% 消息丢弃；乱序本身不丢弃，按 eventID + TTL + 最新快照判断有效性；不补发、不启动过时活动 |

任一失败 → G-003 失败；按 ADR-0006 降级，不得对外承诺“自动灵动岛/警报级”。

### 9.2 测试条件

- 真机：iPhone + Apple Watch；至少 2 种 iPhone（含/不含灵动岛）。
- iPhone 状态：前台、锁屏、后台、强制退出。
- 通知：允许、拒绝、专注模式开/关、静音开/关。
- 电量：用真机放电到 5%（不伪造），记录 5%→3% 的行为。
- 不充电、不手动停止，直到 3% 安全停止。

## 10. 验证矩阵

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 5%，iPhone 前台 | 通知 + Live Activity 立即可见 |
| 2 | 5%，iPhone 锁屏/后台 | 通知送达；点击后启动 Live Activity |
| 3 | 5%，iPhone 强制退出 | 记录实际行为；Watch 警告可见 |
| 4 | 通知权限拒绝 | 应用内横幅 + Watch 警告 |
| 5 | 专注模式开 | Time Sensitive 按用户设置表现；不误报 |
| 6 | 静音开 | Time Sensitive 不绕过静音；不宣称警报级 |
| 7 | 5%→4%→3% | 更新及时；3% 安全停止并保存 |
| 8 | 充电回到 >10% | 告警重置；Live Activity 结束 |
| 9 | 录音停止 | Live Activity 结束；通知不残留 |
| 10 | 8 小时上限 | Live Activity 正常结束；无崩溃 |
| 11 | 无灵动岛设备 | 锁屏 Live Activity 或通知可用 |
| 12 | 重复消息/重连 | 去重；不重复通知 |
| 13 | 多会话 | 不跨会话误报 |
| 14 | 敏感内容检查 | 通知/Live Activity/日志均无内容泄露 |
| 15 | 离线积压后重连 | 只补发最新未过期状态；旧 5% 不补发、不启动活动 |
| 16 | 电量监测未启用 | UI 显示不可用并重试，不静默跳过 |

## 11. 验收标准

- 5% 时 iPhone 可达 → 60 秒内收到 Time Sensitive 通知，内容正确。
- 5% 只告警并继续录音；3% 自动安全停止并封口分片。
- 同一次跨阈值只通知一次；充电恢复后可再次告警。
- TTL 过期或最新状态已停止/充电/3% 时不补发、不启动过时 Live Activity；乱序本身不丢弃有效告警。电量监测未启用时明确显示不可用。
- App 前台或用户点击通知后，Live Activity 可启动、更新、结束。
- 不承诺后台自动灵动岛、不承诺 24h 常驻、不宣称 Critical Alert（MVP 不申请）。
- 3% 安全停止；录音分片完整。
- 通知、Live Activity、日志无音频/转写/位置内容。
- G-003 通过。

## 12. 参考资料

- Apple Documentation: [`Activity.request(attributes:content:pushType:style:)`](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:style:))
- Apple Documentation: [ActivityKit](https://developer.apple.com/documentation/activitykit)
- Apple Documentation: [`UNNotificationInterruptionLevel`](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel)
- Apple Documentation: [Critical alerts](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)（仅供参考；MVP 不申请）
- Apple Documentation: [`WKInterfaceDevice.batteryLevel`](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/batterylevel)

> 以上资料用于说明约束，不作为验收依据；最终以目标系统版本真机结果为准。实测结论必须回写本文与 ADR-0006。
