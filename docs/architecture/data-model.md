# 数据模型

> 状态：活跃 · 最后更新：2026-10-28

## 设计原则

1. **稳定标识**：所有实体用 `UUID`，不用自增 ID；为未来同步留余地。
2. **文件与元数据分离**：数据库存元数据与相对路径，音频/转写原文存文件。
3. **文件名不含用户内容**：只用 UUID、序号、时间戳。
4. **可幂等**：分片以 `id + checksum` 去重；重复传输不产生重复记录。
5. **可删除**：删除必须级联到文件、转写、索引与缓存。
6. **可迁移**：有 `schemaVersion`，迁移前备份，迁移可测试。
7. **时间统一**：存储用 UTC；展示按用户时区。录音时间用 `Date` + 毫秒时间戳。

## 实体

### RecordingSession

一次用户主动开始、停止的录音过程。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 主键 |
| `startedAt` | Date | 会话开始（UTC） |
| `endedAt` | Date? | 会话结束；录音中为 nil |
| `state` | SessionState | 见状态机 |
| `sourceDeviceModel` | String | 例如 `Watch7,5`，仅用于兼容性排查 |
| `sourceOSVersion` | String | 例如 `watchOS 11.0` |
| `timeZoneIdentifier` | String | 开始时会话时区，用于按天归档 |
| `lastKnownBatteryLevel` | Double? | 最近一次 Watch 电量（0–1），用于告警幂等与诊断 |
| `lowBatteryAlertSentAt` | Date? | 5% 告警发送时间；充电恢复到 10% 以上后清空 |
| `autoPauseReason` | String? | 例如 `lowBattery3Percent` |
| `lastHeartbeatAt` | Date? | 最近心跳 |
| `lastStateVersion` | Int64? | 会话内单调递增的状态版本 |
| `lastAudioBufferAt` | Date? | 最近音频回调 |
| `interruptionCount` | Int | 中断次数 |
| `autoRecoveryEnabled` | Bool | 是否允许意外中断后自动恢复 |
| `recoveryAttemptCount` | Int | 自动恢复尝试次数 |
| `lastRecoveryAt` | Date? | 最近一次成功恢复时间 |
| `totalGapMs` | Int64 | 累计音频缺口（毫秒） |
| `corruptSegmentCount` | Int | 损坏分片数 |
| `recoveredSegmentCount` | Int | 恢复分片数 |
| `integrityState` | String | `healthy/degraded/interrupted/recovering/recovered` |
| `createdAt` / `updatedAt` | Date | 审计字段 |

> 设备型号与系统版本只用于排查兼容性，不用于识别用户；不得与账号或广告标识关联。

### LocationTrack

一次录音会话对应的位置轨迹元数据，与 `RecordingSession` 一对一。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 主键 |
| `sessionID` | UUID | 外键 → RecordingSession，唯一 |
| `sessionStartedAt` | Date | 会话开始时间（冗余，供 TrackImporter 判定 DataEpoch） |
| `startedAt` / `endedAt` | Date | 轨迹起止（UTC） |
| `source` | String | `watch` / `iphone`；MVP 仅 watch |
| `state` | TrackState | 见状态机 |
| `pointCount` | Int | 点数 |
| `distanceMeters` | Double? | 估算总距离 |
| `relativePath` | String | JSONL 相对路径 |
| `createdAt` / `updatedAt` | Date | 审计字段 |

**不变量**

- 一个 `sessionID` 最多一个 `LocationTrack`。
- 轨迹点只追加，不修改历史点。
- 删除 RecordingSession 时级联删除轨迹元数据、JSONL 与 GPX 缓存。

### LocationPoint

位置点不单独建表，按 JSONL 追加存储；每行一个 JSON 对象。JSONL 是事实来源，GPX 只在导出时生成。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `t` | Int64 | UTC 毫秒 |
| `lat` / `lon` | Double | WGS84 |
| `alt` | Double? | 海拔（米） |
| `hAcc` | Double | 水平精度（米） |
| `vAcc` | Double? | 垂直精度（米） |
| `speed` | Double? | 米/秒 |
| `course` | Double? | 度，0–360 |

### AudioChunk

录音的最小落盘与传输单位。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 全局唯一，Watch 生成 |
| `sessionID` | UUID | 外键 → RecordingSession |
| `sessionStartedAt` | Date | 会话开始时间（冗余，供 Inbox 判定 DataEpoch） |
| `sequence` | Int | 会话内递增，从 0 开始 |
| `startedAt` | Date | 分片开始（UTC） |
| `durationMs` | Int | 实际时长 |
| `byteSize` | Int | 文件字节数 |
| `checksumSHA256` | String | 文件校验和 |
| `formatVersion` | Int | 音频格式版本，用于兼容 |
| `sampleRate` | Int | 44100（ADR-0011） |
| `channels` | Int | 2（立体声默认；多声道按硬件/API） |
| `bitRate` | Int | 96000 **每声道**（ADR-0011） |
| `relativePath` | String | 相对应用容器路径，不含绝对路径 |
| `transferState` | ChunkTransferState | 见状态机 |
| `processingState` | ChunkProcessingState | 见状态机 |
| `activeTranscriptID` | UUID? | 当前用于检索/展示的转写版本；重转写时切换，不覆盖旧记录 |
| `receivedAt` | Date? | iPhone 完成校验并入库的时间 |
| `confirmedAt` | Date? | Watch 收到确认的时间 |
| `deletedAt` | Date? | 软删除标记；清理任务据此删文件 |
| `audioPurgedAt` | Date? | 仅音频已清理、转写保留的时间 |
| `localState` | String | `present` / `reclaimed` / `deleted` / `audioPurged` / `missing` |
| `createdAt` / `updatedAt` | Date | 审计字段 |

**不变量**

- `sequence` 在同一 `sessionID` 内唯一。
- `checksumSHA256` 与 `byteSize` 必须与实际文件一致；不一致视为损坏。
- `relativePath` 在 iPhone 与 Watch 上可以指向不同根目录，但结构一致。
- 默认 60 秒或 2 MB 封口；见 `../specs/recording-health.md`。
- 未确认分片不得被 Watch 的空间回收删除。

### Transcript

一个分片对应的转写结果。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 主键 |
| `chunkID` | UUID | 外键 → AudioChunk；一个分片可有多个引擎版本的结果 |
| `providerID` | String | 例如 `apple-speech`、`whisperkit` |
| `providerVersion` | String | 模型/引擎版本 |
| `language` | String | BCP-47，例如 `zh-Hans` |
| `text` | String | 完整文本 |
| `status` | TranscriptStatus | `.pending/.ready/.failed` |
| `errorCode` | String? | 失败原因码，不含内容 |
| `createdAt` / `updatedAt` | Date | 审计字段 |

唯一约束建议：`(chunkID, providerID, providerVersion)` 唯一，保证幂等。

### TranscriptSegment

转写的时间片段，用于高亮、定位与检索。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 主键 |
| `transcriptID` | UUID | 外键 → Transcript |
| `chunkID` | UUID | 外键 → AudioChunk（冗余，供索引与跳转） |
| `sessionID` | UUID | 外键 → RecordingSession（冗余，供分组与检索） |
| `startMs` | Int64 | **绝对** Unix 毫秒（UTC），便于全局检索排序 |
| `endMs` | Int64 | 绝对 Unix 毫秒 |
| `text` | String | 片段文本 |
| `confidence` | Double? | 0–1，引擎不提供则为 nil |
| `isFinal` | Bool | 是否为最终结果 |

### TranscriptionTask（iPhone 转写队列）

持久化队列，保证应用重启或崩溃后可以继续。实现为 SwiftData 实体。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `taskID` | UUID | 主键 |
| `chunkID` / `sessionID` | UUID | 任务对应的分片与会话 |
| `providerID` / `providerVersion` | String | 幂等键的一部分；引擎升级后生成新任务 |
| `state` | String | `queued` / `running` / `failed` / `ready` |
| `attemptCount` | Int | 已失败次数；达到上限后置 `failed`，等待手动重试 |
| `nextAttemptAt` | Date | 退避后的下次可执行时间 |
| `lastErrorCode` | String? | 错误码，不含音频或文本内容 |
| `createdAt` / `updatedAt` | Date | 审计字段 |

- 启动时会把遗留的 `running` 重置为 `queued`，避免崩溃后任务永久卡住。
- 同一 `chunkID + providerID + providerVersion` 只保留一条任务与一条成功的 Transcript。

> 播放定位：`chunkOffsetMs = segment.startMs - chunk.startedAt.timeIntervalSince1970 * 1000`。

### Tag / ChunkTag（P2）

MVP 不做自动标签；保留结构以便后续扩展。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `Tag.id` | UUID | 主键 |
| `Tag.name` | String | 用户可见名称 |
| `Tag.colorHex` | String | 展示色 |
| `ChunkTag.chunkID` / `tagID` | UUID | 联合主键 |

### DeletionTombstone（为同步预留）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | UUID | 墓碑 ID |
| `entityType` | String | `session` / `chunk` / `audio` / `transcript` / `location` |
| `entityID` | UUID | 被删除实体 ID |
| `sessionID` | UUID? | 所属会话，便于批量拒绝 |
| `deletedAt` | Date | 删除时间 |
| `source` | String | `iphone` / `watch` |
| `acknowledgedAt` | Date? | Watch 回执时间 |
| `expiresAt` | Date? | 宽限期；过期可归档，但不得复活 |
| `reason` | String? | `userDelete` / `allData` / `retention` |

### 删除传播与防复活

1. iPhone **先写墓碑并持久化**，再删除索引、文件与元数据。
2. 删除指令通过 WatchConnectivity 发送（含 `tombstoneID` / `sessionID`）；Watch 删除本地分片、清空传输队列中的对应条目并回执。
3. Watch 离线时墓碑保留；重连后补发。Watch 也可在下次心跳/同步时上报本地仍存在的 session/chunk，由 iPhone 回以墓碑。
4. iPhone Inbox 收到任何分片时，**先查墓碑**；命中则丢弃并回执删除，不得重新创建记录。
5. 迟到/重复分片、备份恢复产生的旧数据，都必须与墓碑对账后再次删除。
6. 墓碑保留到 Watch 回执 + 宽限期（建议 30 天）；到期可归档，但不得作为“可恢复”依据。
7. 删除是幂等的；任何步骤失败都保留墓碑并重试，UI 不得提前显示“已删除”。

> 系统备份恢复到删除前的快照时，可能带回旧数据；墓碑只能阻止 App 内迟到/排队数据复活，无法阻止用户显式恢复旧备份。恢复后应提示用户并允许再次删除。

### DataEpoch（全量删除）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `tombstoneID` | UUID | 删除指令与回执的关联键 |
| `epoch` | Int64 | 删除截止时间（UTC ms） |
| `createdAt` | Date | 创建时间 |
| `source` | String | `iphone` |
| `watchAckAt` | Date? | Watch 应用时间 |

- iPhone 端墓碑与 DataEpoch 均为 SwiftData 实体；`acknowledgedAt` / `watchAckAt` 由 Watch 的 `deletionAck` 回执写入。
- 删除指令通过 WatchConnectivity `transferUserInfo` 持久发送，`sendMessage` 在可达时即时补发；未回执的指令在激活/可达变化时重发。

规则：

- “删除全部数据”**先写 DataEpoch = now**，再删除本地数据并发送给 Watch。
- 判定统一使用**所属会话的开始时间** `session.startedAt`（分片冗余为 `sessionStartedAt`），不使用分片自身开始时间。
- Watch 收到后删除所有 `session.startedAt < epoch` 的 session/chunk/location/logs，**包括 iPhone 未知的离线会话**；**仅当当前录音会话的 `startedAt < epoch` 时**才停止/封口并删除当前会话；`startedAt >= epoch` 的新会话不得停止或删除。
- Watch **MUST** 在重连后先应用 epoch，再传输；`session.startedAt < epoch` 的数据不得发送。
- iPhone Inbox **MUST** 拒绝任何 `sessionStartedAt < epoch` 的分片，即使没有逐实体墓碑；分片元数据必须携带 `sessionStartedAt`。
- epoch 持久化；备份恢复取已存储的最大 epoch；旧备份可能回退，恢复后需提示并允许再次删除。

### 删除粒度

| 入口 | `scope` | 删除范围 |
| --- | --- | --- |
| 单条分片/录音 | `chunk` | 该 chunk 的音频、转写、索引；不影响同会话其他 chunk/轨迹 |
| 单条轨迹 | `location` | 该轨迹文件与元数据；同会话后续轨迹导入被拒绝；不影响音频/转写/索引 |
| 单次会话 | `session` | 该会话全部 chunk、转写、索引、轨迹、GPX |
| 删除全部 | `all` | DataEpoch；Watch 所有 `sessionStartedAt < epoch` 的数据 |

- 删除指令 **MUST** 携带 `scope` 与对应 ID；Watch 只删除匹配范围，不得把 `chunk` 删除扩大为 `session` 删除。
- Inbox 按 `scope` 检查墓碑：`chunk` 墓碑只拒绝该 chunk；`session` 墓碑拒绝整个会话。

### 删除轨迹（保留录音）

- iPhone 删除单条轨迹：写 `DeletionTombstone(entityType=location, entityID=trackID, sessionID=…)`，再删除轨迹文件与 `LocationTrackRecord`；音频、转写、索引保持不变。
- 指令 `scope=location` 只要求 `sessionID`；Watch 停止该会话的定位写入并删除 `.jsonl` / `.jsonl.part`，音频与传输队列不受影响。
- `TrackImporter` **MUST** 同时检查 session 墓碑、location 墓碑与 DataEpoch；任一命中即拒绝并回执，不得重建。
- location 墓碑 **MUST NOT** 导致 Inbox 拒绝同会话音频。

### 清理音频（保留转写）

- 操作**只删除音频文件**，保留 Transcript、索引、元数据；`AudioChunk.audioPurgedAt` 标记。
- 为每个 chunk 写 `DeletionTombstone(entityType=audio)`；Watch 删除对应音频且不得补传；Inbox 拒绝该 chunk 的音频，但不删除转写。
- 播放显示“音频不可用”；搜索仍可用。
- 与“删除整个会话”（session tombstone，级联删除转写/索引/位置）和“删除单个分片”（chunk tombstone）区分。

## 状态机

### SessionState

```text
recording ──stop──> finalizing ──> completed
    │                    │
    │                    └──error──> failed
    ├──pause──> paused ──resume──> recording
    ├──interruption──> interrupted ──userResume──> recording
    │                        │
    │                        └──autoRetry（可恢复场景）──> recovering ──success──> recording
    └──fatal──> failed
```

规则：

- 进入 `recording` 的合法路径：
  - 用户在前台启动；
  - 从 `interrupted`/`recovering` 自动恢复（仅当 `autoRecoveryEnabled` 且音频会话仍可激活）；
  - 用户在前台确认恢复。
- `interrupted` 只能在可恢复场景自动进入 `recovering`；失败保持 `interrupted`，不得伪造“录音中”。
- App 启动/重启后不得直接进入 `recording`；必须前台倒计时或用户确认。
- `finalizing` 必须封口当前分片并写入索引；完成前不得显示“已保存”。

### ChunkTransferState

```text
localOnly ──enqueue──> queued ──start──> transferring ──success──> received ──verify──> verified
     ▲                    │                  │                                        │
     └────retry───────────┘                  └──fail──> failed ──retry─────────────────┘
                                                                  │
                                                                  └──confirm──> confirmed（Watch 侧）
```

- `received`：iPhone 已收到文件，尚未校验。
- `verified`：校验和、大小、元数据一致，已入库。
- `confirmed`：Watch 已收到回执，可进入延迟清理。
- `failed` 必须带可重试原因；永久失败（如格式不兼容）标记为 `corrupt` 并提示用户。

### ChunkProcessingState

```text
pending ──start──> transcribing ──success──> transcribed ──index──> indexed
   │                    │
   └──skip──> skipped   └──fail──> failed ──retry──> pending
```

### TrackState

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

- `skipped`：用户关闭转写或音频被判定为静音（需记录原因码）。
- `indexed` 是终态；重新转写会生成新 Transcript，不覆盖旧记录。

## 文件布局

### iPhone

```text
<Application Support>/AkaMemo/
├── audio/
│   └── 2026/10/28/<sessionUUID>/
│       ├── 0000-<startEpochMs>.m4a
│       ├── 0000-<startEpochMs>.json      # 分片元数据快照
│       ├── 0001-<startEpochMs>.m4a
│       └── 0001-<startEpochMs>.json
├── location/
│   ├── 2026/10/28/<sessionUUID>.jsonl
│   └── 2026/10/28/<sessionUUID>.gpx      # 导出缓存，可删除
├── logs/
│   └── 2026/10/28/diagnostics.jsonl      # 7 天/5MB 轮转
├── inbox/                                # 接收临时区，校验后移入 audio/
├── transcripts/
│   └── 2026/10/28/<chunkUUID>/<transcriptID>.json
├── index/
│   └── search.sqlite                     # FTS5 侧车索引
└── metadata/
    └── AkaMemo.store                      # SwiftData 容器
```

### Watch

```text
<Application Support>/AkaMemoWatch/
├── audio/<sessionUUID>/<seq>-<startEpochMs>.m4a
├── audio/<sessionUUID>/<seq>-<startEpochMs>.json
├── location/<sessionUUID>.jsonl
├── logs/diagnostics.jsonl                # 本机环形缓冲的持久化副本
└── queue/transfer-manifest.json          # 待传输队列快照
```

规则：

- 目录按 UTC 日期归档；展示时按用户时区换算。
- 文件名只含 UUID、序号、时间戳；**MUST NOT** 含标题、转写、联系人等用户内容。
- 一个 `Transcript` 一个文件；不得覆盖旧引擎版本；`AudioChunk.activeTranscriptID` 指向当前激活版本。
- 临时文件后缀 `.part`；封口时 `fsync` + rename。
- 数据库只存相对路径；应用容器迁移后仍可用。

## 数据保护

| 数据类型 | 文件保护等级 | 理由 |
| --- | --- | --- |
| 正在写入的分片 | `.completeUnlessOpen` | 锁屏后仍能继续写当前文件 |
| 正在写入的轨迹 | `.completeUnlessOpen` | 锁屏/后台仍能继续追加 |
| 已封口分片 | `.completeUntilFirstUserAuthentication` | 后台传输需要读取 |
| 已封口轨迹 / GPX | `.completeUntilFirstUserAuthentication` | 后台传输与导出需要读取 |
| 诊断日志 | `.completeUntilFirstUserAuthentication` | 实时查看与导出需要读取 |
| 转写 JSON | `.completeUntilFirstUserAuthentication` | 后台建索引需要读取 |
| 索引数据库 | `.completeUntilFirstUserAuthentication` | 搜索与后台任务需要读取 |

如果未来提供“最大保护”模式，可切换到 `.complete`，代价是锁屏期间无法后台传输/转写；必须在设置中说明。

## 持久化与检索（Q-011 已定）

- **iPhone 元数据**：SwiftData（会话、分片、转写、健康、位置）。
- **Watch**：轻量文件/JSON 与必要元数据；不共享 iPhone 的 SwiftData store。
- **全文检索**：独立 SQLite **FTS5 侧车索引**（系统 SQLite），只索引转写片段；默认 `trigram`，最终分词器按 `Q-009` 评测确定（ADR-0010）。
- **一致性**：SwiftData 是业务事实来源；FTS5 索引可从 SwiftData 全量重建；写入失败不回滚录音。
- **未来 CloudKit**：MVP 不启用；启用时 SwiftData + CloudKit 要求属性 optional/default、无 unique constraint、关系 optional。当前 schema 需避免不可迁移的强约束，或在同步层单独设计。

业务层只依赖协议：

```swift
// 示意，不是最终 API
protocol SessionRepository: Sendable {
    func session(id: UUID) async throws -> RecordingSession?
    func upsert(_ session: RecordingSession) async throws
    func delete(id: UUID) async throws
}

protocol SearchIndexing: Sendable {
    func replaceChunk(_ chunkID: UUID, with entries: [SearchIndexEntry]) async throws
    func replaceAll(_ entries: [SearchIndexEntry]) async throws
    func deleteChunk(_ chunkID: UUID) async throws
    func deleteSession(_ sessionID: UUID) async throws
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func entryCount() async throws -> Int
    func deleteAll() async throws
}
```

索引库包含三张表：`segments`（片段元数据）、`segment_fts`（trigram 分词）、`segment_short`（CJK/alnum unigram+bigram）。查询按长度路由：1–2 字符走 `segment_short`，≥3 字符走 `segment_fts`（`specs/transcription-and-search.md` §6.2–6.3）。

这样可以在不改 UI/业务逻辑的前提下替换存储与索引实现。

## 迁移

- 每个持久化存储有 `schemaVersion`，与应用版本解耦。
- 迁移 **MUST** 前向兼容：旧版本数据能被新版本读取；不要求新数据被旧版本读取。
- 迁移前 **MUST** 创建可恢复备份（至少元数据与索引；音频不复制）。
- 迁移 **MUST** 有测试：用固定夹具数据库跑升级，断言实体数量、关键字段与文件引用一致。
- 迁移失败 **MUST** 保留原库并进入只读恢复模式，不得清库重来。

## 保留与删除

| 数据 | 默认保留 | 可配置 |
| --- | --- | --- |
| Watch 未确认分片 | 直到确认 | 否 |
| Watch 已确认分片 | 确认后 24 小时清理 | 保留窗口可调 |
| iPhone 音频 | 直到用户删除 | 否（Q-013：MVP 不自动删除） |
| 位置轨迹 | 跟随录音 | 否 |
| GPX 导出缓存 | 导出后可清理 | 是 |
| 转写文本 | 跟随音频；可选择“只保留文本” | 是 |
| 索引 | 跟随音频/转写 | 否 |
| 诊断日志 | 7 天 / 5MB（不含内容） | 是（可清空） |

删除顺序（保证可恢复与一致）：

1. **先写 DeletionTombstone（或 DataEpoch）并持久化**。
2. **取消**该会话的转写/索引任务；提交前必须再次检查墓碑。
3. 标记 `deletedAt`（软删除），立即从搜索索引移除。
4. 删除转写文件与索引条目。
5. 删除音频分片文件、位置轨迹 JSONL 与 GPX 缓存。
6. 删除元数据记录。
7. 向 Watch 发送删除指令并等待回执；保留墓碑直到回执 + 宽限期。
8. 清理缓存与缩略图（如有）。

任一步失败：保留软删除标记，后台重试；UI 显示“正在删除”，不得显示“已删除”。

## 未来同步的就绪条件

如果 `Q-003` 选择引入 iCloud 或自建后端，现有模型已具备：

- 稳定 UUID、`updatedAt`、软删除与 tombstone。
- 文件与元数据分离，可按分片增量同步。
- 设备型号/系统版本不作为用户标识。

尚需补充：冲突解决策略、加密密钥管理、配额与重试、跨设备转写去重。
