# ADR-0010: SwiftData + SQLite FTS5 侧车索引

- 状态：已接受（分词器以基准评测为准）
- 日期：2026-10-28
- 决策者：用户（`Q-011` SwiftData；`Q-009` 选最好的）
- 关联：`Q-009`、`Q-011`、ADR-0009、`../architecture/data-model.md`、`../specs/transcription-and-search.md`

## 背景

- 用户选择 **SwiftData** 作为持久化方案（`Q-011`）。
- 用户要求中文检索“选最好的”（`Q-009`），把分词/索引方案交给工程评测。
- SwiftData 没有内置全文检索（FTS），中文子串检索更不能依赖简单的空白分词。
- MVP 不上云（ADR-0009），因此索引只需本地可用，但要为未来 iCloud/后端同步预留。

## 选项

### 持久化

1. **SwiftData（已选）**：原生、与 SwiftUI 集成好、迁移工具体系；FTS 弱。
2. GRDB/SQLite：FTS5 原生、性能可控；第三方依赖。
3. Core Data：成熟；模板与并发复杂。

### 中文检索

1. **SQLite FTS5 trigram（默认候选）**：支持中文子串匹配；索引体积较大。
2. FTS5 + bigram 预分词：索引更小；查询与分词需一致。
3. Core Spotlight：系统分词、集成简单；转写内容可能出现在系统搜索，隐私需评估。
4. SwiftData 谓词：大数据量性能不足，不适合全文检索。

## 决定

1. **iPhone 端**：使用 SwiftData 存储会话、分片、转写、健康、位置等元数据。
2. **Watch 端**：使用轻量文件/JSON 与必要元数据，不共享 iPhone 的 SwiftData store。
3. **全文检索**：使用独立的 SQLite **FTS5 侧车索引**（系统 SQLite C API），只索引 `TranscriptSegment` 文本与必要定位字段。
4. **分词器**：默认候选 `trigram`；同时评测 bigram 与 Core Spotlight，按以下指标选优：
   - 中文单字/双字/三字查询命中率（recall/F1）；
   - P95 查询延迟（10 万 segment）；
   - 索引体积；
   - 隐私（是否进入系统搜索）；
   - 实现复杂度。
   - 评测结果写入本节；未被选中的方案保留为备选。
5. **一致性**：`SearchIndex` 协议负责增删改；索引损坏时可从 SwiftData 全量重建；写入失败不回滚录音。
6. **不做第三方依赖**：FTS5 通过系统 SQLite；若实现成本过高、需要 GRDB，必须另写 ADR。
7. **迁移**：SwiftData 使用 `VersionedSchema` / `SchemaMigrationPlan`；迁移前备份，迁移测试使用固定夹具。
8. **短查询**：额外维护 short-token FTS5（unigram+bigram 预分词）；1 字符走 unigram、2 字符走 bigram、≥3 字符走 trigram。查询按长度路由，避免 trigram 对 <3 字符不命中；纳入 Q-009 评测。
9. **未来 CloudKit**：
   - MVP 不启用 CloudKit；
   - 若未来启用，SwiftData + CloudKit 要求属性 optional/default、无 unique constraint、关系 optional；
   - 当前 schema 需避免不可迁移的强约束，或在同步层单独设计；
   - FTS5 索引不同步，云端恢复后需本地重建。

## 后果

**正面**

- 满足 SwiftData 选型；UI/业务与持久化集成好。
- FTS5 侧车解决中文全文检索，性能可控。
- 索引可重建，不把搜索故障变成数据故障。
- 无第三方依赖（默认路径）。

**负面**

- 两套存储（SwiftData + FTS5）需要一致性/重建逻辑。
- trigram 索引体积较大，需要监控。
- 分词器最终选择依赖评测，存在实现期调整。
- SwiftData + CloudKit 的未来兼容性需要提前约束 schema。

**必须验证**

- 10 万 segment 中文查询 P95 < 200 ms；索引体积可接受。
- 索引重建时间、崩溃恢复、删除级联。
- SwiftData 迁移测试。
- MVP 网络审计（无云同步）。

## 验证

见 `../specs/transcription-and-search.md` 的检索验收与 `../development/testing.md`。评测结果回写本节与 `Q-009`。

## 回退

- 如果 trigram 索引过大/过慢：切换 bigram 或 Core Spotlight（需隐私评估）。
- 如果 SwiftData 迁移受限：评估 GRDB/Core Data，另写 ADR。
- 如果 FTS5 实现成本过高：允许引入 GRDB，但必须写 ADR 并评估依赖/许可证/体积。
