# 录音保活、异常通知与完整性

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文定义录音心跳/看门狗、中断通知、分片完整性校验与恢复。决策见 `../decisions/0007-recording-health-and-integrity.md`；录音参数见 `recording.md`。
>
> 实现状态（2026-10-28）：Watch 每 10 秒写 `applicationContext` 健康快照（含心跳/电量/存储/录音状态），状态变化即时发送事件；iPhone 在可达时 45 秒无心跳、或收到 interrupted 事件时发本地通知，并有 90 秒 dead-man 本地通知，stop/pause/删除时取消。Watch 存储 <1GB 警告、<500MB 停止录音。真机后台/通知/G-004 未验证。

## 1. 目标与非目标

**目标**

- 持续确认“录音仍然活着”，而不是只看 UI 状态。
- 录音意外中断时，尽快在 Watch 与 iPhone 上通知用户，并在可恢复场景下自动恢复。
- 已封口分片可独立校验、播放、传输；损坏可检测、可隔离、不静默删除。
- 断电/进程被杀时，把损失限制在最后一个未封口分片（默认 ≤ 60 秒）。

**非目标**

- 承诺零丢失或零损坏；硬件/文件系统故障无法完全避免。
- App 被杀后的后台自动续录；可恢复场景按 §3.4 自动重试，失败后前台恢复。
- 服务端修复或云端备份（MVP 无后端）。

## 2. 术语

| 术语 | 含义 |
| --- | --- |
| 物理分片 | 60 秒或 2 MB 封口的独立音频文件，可单独校验/播放 |
| 逻辑分组 | 按 5 分钟/会话聚合展示或传输的分片集合，不改变物理文件 |
| 心跳 | Watch 每 10 秒写入的录音健康状态（时间、分片序号、字节数、音频会话状态） |
| 看门狗 | 检测心跳/音频回调是否停止的逻辑 |
| 中断 | 非用户主动停止的录音停止或音频会话失效 |
| 损坏 | 校验失败、无法解码、时长/大小异常、序号缺失且无法恢复 |

## 3. 保活机制

### 3.1 Watch 端 `RecordingHealthMonitor`

- 音频回调每次写入时更新 `lastAudioBufferAt`。
- 每 10 秒写心跳：
  - 本地：`health.json`（原子更新），含 `sessionID`、`lastAudioBufferAt`、`lastHeartbeatAt`、`chunkSequence`、`bytesWritten`、`audioSessionActive`、`batteryLevel`、`state`。
  - 远端：由统一的 `WatchStatePublisher` 写 `applicationContext`（心跳+电量+录音状态合并为单一快照）；即时事件用 `sendMessage`/`transferUserInfo`。心跳与电量模块 **MUST NOT** 各自写 context。
- 看门狗每 5 秒检查：
  - 10 秒无音频回调 → 尝试恢复（重启音频会话/重新配置输入）；记录 `recovering`。
  - 30 秒无音频回调 → 标记 `interrupted`，封口当前分片，停止“录音中”状态，发通知。
  - 恢复成功 → 记录 `recovered`，继续；不补造缺失音频。
- 不得在未恢复时继续显示“录音中”；不得伪造心跳。
- 中断后按 §3.4 尝试自动恢复；恢复失败才提示用户。

### 3.2 iPhone 端 `RecordingWatchdog`

- 记录最近心跳时间、Watch 可达性与最近 `stateVersion`。
- **可达且存活**：45 秒无心跳 → 发“录音可能已中断”通知（60 秒内）。
- **进程消失/不可达**：`isReachable` 在 App 未运行时通常为 false，不能作为存活依据。iPhone 在收到首个心跳后调度一个**本地通知 dead-man's switch**（默认 90 秒）；每收到心跳取消并重排；触发时显示“无法确认录音状态”，不称“已中断”。
- **iPhone 被挂起**：预调度的本地通知仍由系统触发；但 iPhone 被强制退出/从未收到心跳时，无送达保证，必须在 UI/文档说明。
- 收到 `interrupted` 事件 → 立即更新 UI 并通知（去重）；收到 `recovered` → 更新 UI，保留中断事件记录。
- 状态快照/中断事件按 `stateVersion` 取最新；告警事件按 `eventID` 去重，并用 TTL + 最新快照判断有效性；乱序本身不是丢弃理由。
- dead-man 通知**只在 `recording` 状态调度**；收到 stop/pause/finalize/completed/delete/all-data 时 **MUST 取消 pending 通知**（`removePendingNotificationRequests`）；resume 时重新调度。非 recording 心跳不得留下 pending 通知。

### 3.3 阈值

| 参数 | 默认值 | 可调整 |
| --- | --- | --- |
| 心跳间隔 | 10 秒 | 否（性能原因） |
| 本地看门狗检查 | 5 秒 | 否 |
| 无音频回调告警 | 10 秒 | 是（8–15 秒） |
| 判定中断 | 30 秒 | 是（20–60 秒） |
| iPhone 无心跳告警（可达） | 45 秒 | 是（30–60 秒） |
| dead-man 本地通知（进程消失/不可达） | 90 秒（收到首个心跳后） | 是（60–120 秒） |
| 通知去重窗口 | 5 分钟 | 否 |

阈值调整必须更新本文与 G-004 结果；不得为了减少误报而关闭通知。

### 3.3.1 状态版本契约

- `stateVersion` 是**会话内单调递增**的 `Int64`，由 `WatchStatePublisher` 在每次快照更新时递增并持久化到 `health.json`/会话元数据。
- 同一会话跨 Watch 重启 **MUST** 从持久化的最后版本继续递增，**MUST NOT 归零**；若持久化丢失，使用 `max(lastKnown + 1, nowMs)` 避免回退。
- 新会话使用新 `sessionID`，`stateVersion` 从 1 开始；iPhone 只在**同一 `sessionID` 内**比较版本，不跨会话继承。
- 电量、心跳、录音状态共用该版本；电池/健康模块不得各自维护计数器。
- `stateVersion` 只用于快照/当前状态排序；**告警事件**按 `eventID` 去重，并用 TTL + 处理时刻最新快照判断有效性，不依赖跨通道到达顺序。

### 3.4 自动恢复

`RecordingRecoveryController` 在检测到中断后按以下顺序处理：

1. **可恢复场景**（App 仍在运行、音频会话可重新激活）：
   - 最多尝试 3 次，间隔 1s / 5s / 15s；
   - 每次尝试重新配置音频会话与输入；
   - 成功：新开分片，记录 `gapMs`，状态 `recovering → recording`，UI 显示“已自动恢复，缺口 X 秒”；
   - 失败：状态 `interrupted`，发送通知，等待用户前台恢复。
2. **App 被杀/重启后**：
   - 只允许在**前台**恢复；
   - 若用户开启“意外中断后自动恢复”，显示 3 秒倒计时“即将恢复录音”，可取消；倒计时结束才启动麦克风；
   - 未开启或用户取消：显示“上次录音中断”，提供手动恢复按钮；
   - **MUST NOT** 在后台/锁屏/重启后无可见提示地启动麦克风。
3. **恢复后的音频**：
   - 新分片从恢复时刻开始，不补造缺失音频；
   - 缺口写入会话 `totalGapMs` 与时间线；
   - 不把缺口拼接成连续音频。

#### 静默恢复设置

- `autoResumeRecording`：意外中断后自动尝试恢复（默认开）。
- `silentResume`：恢复时不播放应用提示音/触觉（默认开，可关）。
- **“静默”只指应用层声音/触觉**；系统麦克风指示仍然可见。
- 仅在 App 仍持有音频会话/后台音频执行时生效；App 被杀/重启后必须前台倒计时确认。
- **MUST NOT** 隐藏系统指示、伪装未录音或在后台无可见状态开麦。

> 2026-10-28 已确认：接受上述“静默恢复”边界。

## 4. 异常通知

### 4.1 触发条件

- 看门狗判定 `interrupted`。
- 自动恢复尝试失败。
- 音频会话无法恢复。
- 磁盘满/写入失败导致停止。
- 启动扫描发现损坏/缺失分片。
- 用户主动停止/暂停 **不触发**。

### 4.2 通知内容

- 标题：`录音已中断` / `录音可能已中断` / `检测到 1 段录音损坏`
- 正文：说明会话时间、已保存到的位置、用户可做的事（打开 AkaMemo / 继续录音 / 查看损坏段）。
- 分类动作：`打开 AkaMemo`；后续可增加 `继续录音`（需前台）。
- **MUST NOT** 包含音频、转写、位置、文件名。
- 使用 Time Sensitive（与 ADR-0006 一致）；MVP 不申请 Critical Alert。
- 去重：`sessionID + eventType + 5 分钟时间桶`。
- Watch 本地同时显示警告/触觉，避免 iPhone 不可达时无感知。

## 5. 完整性

### 5.1 写入

1. 写入 `<segment>.m4a.part`。
2. 关闭/`fsync`。
3. 校验时长、大小、可解码性；计算 SHA-256。
4. 写入 `<segment>.json.part`，校验后 rename。
5. `.m4a.part` rename 为 `.m4a`。
6. 原子更新 `manifest.json`（分片序号、校验和、状态）。

### 5.2 启动恢复

- 扫描 `.part`：
  - 可解析且时长 > 0 → 尝试修复并标记 `recovered`。
  - 不可解析 → rename 为 `.corrupt`，保留并在 UI 显示。
- `manifest.json` **MUST** 为每个序号记录 `localState`（`present/reclaimed/deleted/audioPurged/missing`）与关联 `tombstoneID`（如有）。
- 扫描 `manifest.json` 与文件系统不一致：
  - 以文件系统为准重建索引，但保留 `reclaimed/deleted/audioPurged` 状态；
  - 缺失序号只有在 manifest 未标记 `reclaimed/deleted/audioPurged` **且**无墓碑时才标记 `missing`；正常清理不得误报；
  - manifest 标记 `present` 但文件缺失 → 标记 `missing`（意外缺失）；
  - 无法判定 → 保留原状态并记录诊断，不猜。
- 恢复必须幂等；重复启动不产生重复分片。
- 损坏/缺失分片不得进入转写；不得静默删除。

### 5.3 传输与校验

- iPhone 收到分片后校验 SHA-256、大小、时长、序号。
- 不一致 → 请求重传；永久不一致 → 标记 `corrupt`，保留原文件。
- 重复传输按 `chunkID + checksum` 去重。
- 只有 iPhone 校验并持久化后，Watch 才能删除；未确认分片不得删除。

### 5.4 损坏处理

- `.corrupt` 文件保留，不自动删除；UI 显示数量与时间范围。
- 提供“导出损坏段”或“尝试修复”作为后续能力；MVP 至少可见、可删除。
- 已封口分片损坏率目标 0；任何损坏都必须可追溯（原因码、设备、系统版本）。

## 6. 数据与状态

`RecordingSession` 增加：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `lastHeartbeatAt` | Date? | 最近心跳 |
| `lastAudioBufferAt` | Date? | 最近音频回调 |
| `interruptionCount` | Int | 中断次数 |
| `autoRecoveryEnabled` | Bool | 是否允许意外中断后自动恢复 |
| `recoveryAttemptCount` | Int | 自动恢复尝试次数 |
| `lastRecoveryAt` | Date? | 最近一次成功恢复时间 |
| `totalGapMs` | Int64 | 累计音频缺口（毫秒） |
| `corruptSegmentCount` | Int | 损坏分片数 |
| `recoveredSegmentCount` | Int | 恢复分片数 |
| `integrityState` | String | `healthy/degraded/interrupted/recovering/recovered` |

健康事件只记录时间、类型、原因码、恢复结果；**MUST NOT** 记录音频内容。

## 7. 平台限制

- watchOS 后台恢复不可靠；可恢复场景自动重试，失败后仍需用户前台恢复，不得假装自动续录。
- **MVP 不支持“后台静默开麦”**：系统不允许隐藏麦克风指示或在后台/被终止后启动录音；设置中的“静默恢复”仅关闭应用提示音/触觉。
- 自动恢复 **MUST NOT** 在后台/锁屏/重启后无可见提示地启动麦克风；前台倒计时可取消。
- 心跳/通知依赖 WatchConnectivity；iPhone 不可达时以 Watch 本地警告为准。
- 音频会话中断（来电/Siri/路由变化）可能无法自动恢复；按 `recording.md` 处理。
- 60 秒分片降低损坏窗口，但不能保证硬件/文件系统故障下的零损坏。

## 8. G-004 门禁

### 8.1 通过标准

| # | 标准 | 判定 |
| --- | --- | --- |
| 1 | 强制退出 | 已封口分片完整；损失 ≤ 60 秒；重启可恢复/继续传输 |
| 2 | 断电/关机 | 已封口分片完整；损失 ≤ 60 秒；无“半截文件”被当作完整 |
| 3 | 音频中断 | 30 秒内标记 interrupted；60 秒内通知（iPhone 可达） |
| 4 | 路由变化/权限撤销 | 状态正确；通知；不崩溃 |
| 5 | 损坏注入 | 检测、隔离为 `.corrupt`；不转写；UI 可见 |
| 6 | 磁盘满 | 安全停止；已录分片不损坏；通知 |
| 7 | 重复传输 | 幂等；不重复转写 |
| 8 | 24h 运行 | 看门狗无误报；已封口分片损坏 0 |
| 9 | 无敏感内容 | 心跳/通知/日志不含音频/转写/位置 |
| 10 | 可复现 | 主设备至少 2 次通过；至少 2 种设备/系统组合 |
| 11 | 可恢复中断 | 3 次内自动恢复；新开分片；gap 可见 |
| 12 | App 被杀后前台恢复 | 3 秒倒计时可取消；不在后台静默开麦 |
| 13 | Watch 进程消失 | iPhone 已收到心跳 → 90 秒内“无法确认”本地通知；force-quit 不保证 |
| 14 | Context 合并 | 心跳与电量同时存在，互不覆盖 |
| 15 | dead-man 取消 | stop/pause/delete/all-data 后无 pending 通知 |
| 16 | stateVersion 重启 | 同会话跨重启单调递增；新会话不继承 |

任一失败 → G-004 失败；按 ADR-0007 调整阈值/分片策略，不得隐藏问题。

### 8.2 测试条件

- 真机：iPhone + Apple Watch；至少 2 种设备/系统组合。
- 场景：正常录音、强制退出、关机、来电、Siri、蓝牙切换、撤销麦克风权限、磁盘满、注入损坏文件、重复传输、自动恢复、前台倒计时、Watch 进程消失/不可达、iPhone 被挂起/强制退出、正常停止/暂停/删除、Watch 重启继续会话、24h。
- 记录：设备、系统、分片数、丢失/损坏/恢复数、中断检测时间、通知时间。

## 9. 验证矩阵

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 正常录音 30 分钟 | 心跳稳定；0 损坏；无通知 |
| 2 | 强制退出 | 最后分片封口；损失 ≤ 60 秒；重启恢复 |
| 3 | 关机/断电 | 同上；无半截文件被接受 |
| 4 | 来电/Siri | 30 秒内 interrupted；60 秒内通知 |
| 5 | 蓝牙路由变化 | 状态正确；必要时中断通知 |
| 6 | 撤销麦克风权限 | 停止并通知；不崩溃 |
| 7 | 磁盘满 | 安全停止；无损坏；通知 |
| 8 | 注入损坏分片 | `.corrupt` 隔离；不转写；UI 可见 |
| 9 | 重复传输 | 幂等；不重复转写 |
| 10 | 24h 运行 | 看门狗无误报；损坏 0 |
| 11 | Heartbeat 丢失但 Watch 不可达 | 显示“无法确认”，不误报中断 |
| 12 | 用户主动停止 | 不触发中断通知 |
| 13 | 可恢复中断 | 3 次内自动恢复；新开分片；gap 可见 |
| 14 | App 被杀后前台恢复 | 3 秒倒计时可取消；不在后台静默开麦 |
| 15 | Watch 进程消失/不可达 | iPhone 已收到心跳 → 90 秒内“无法确认”通知；force-quit 不保证 |
| 16 | 心跳/电量并发 | applicationContext 单一快照，两状态都在，不互相覆盖 |
| 17 | 正常停止/暂停/删除 | pending dead-man 通知被取消，不再触发 |
| 18 | Watch 重启后继续会话 | stateVersion 继续递增，不归零 |

## 10. 验收标准

- 强制退出/断电后，已封口分片 0 损坏；损失 ≤ 60 秒。
- 中断后 30 秒内状态变为 `interrupted`，iPhone 可达时 60 秒内收到通知。
- Watch 进程消失且 iPhone 已收到心跳：90 秒内收到“无法确认”本地通知；iPhone 被强制退出不保证。
- 心跳与电量共享单一 `applicationContext` 快照，不互相覆盖。
- 正常停止/暂停/删除后无 pending dead-man 通知；同一会话重启后 `stateVersion` 继续递增。
- 损坏分片被隔离且不进入转写；UI 可见、可删除。
- 可恢复中断 3 次内自动恢复；缺口可见；不拼接音频。
- App 被杀后只在前台倒计时恢复，不在后台静默开麦。
- 心跳/通知/日志不含音频、转写、位置。
- 24h 运行看门狗无误报。
- G-004 通过。

## 11. 参考资料

- Apple Documentation: [`AVAudioSession` interruptions](https://developer.apple.com/documentation/avfaudio/avaudiosession)
- Apple Documentation: [File System Programming Guide — atomic writes](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/)
- Apple Documentation: [`WCSession`](https://developer.apple.com/documentation/watchconnectivity/wcsession)
- 录音规格：`recording.md`
- 低电量通知：`battery-alerting.md`

> 本文的阈值是工程默认值；G-004 实测后可调整，但必须回写本文与 ADR-0007。
