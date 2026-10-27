# 录音规格

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文定义 Watch 端录音的行为、参数、失败处理与验证方式。架构见 `../architecture/overview.md`，数据字段见 `../architecture/data-model.md`。

## 1. 目的与范围

- 让用户在 Apple Watch 上以最低操作成本开始录音。
- 在屏幕熄灭、应用退到后台、来电、蓝牙切换、进程被杀等真实场景下，尽量不丢音频。
- 为 iPhone 端提供可校验、可重试、可重组的分片。
- 不负责转写与检索（见 `transcription-and-search.md`）。
- 位置轨迹与录音并行采集，规格见 `gps-tracking.md`；定位失败不得影响录音。
- 保活、自动恢复、异常通知与完整性见 `recording-health.md`。

## 2. “24 小时录音”的定义（Q-001 已确认：A）

产品目标已由用户确认为 **A：连续 24 小时不间断录音**，不是“全天候可用”或“白天连续”。决策记录见 `../decisions/0004-24h-recording-requirement.md`。

| 解释 | 含义 | 状态 |
| --- | --- | --- |
| A. 连续 24 小时 | 一次开始后不间断录 24h | **产品目标**；可行性未证明 |
| B. 全天候可用 | 24h 内随时可开始；单次可达数小时；充电间隙续录 | 备选，未采用 |
| C. 佩戴期间连续 | 白天佩戴时连续录，夜间充电停止 | 备选，未采用 |

**当前阶段：G-001 可行性门禁**

- 在 `24h-feasibility.md` 的门禁通过前，不得对外承诺 24h，不得写入营销文案、App Store 描述或 TestFlight 说明。
- 工程可以按 24h 目标设计，但验收以门禁结果为准；门禁未通过时，按 ADR-0004 的流程评估降级方案，不得静默改为 B/C。
- UI 必须显示当前录音时长与电量，不显示未经实测的“可录 24h”。
- 实测数据回写本文、`24h-feasibility.md` 与 `../product/overview.md`。

## 3. watchOS 平台约束

以下结论来自 Apple 文档与开发者社区，**最终以目标 watchOS 版本真机实测为准**。

### 3.1 后台音频

- 录音 **MUST** 在应用处于前台且用户可见交互时启动；不能在后台静默启动。后台音频能力只允许**延续**已经开始的音频 I/O。
- 应用退到后台后，只要音频会话保持活跃，录音可以继续；但系统可能在电量、热量、CPU 压力下终止。
- 音频中断（来电、Siri 等）后，后台自动恢复不可靠；可恢复场景按 `recording-health.md` §3.4 自动重试，失败后仍需用户回到前台操作。
- **MUST NOT** 使用播放静音音频、循环空白音轨等方式“保活”；这既有审核风险，也违背产品隐私原则。

### 3.2 Extended Runtime Session

`WKExtendedRuntimeSession` 的公开类型有明确时长上限（以 Apple 文档为准）：

| 类型 | 时长 | 适用性 |
| --- | --- | --- |
| Self Care | 10 分钟 | 不适合 |
| Mindfulness | 1 小时 | 可作为短时补充，不足以覆盖全天 |
| Physical Therapy | 1 小时 | 不适合 |
| Smart Alarm | 30 分钟 | 不适合 |

> 公开的 Extended Runtime 类型只有 Self Care、Mindfulness、Physical Therapy、Smart Alarm。Health Monitoring 需专门 entitlement，不属于公开类型，MVP 不使用。

结论：**不能**把 Extended Runtime Session 当作 24h 录音的唯一机制；它最多作为特定短场景的补充。一个应用只能配置一种 extended runtime 类型。

### 3.3 Workout Session

`HKWorkoutSession` 可以让应用在后台持续运行更久，但会：

- 影响 Activity 圆环与健身记录；
- 让用户误以为在锻炼；
- 带来额外的审核解释成本。

**不作为 MVP 方案。** 如果未来验证发现它是唯一可行路径，必须单独写 ADR，并由产品确认用户体验与审核风险。

### 3.4 配置键

- 音频后台模式需要在 Info.plist / capability 中声明。watchOS 工程的键名与 iOS 不同，且不同 Xcode 版本/单 target 结构下行为有差异。
- 有开发者报告 watchOS 的 `WKBackgroundModes` 不接受 `audio`，而应使用 `UIBackgroundModes`；此点 **MUST** 在工程创建时用真机验证，并把结论写入 `../development/environment.md`。
- 模拟器对后台与麦克风行为比真机宽松，**不得**用模拟器结果作为验收依据。

## 4. 音频参数（建议基线）

| 参数 | 基线值 | 说明 |
| --- | --- | --- |
| 容器 | M4A | 系统原生，便于播放与转写解码 |
| 编码 | AAC-LC | 低码率语音足够；避免 PCM 体积 |
| 采样率 | 44.1 kHz | 用户确认（ADR-0011）；转写前降混并重采样到 16 kHz |
| 声道 | 立体声（2ch）默认；多声道按硬件/API | 记录实际 `channelCount`；不得伪造多声道 |
| 码率 | 96 kbps **每声道** | 立体声合计 192 kbps；24h ≈ 2.07 GB |
| 分片时长 | 60 秒 | 断电最多损失 60 秒；文件数约 1440/天 |
| 分片大小上限 | 2 MB | 立体声 96 kbps/声道下 60 秒约 1.44 MB；超过则提前封口 |
| 文件格式版本 | `formatVersion = 1` | 任何参数变更必须递增 |

体积估算：

| 码率 | 每小时 | 24 小时 |
| --- | --- | --- |
| 16 kbps | 7.2 MB | 172.8 MB |
| 24 kbps | 10.8 MB | 259.2 MB |
| 32 kbps 单声道 | 14.4 MB | 345.6 MB |
| 64 kbps 单声道 | 28.8 MB | 691.2 MB |
| **96 kbps 单声道** | **43.2 MB** | **1.04 GB** |
| **96 kbps 立体声（当前）** | **86.4 MB** | **2.07 GB** |
| 96 kbps 4ch | 172.8 MB | 4.15 GB |

**变更规则**：修改采样率、码率、声道、容器、分片时长或分片大小上限，属于兼容性变更，**MUST**：

1. 递增 `formatVersion`；
2. 更新本文与 `../architecture/data-model.md`；
3. 提供旧分片仍可播放/转写的兼容路径；
4. 在真机上重跑验证矩阵；
5. 任何降级必须由用户显式选择低功耗档位，**MUST NOT** 静默改变音频参数。

## 5. 会话与分片生命周期

### 5.1 会话

- 一个会话由用户的一次“开始 → 停止”定义；暂停不结束会话。
- 会话跨天时，归档日期以**开始时间**为准，UI 可按实际时间拆分展示。
- 会话结束前必须封口当前分片；封口完成前 UI 不得显示“已保存”。

### 5.2 分片

- 默认每 60 秒封口；达到 2 MB 提前封口；停止、暂停、中断、路由变化时立即封口。
- 保存原始多声道 AAC，不在录音链路做降混/降噪；后期处理另行（Q-006）。
- 每个分片一个 `.m4a` + 一个 `.json` 元数据快照；JSON **MUST** 含 `sessionID`、`sessionStartedAt`、`sequence`、分片开始时间、时长、字节数、checksum、`formatVersion`、`channels`。
- 分片序号在会话内从 0 递增，不允许复用。
- 分片封口后 **MUST** 计算 SHA-256 并写入元数据；校验失败的分片标记为损坏，不进入传输队列。

### 5.3 命名

```text
<sessionUUID>/<sequence:04d>-<startEpochMs>.m4a
<sessionUUID>/<sequence:04d>-<startEpochMs>.json
```

**MUST NOT** 在文件名中出现标题、转写、联系人、地点等用户内容。

## 6. 原子写入与崩溃恢复

写入流程：

1. 写入 `<name>.m4a.part`。
2. 关闭文件，`fsync`（或等效的原子落盘手段）。
3. 计算校验和与时长。
4. 写入 `<name>.json.part`，校验后 rename。
5. 将 `.m4a.part` rename 为 `.m4a`。
6. 原子更新会话的 `manifest.json`（临时文件 + rename）。

启动恢复：

- 扫描会话目录中的 `.part` 文件：
  - 可解析且时长 > 0：尝试修复为正式分片，标记 `recovered`。
  - 不可解析：重命名为 `.corrupt`，在 UI 中显示“有 1 段录音损坏”，不得静默删除。
- 扫描 `manifest.json` 与文件系统不一致的条目：以文件系统为准重建索引，并记录日志。
- 恢复过程 **MUST** 可重复执行（幂等），不得因重复启动产生重复分片。

## 7. 后台与中断处理

| 事件 | 必须行为 |
| --- | --- |
| 屏幕熄灭 / 放下手腕 | 继续录音；不改变状态 |
| 应用退到后台 | 继续录音（平台允许时）；保持音频会话活跃 |
| 来电 / Siri / 其他音频中断开始 | 立即封口当前分片；进入 `interrupted`；更新 UI |
| 中断结束 | 尝试自动恢复（3 次，1s/5s/15s）；失败后回到前台提示“继续录音” |
| 音频回调停止 | 10 秒尝试恢复；30 秒判定中断；封口并通知 |
| 蓝牙耳机连接/断开 | 封口当前分片；按新路由继续或暂停（可配置，默认继续） |
| 音频服务重置 | 重建音频栈；封口旧分片；提示用户检查状态 |
| 低电量模式开启 | **不改变音频参数**；降低 GPS/日志/刷新；如需低功耗音频档位，必须用户显式选择并递增 `formatVersion` |
| 电量 5% | 发送 iPhone 通知 + Live Activity；默认继续录音 |
| 电量 3% | 安全停止：封口当前分片 → 暂停 → 提示 |
| 存储低于阈值 | 停止新录音；提示清理；不得覆盖未确认分片 |
| 进程被系统杀死 | 已落盘分片保留；下次启动恢复并继续传输 |
| 设备重启 | 同上；不自动开始录音 |
| 时区变化 | 不影响 UTC 时间戳；UI 按当前时区展示 |
| 定位权限被拒 / 定位服务关闭 | 录音继续；轨迹标记 `unavailable`；UI 提示，不反复弹窗 |
| 定位中断 / 无信号 | 录音继续；轨迹标记 `degraded`/`interrupted`；不补造点 |

**中断恢复的产品原则**：宁可让用户看到“已暂停，点击继续”，也不要显示“录音中”但实际没有采集。

## 8. 传输

### 8.1 机制

- 使用 `WCSession.transferFile(_:metadata:)` 传输分片；它是后台队列，适合文件，不保证实时与顺序。
- **MUST NOT** 用 `sendMessage` 传输音频；它只适合小体积控制消息，且要求可达。
- iPhone 收到文件后 **MUST** 立即移出 inbox 临时区并校验；不得在回调里做耗时转写。

### 8.2 幂等与确认

- iPhone 以 `chunk.id + checksum` 去重；重复文件直接丢弃并回执成功。
- iPhone 完成校验并持久化后，通过 `transferUserInfo` 发送应用级确认（含 `chunk.id`）。
- Watch 收到确认后标记 `confirmed`，进入延迟清理；未收到确认则重试。
- 重试使用指数退避（例如 5s、30s、2min、10min，上限 1h），并尊重低电量模式。
- 传输顺序不保证：iPhone 按 `sessionID + sequence` 重组；缺失分片在 UI 中显示为缺口，不伪造连续。

### 8.3 网络与电量策略

- 默认允许 Wi‑Fi 与蜂窝；用户可限制为仅 Wi‑Fi。
- 大量积压时，优先在充电 + Wi‑Fi 下传输。
- iPhone 不可达时，Watch 继续本地缓存；不得因传输失败停止录音（除非存储不足）。

## 9. 电量、存储与热量

### 9.1 电量

- 产品目标为连续 24 小时；可行性门禁 G-001 与测试方法见 `24h-feasibility.md`。
- 开启 GPS 时，定位是主要耗电来源之一；组合续航见 `gps-tracking.md` 的 G-002。
- 真机实测 **MUST** 记录：满电开始连续录音，每小时耗电百分比、可维持时长、表面温度感受；至少完成一次完整 24 小时测试。
- 电量策略：20% 应用内提示、10% 强提示并降 GPS、**5% 发送 iPhone 通知 + Live Activity（默认继续录音）**、**3% 安全停止**；详见 `battery-alerting.md`。
- 5% 时只告警并继续录音；3% 自动停止并封口当前分片；MVP 不提供 5% 自动暂停。
- 充电后 **MUST NOT** 自动恢复录音；由用户确认（避免在会议/隐私场景意外录音）。

### 9.2 存储

- 停止阈值：可用空间 < 500 MB；警告阈值：< 1 GB。
- Watch 只保留未确认分片 + 已确认但未满 24h 的分片。
- 空间不足时，按“已确认且最旧”顺序清理；**MUST NOT** 删除未确认分片。
- iPhone 存储不足时，暂停接收并在 Watch 保留分片；恢复后继续。

### 9.3 热量

- 监听 `ProcessInfo.thermalState`；`serious` 时**不静默改音频参数**，优先降低 GPS/日志/刷新；必要时使用用户预设的低功耗音频档位并递增 `formatVersion`；`critical` 时暂停并提示。
- 不得为了“保持录音”而忽略系统热保护。

## 10. 用户可见状态

- Watch 与 iPhone 都必须能区分：`录音中`、`正在自动恢复`、`已暂停`、`已中断（待恢复）`、`正在传输`、`传输失败`、`存储不足`、`电量不足`、`低电量告警已发送/失败`、`Live Activity 不可用`。
- 录音中 **MUST** 有持续可见的系统或应用内指示；不得隐藏。
- 暂停/继续 **MUST** 是明确操作，不得用“摇晃”“双击表冠”等隐晦手势单独承担。
- 通知与实时活动（如使用）**MUST** 与真实采集状态一致。

## 11. 验证矩阵（真机）

每条场景记录：设备型号、watchOS 版本、iPhone 型号、iOS 版本、开始电量、结束电量、录音时长、分片数、丢失/损坏数、结果。

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 前台开始 → 锁屏 30 分钟 | 录音连续，分片按时封口 |
| 2 | 放下手腕 / 袖口遮挡 | 不中断；音量正常 |
| 3 | 来电并挂断 | 当前分片落盘；回前台提示继续 |
| 4 | Siri 唤醒 | 同中断处理 |
| 5 | 蓝牙耳机连接/断开 | 分片封口；按策略继续或暂停 |
| 6 | 飞行模式 | 继续录音；传输等待网络 |
| 7 | 低电量模式 | 按策略继续/降级；UI 明示 |
| 8 | 电量 < 阈值 | 暂停并提示；已录分片完整 |
| 9 | 存储 < 500 MB | 停止新录音；提示清理 |
| 10 | 强制退出应用 | 已落盘分片保留；重启可恢复 |
| 11 | 重启 Watch | 可恢复/继续传输；不自动录音 |
| 12 | 跨天录音（23:59 → 00:01） | 分片与归档正确；时间戳不跳变 |
| 13 | 充电时录音 | 可录；温度与电量正常 |
| 14 | 连续 4 小时 | 记录实际耗电与丢失率 |
| 15 | 连续 8 小时（如可行） | 记录实际耗电与丢失率 |
| 16 | iPhone 不在身边 4 小时 | Watch 本地缓存；回连后传输 |
| 17 | iPhone 存储满 | Watch 保留分片；不丢失 |
| 18 | 人为断网/重复传输 | 幂等；不产生重复记录 |
| 19 | 时区变化 | UTC 时间戳不变；UI 正确 |
| 20 | 系统音频服务重置 | 重建成功；无静默停止 |
| 21 | 连续 24 小时（按 `24h-feasibility.md`） | 音频连续；0 丢失/损坏；设备未关机；结束电量 ≥ 5% |
| 22 | 24h + iPhone 在旁传输 | 传输积压可清空；Watch 空间可回收 |
| 23 | 24h + iPhone 不在旁（飞行模式） | 本地缓存不丢；回连后补传 |
| 24 | 录音 + GPS（按 `gps-tracking.md`） | 音频不受影响；轨迹按 G-002 判定 |
| 25 | 5% 低电量告警与 Live Activity（按 `battery-alerting.md`） | 通知送达；Live Activity 前台/点击启动；录音不受影响 |
| 26 | 强制退出 / 断电 | 已封口分片完整；损失 ≤ 60 秒；重启可恢复 |
| 27 | 注入损坏分片 | 隔离 `.corrupt`；不转写；UI 可见 |
| 28 | 可恢复中断 | 3 次内自动恢复；gap 可见；不拼接音频 |

## 12. 验收标准

- 验证矩阵中 P0 场景（1–4、6、8–12、16–18、21–23）全部通过。
- G-001 连续 24 小时门禁通过：音频连续、0 丢失/损坏、设备未因电量/热关机、结束电量 ≥ 5%。
- 若启用 GPS：G-002 录音 + GPS 组合门禁通过，且定位失败不影响录音。
- G-003 低电量告警门禁通过：5% 通知、去重、Live Activity、3% 安全停止均符合 `battery-alerting.md`。
- G-004 录音保活/完整性门禁通过：中断检测、自动恢复、0 损坏、损失 ≤ 60 秒，符合 `recording-health.md`。
- G-005 诊断日志门禁通过：实时日志、脱敏、配额、导出与性能符合 `diagnostics.md`。
- 连续 4 小时中间检查点：分片丢失率 0；损坏分片可被识别且不静默删除。
- 中断后：UI 状态与真实采集一致；不存在“显示录音但无数据”。
- 传输：重复/断网/重启后最终一致；无重复转写。
- 电量与存储阈值：按本文行为执行，并有 UI 提示。

## 13. 参考资料

- Apple Developer Forums: [Resume recording from AudioInterruption in background mode](https://developer.apple.com/forums/thread/750432)
- Apple Documentation: [Using extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)
- Stack Overflow: [Apple Watch error 561015905 when starting recording in background](https://stackoverflow.com/questions/78501508)
- Apple Documentation: [WCSession.transferFile(_:metadata:)](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
- Apple Documentation: [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)

> 这些资料只用于说明约束，不作为验收依据；最终以目标系统版本真机结果为准。实测结论必须回写本文与 `../decisions/`。
