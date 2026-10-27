# 转写与检索规格

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文定义分片如何变成可检索的文字。录音侧见 `recording.md`，数据字段见 `../architecture/data-model.md`。

## 1. 目标与非目标

**目标**

- 把已校验的音频分片稳定转写为带时间戳的文本。
- 转写失败可重试、可替换引擎、结果幂等。
- 支持中文全文检索，命中后能跳回原声。
- 默认在设备上完成；任何云端路径都必须显式同意、可关闭。

**非目标（MVP）**

- 实时流式转写（允许分钟级延迟）。
- 说话人分离、情绪识别、自动摘要。
- 跨语言自动翻译。
- 云端账号体系与多端同步。

## 2. 转写管线

```mermaid
flowchart LR
    A[已校验分片] --> B[解码/重采样]
    B --> C[VAD/静音切分]
    C --> D[识别窗口切分]
    D --> E[引擎转写]
    E --> F[合并分段 + 时间戳]
    F --> G[持久化 Transcript]
    G --> H[写入检索索引]
    H --> I[可检索]
```

### 2.1 输入

- 只处理 `transferState == verified` 且 `processingState == pending` 的分片。
- 音频格式见 `recording.md`；立体声 96 kbps/声道 / 44.1 kHz 输入在识别前降混并重采样到 16 kHz（ADR-0011）。
- 解码失败标记 `unsupported_format`，不反复重试。

### 2.2 窗口切分

识别引擎通常有单次请求时长限制（不同引擎不同，以文档与实测为准）。因此：

- 不能把 60 秒分片直接丢给只支持更短窗口的引擎。
- 需要按引擎能力切分为识别窗口（例如 30–60 秒），并在合并时拼接时间戳。
- 切分点优先落在 VAD 检测到的静音处，避免把一个词切成两半。
- 合并后的 segment 时间戳 **MUST** 是绝对 UTC 毫秒，且单调递增、不重叠。

### 2.3 输出

```swift
// 示意，不是最终 API
struct TranscriptDraft: Sendable {
    let providerID: String
    let providerVersion: String
    let language: String
    let text: String
    let segments: [SegmentDraft]
}

struct SegmentDraft: Sendable {
    let startMs: Int64   // 绝对 UTC 毫秒
    let endMs: Int64
    let text: String
    let confidence: Double?
}
```

### 2.4 幂等

- 唯一键：`chunkID + providerID + providerVersion`。
- 已存在同键的成功结果时，不得重复写入；重试只针对失败/缺失。
- 重复任务 **MUST** 返回已有结果，而不是生成第二份。

## 3. 引擎抽象

业务层只依赖协议，不直接依赖具体引擎：

```swift
// 示意，不是最终 API
protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var version: String { get }
    var supportedLanguages: [String] { get }

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions
    ) async throws -> TranscriptDraft
}
```

候选：

| 方案 | 优点 | 风险/成本 | 隐私 |
| --- | --- | --- | --- |
| Apple Speech（端上） | 系统自带、无包体积、支持中文 | 长音频需窗口切分；设备差异；离线模型可用性需验证 | 音频不出设备（`requiresOnDeviceRecognition`） |
| WhisperKit / 本地模型 | 准确率可控、可离线、可换模型 | 包体积/模型下载、内存与发热、需第三方依赖 ADR | 音频不出设备 |
| 云端 API | 准确率高、维护少 | 成本、延迟、网络依赖、合规与审核 | 音频离开设备，必须显式同意 |

**已定（ADR-0009）**：MVP **仅使用端上转写**，不调用云 STT、不上传音频/转写；混合/云端是后续版本路线，云端必须显式同意并提供本地替代。MVP 语言至少覆盖普通话与英语；其他语言按端上引擎能力启用（Q-015）。表内“音频不出设备”指 App 转写不上传；系统 iCloud 备份可能包含音频（Q-016）。

### 3.1 引擎选择标准

1. 中文（普通话）安静环境 CER/WER 基线。
2. 长音频窗口切分后的时间戳准确性。
3. 离线可用性与模型体积。
4. iPhone 上的转写速度与发热。
5. 隐私与合规成本。
6. 许可证与商业使用限制。

## 4. 调度与后台执行

- 转写队列 **MUST** 持久化；应用重启、崩溃后能恢复。
- 每个任务 **MUST** 携带 `sessionID/chunkID`；开始前与提交前都检查 `DeletionTombstone`/`DataEpoch`。
- 删除发生时 **MUST** 取消队列中与运行中的任务；提交事务 **MUST** 重新检查墓碑，命中则丢弃结果且不得写索引。
- 音频清理（`entityType=audio`）后，该分片 **MUST NOT** 再转写；已存在的转写保留。
- 触发时机：
  - 应用前台且空闲时；
  - 充电 + Wi‑Fi 时优先批量处理；
  - 使用系统后台任务（如 `BGProcessingTask`）在允许时执行，具体 API 以目标系统版本为准。
- 并发度默认 1；避免多任务同时转写导致发热与电量骤降。
- 热状态 `serious`/`critical` 时暂停新任务。
- 失败重试：指数退避；连续失败 N 次后标记为 `failed`，在 UI 中提供手动重试。
- 用户可在设置中暂停转写（例如只想保留音频）。

## 5. 质量指标

| 指标 | 目标（暂定） | 测量方式 |
| --- | --- | --- |
| 中文 CER（安静、近场） | < 15% | 固定评测集，人工校对基线 |
| 中文 CER（嘈杂/远场） | < 30% | 固定评测集 |
| 时间戳偏差 | 片段边界 ±1s 内 | 与人工标注对比 |
| 转写完成率 | ≥ 95% / 24h | 队列统计（充电 + Wi‑Fi） |
| 前台延迟 | P95 < 2 min/分片 | 性能测试 |
| 后台延迟 | P95 < 10 min/分片 | 性能测试 |

指标是工程目标，不是对外承诺；基线建立后更新本节并注明日期与设备。

### 5.1 评测集

- **MUST** 使用合成音频或明确授权的公开素材；不得使用真实用户录音。
- 覆盖：安静室内、办公室多人、街道噪声、远场（手表佩戴）、中文夹杂英文术语。
- 评测集与标注存放在仓库外或受控目录，不提交到公开仓库。

## 6. 检索

### 6.1 索引内容

- 以 `TranscriptSegment` 为最小索引单元。
- 每个索引条目包含：`segmentID`、`chunkID`、`sessionID`、`startMs`、`endMs`、文本、语言、引擎版本。
- 只索引当前“激活”的转写版本（`AudioChunk.activeTranscriptID`），避免同一分片多版本造成重复结果。

### 6.2 存储方案（已定：SwiftData + FTS5 侧车）

- **SwiftData** 存会话/分片/转写/元数据。
- **SQLite FTS5 侧车索引** 存检索片段；索引留在应用容器内，不进入系统级搜索。
- **分词器**：默认 `trigram`；同时评测 bigram 与 Core Spotlight，按命中率、P95、索引体积、隐私选优（ADR-0010）。
- **短查询索引**：额外维护 short-token FTS5（unigram+bigram 预分词）；1 字符走 unigram，2 字符走 bigram，≥3 字符走 trigram。查询路由按长度选择，避免 trigram 对 <3 字符不命中。
- 索引可从 SwiftData 重建；写入失败不回滚录音。
- MVP 不上云，不做 iCloud/CloudKit 同步。

### 6.3 中文检索的关键问题

- SQLite FTS5 的 `unicode61` 分词器按空白/标点切分，中文连续文本会被当成一个 token，导致“搜不到子串”。
- 解决路径：
  1. `trigram` 分词器（默认候选；支持中文子串匹配，索引更大）；
  2. 写入前用 bigram 或 `NaturalLanguage` 分词，查询时同样处理；
  3. 自定义分词器（成本最高）。
- **必须补齐短查询**：trigram 对 1–2 字符不命中；用 short-token 索引（unigram+bigram）处理，并纳入性能验收。
- 最终选择以 `Q-009` 基准评测为准（ADR-0010）。
- 无论选哪种，**MUST** 有测试覆盖：
  - 单字、双字、三字查询；
  - 中英混合查询；
  - 标点、数字、英文大小写；
  - 空查询与超长查询；
  - 10 万 segment 规模下的 P95 延迟。

### 6.4 查询能力（MVP）

- 关键词全文检索。
- 时间范围过滤（今天/昨天/自定义）。
- 按会话/按天分组。
- 排序：相关度（BM25 等）或时间；默认相关度 + 时间衰减。
- 结果展示：命中片段高亮、时间、会话、可跳转播放。
- 分页/懒加载，避免一次渲染全部结果。

### 6.5 结果与跳转

```swift
// 示意，不是最终 API
struct SearchHit: Sendable {
    let segmentID: UUID
    let chunkID: UUID
    let sessionID: UUID
    let startMs: Int64
    let endMs: Int64
    let snippet: String
    let score: Double
}
```

- 点击结果：定位到 `chunk`，`chunkOffsetMs = startMs - chunk.startedAt`，从命中点前 1–2 秒开始播放。
- 音频已删除但转写保留：显示文本并标注“音频不可用”，不崩溃。

## 7. 隐私

- **MVP 仅端上转写**；无云 STT、无上传（ADR-0009）。云端为后续版本，默认关闭。
- 云端转写必须：
  - 单独同意，说明音频会离开设备、服务商、保留策略；
  - 传输 TLS；服务商不得用于训练（需合同/条款）；
  - 提供“仅本地”替代路径；
  - 在隐私文档与 App Store 隐私标签中披露。
- 转写文本、搜索词、命中片段 **MUST NOT** 进入日志、分析事件或崩溃上报。
- 删除分片时，必须同时删除其转写与索引条目（见 `../architecture/data-model.md`）。

## 8. 失败与版本

### 8.1 错误码（示例）

| 错误码 | 含义 | 处理 |
| --- | --- | --- |
| `decode_failed` | 音频无法解码 | 标记失败，提示用户 |
| `unsupported_format` | 格式版本不兼容 | 保留音频，等待应用升级 |
| `engine_unavailable` | 引擎不可用（模型缺失/系统限制） | 重试或切换引擎 |
| `low_confidence` | 置信度低 | 保留结果，标记低置信度，不删除 |
| `cancelled` | 用户取消/系统终止 | 重新入队 |
| `quota_exceeded` | 云端配额/限流 | 退避重试，提示用户 |

### 8.2 引擎升级与重转写

- 引擎/模型版本变化时，旧结果 **MUST** 保留。
- 重转写生成新 `Transcript`，用户可选择激活版本；索引只保留激活版本。
- 重转写不得自动删除旧结果，除非用户显式选择。

## 9. 验收标准

- 已校验分片在充电 + Wi‑Fi 条件下 24h 内转写完成率 ≥ 95%。
- 同一分片重复入队不产生重复 Transcript；重试幂等。
- 中文单字/双字/三字查询均能命中；中英混合查询正常。
- 10 万 segment 规模下搜索 P95 < 200 ms。
- 删除分片后，搜索不再返回其任何片段。
- 转写失败在 UI 可见、可手动重试。
- 日志中不含转写文本、搜索词或音频内容。

## 10. 开放问题

- `Q-002` 已定：MVP 端上；目标混合（ADR-0009）。
- `Q-009` 已定：评测选优，默认 trigram（ADR-0010）。
- `Q-010` 已定：MVP 不做说话人分离。
- `Q-011` 已定：SwiftData + FTS5 侧车（ADR-0010）。
- `Q-015` 已定：至少普通话+英语；其他语言按端上引擎能力启用。
