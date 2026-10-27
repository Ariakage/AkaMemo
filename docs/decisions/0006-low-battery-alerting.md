# ADR-0006: 5% 低电量告警与低电量 Live Activity

- 状态：已接受
- 日期：2026-10-28
- 决策者：用户
- 验证状态：G-003 未通过（待执行）
- 关联：`Q-022`、`Q-023`、ADR-0004、`../specs/battery-alerting.md`

## 背景

24 小时连续录音（ADR-0004）很可能触及 Apple Watch 电量上限。用户要求在 Watch 电量降到 **5%** 时向 iPhone 发送高优先级通知，并在低电量期间于灵动岛/锁屏保持可见状态。

平台约束：

- Watch 可以通过 `WKInterfaceDevice.batteryLevel` 读取电量，但 iPhone 与 Watch 之间没有系统级“电池推送”；需要应用通过 WatchConnectivity 传递。
- 没有自建后端时，不能使用 APNs 远程推送；iPhone 收到 Watch 消息后只能发**本地通知**。
- **Time Sensitive** 通知无需 Apple 单独批准，可穿透专注模式（用户允许时），但不绕过静音开关。
- **Critical Alert** 需要 Apple 单独批准 entitlement，通常只给健康/安全/安防类应用；电池提醒很可能不符合条件，不能假设可用。
- **Live Activity 不能从后台启动**：`Activity.request` 只能在前台调用，除非使用 App Intents 或 APNs push-to-start。系统对 Live Activity 还有约 8 小时上限。
- 因此，“5% 自动弹出灵动岛”在无后端、App 在后台时**不能保证**。

## 选项

1. **Time Sensitive 本地通知 + 前台/点击后启动 Live Activity（已选）**
   - 优点：无需后端；通知可靠可落地；Live Activity 在用户可见时提供持续状态。
   - 缺点：通知不是 Critical Alert；Live Activity 不能保证后台自动出现，也不是 24h 常驻。
2. **Critical Alert（未采用）**
   - 优点：绕过静音/专注，最接近“智能家居警报”。
   - 缺点：需 Apple 批准，电池提醒获批概率低；用户仍需单独授权。
3. **APNs 远程推送 + push-to-start Live Activity**
   - 优点：可在后台/终止状态启动 Live Activity，送达更可靠。
   - 缺点：需要后端、推送证书、账号与隐私评估；MVP 不引入。
4. **只在 Watch 本地提示**
   - 优点：实现最简单。
   - 缺点：不满足“通知 iPhone”的需求。

## 决定

1. Watch 电量降到 **5%** 时，通过 WatchConnectivity 向 iPhone 发送高优先级状态；iPhone 发 **Time Sensitive 本地通知**。
2. **MVP 不申请 Critical Alerts entitlement**；统一使用 Time Sensitive。后续如确需绕过静音/专注，必须新写 ADR 再评估。
3. 低电量 Live Activity：
   - iPhone App 在前台时，收到 5% 状态后立即启动/更新。
   - App 在后台时，先发通知；用户点击通知打开 App 后启动。
   - 不承诺“后台自动弹出灵动岛”，也不承诺 24h 常驻；系统约 8 小时上限。
4. 5% 时**只发告警并继续录音**；到 **3%** 自动安全停止并封口当前分片。MVP 不提供“5% 自动暂停”选项；后续如需调整，另写需求变更/ADR。
5. 告警按阈值幂等：每次跨过 5% 只发一次；充电回到 10% 以上后重置。
6. 通知与 Live Activity 只包含电量、录音状态、时间；**MUST NOT** 包含音频、转写、位置内容。
7. Watch 端同时显示本地警告与触觉提示，避免 iPhone 不可达时用户无感知。
8. MVP 不引入后端/APNs；送达限制必须在 UI 与文档中说明。

## 后果

**正面**

- 无需后端即可让用户在 5% 时收到明显提醒。
- Time Sensitive 通知可穿透专注模式（用户允许时），比普通通知更接近“警报”。
- Live Activity 在用户打开 App 后提供锁屏/灵动岛持续状态。
- 告警内容不含敏感数据，隐私风险低。

**负面**

- iPhone 被强制退出、不可达或通知权限被拒时，送达不保证。
- Live Activity 不能从后台可靠启动，也不是 24h 常驻；用户可能看不到灵动岛。
- Critical Alert 不可用意味着静音/专注下仍可能错过。
- Live Activity 增加实现复杂度（Widget Extension、ActivityKit、状态同步）。

**必须验证**

- G-003：5% 通知送达、去重、Live Activity 前台/点击启动、更新、结束、8 小时限制、无敏感内容。
- iPhone 锁定/后台/强制退出/专注模式/静音/通知权限拒绝等场景。
- 低电量下录音不受影响、3% 安全停止不丢分片。

## 验证

见 `../specs/battery-alerting.md` 的 G-003。未通过时按以下顺序降级：

1. 保留 Time Sensitive 通知 + Watch 本地警告；
2. 去掉“后台自动 Live Activity”的预期，改为点击通知后展示；
3. 若用户要求可靠后台告警，再评估后端 APNs / Critical Alert，并新写 ADR。

## 回退

- 如果用户后续要求必须绕过静音/专注：新写 ADR 评估 Critical Alert 申请或后端 APNs；MVP 不申请，不得宣称“警报级”。
- 如果 Live Activity 不可用：保留通知与应用内低电量横幅，删除“常驻灵动岛”承诺。
- 如果 5% 告警影响录音稳定性：降低监控频率，改为 5%/3% 两个节点，不在每次电量变化时唤醒。
