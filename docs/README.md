# AkaMemo 文档

本目录是 AkaMemo 的事实来源。代码回答“怎么做”，文档回答“为什么这样做”和“什么算做对了”。

## 文档地图

| 路径 | 内容 | 主要读者 | 状态 |
| --- | --- | --- | --- |
| `product/overview.md` | 产品定位、用户、场景、边界、风险 | 所有人 | 活跃 |
| `product/requirements.md` | 功能需求、验收标准、非功能需求 | 产品、开发、测试 | 活跃 |
| `architecture/overview.md` | 系统上下文、模块、依赖方向、数据流 | 开发 | 活跃 |
| `architecture/data-model.md` | 实体、状态机、文件布局、迁移与保留 | 开发 | 活跃 |
| `specs/recording.md` | 录音行为、音频参数、watchOS 约束、验证矩阵 | Watch/iOS 开发、测试 | 活跃 |
| `specs/24h-feasibility.md` | 连续 24 小时可行性门禁 G-001、测试矩阵、通过标准 | 所有人 | 活跃 |
| `specs/gps-tracking.md` | GPS 轨迹采样、存储、隐私、GPX 导出、G-002 门禁 | Watch/iOS 开发、测试 | 活跃 |
| `specs/battery-alerting.md` | 5% 低电量通知、Live Activity、阈值与 G-003 门禁 | iOS/Watch 开发、测试 | 活跃 |
| `specs/recording-health.md` | 心跳/看门狗、自动恢复、异常通知、完整性、G-004 门禁 | Watch/iOS 开发、测试 | 活跃 |
| `specs/diagnostics.md` | 实时诊断日志、脱敏、配额、G-005 门禁 | 所有人 | 活跃 |
| `specs/transcription-and-search.md` | 转写管线、引擎抽象、检索索引 | iOS 开发 | 活跃 |
| `privacy/privacy-and-security.md` | 数据分级、同意、加密、日志、审核、事件响应 | 所有人 | 活跃 |
| `development/environment.md` | 环境、建工程清单、构建命令、真机调试 | 开发 | 活跃 |
| `development/workflow.md` | 分支、提交、PR、review、发布 | 所有人 | 活跃 |
| `development/coding-style.md` | Swift / SwiftUI / 并发 / 日志 / 本地化规范 | 开发 | 活跃 |
| `development/testing.md` | 测试策略、测试夹具、完成定义 | 开发、测试 | 活跃 |
| `decisions/README.md` | ADR 流程、已确认决策索引、待决策清单 | 所有人 | 活跃 |
| `decisions/0001-xcode-project.md` | 采用纯 Xcode 工程 | 开发 | 已接受 |
| `decisions/0002-mvp-scope.md` | MVP 范围 | 所有人 | 已接受 |
| `decisions/0003-watch-recording-strategy.md` | Watch 录音与传输策略 | Watch/iOS 开发 | 提议中 |
| `decisions/0004-24h-recording-requirement.md` | 连续 24 小时录音作为产品目标 | 所有人 | 已接受 |
| `decisions/0005-gps-tracking.md` | 录音期间记录 GPS 并支持 GPX | 所有人 | 已接受 |
| `decisions/0006-low-battery-alerting.md` | 5% 低电量告警与 Live Activity | 所有人 | 已接受 |
| `decisions/0007-recording-health-and-integrity.md` | 录音保活、自动恢复与分片完整性 | 所有人 | 已接受 |
| `decisions/0008-realtime-diagnostics.md` | 实时诊断日志 | 所有人 | 已接受 |
| `decisions/0009-mvp-local-first-hybrid-roadmap.md` | MVP 本地优先、端上转写与后续混合/云端路线 | 所有人 | 已接受 |
| `decisions/0010-swiftdata-and-search-index.md` | SwiftData + SQLite FTS5 侧车索引 | 开发 | 已接受 |
| `decisions/0011-audio-parameters.md` | 立体声 96 kbps/声道 / 44.1 kHz 音频参数 | 开发、测试 | 已接受 |
| `decisions/0012-bundle-ids-and-deployment.md` | 发布标识、最低系统版本与个人团队 | 开发、发布 | 已接受 |

## 按角色阅读

**产品/需求**

1. `product/overview.md`
2. `product/requirements.md`
3. `specs/24h-feasibility.md`（24h 可行性门禁）
4. `specs/gps-tracking.md`（GPS/GPX 与 G-002）
5. `specs/battery-alerting.md`（低电量告警与 G-003）
6. `specs/recording-health.md`（保活/自动恢复/完整性）
7. `specs/diagnostics.md`（实时诊断日志）
8. `decisions/README.md` 的待决策清单

**iOS / watchOS 开发**

1. `architecture/overview.md`
2. `architecture/data-model.md`
3. `specs/recording.md`（录音）/ `specs/transcription-and-search.md`（转写）/ `specs/24h-feasibility.md`（续航验证）/ `specs/gps-tracking.md`（GPS）/ `specs/battery-alerting.md`（低电量告警）/ `specs/recording-health.md`（保活完整性）/ `specs/diagnostics.md`（诊断日志）
4. `development/environment.md`
5. `development/coding-style.md`
6. `development/testing.md`
7. `privacy/privacy-and-security.md`（强制）

**AI 编码代理**

1. 仓库根目录 `AGENTS.md`
2. `docs/README.md`（本文件）
3. `architecture/overview.md`
4. 与任务相关的规格文档

**Reviewer**

1. `product/requirements.md` 的验收标准
2. `privacy/privacy-and-security.md` 的 PR 检查清单
3. `development/workflow.md` 的 review 要求

## 维护规则

### 单一事实来源

同一事实只在一个文件里定义，其他文件用链接引用，不复制。对应关系：

| 事实 | 唯一来源 |
| --- | --- |
| 产品目标、用户、非目标 | `product/overview.md` |
| 功能需求与验收标准 | `product/requirements.md` |
| 模块划分与依赖方向 | `architecture/overview.md` |
| 实体、字段、状态机、文件路径 | `architecture/data-model.md` |
| 音频参数、录音行为 | `specs/recording.md` |
| 24h 可行性门禁与测试方法 | `specs/24h-feasibility.md` |
| GPS 采样、存储、GPX 与 G-002 | `specs/gps-tracking.md` |
| 低电量阈值、通知、Live Activity 与 G-003 | `specs/battery-alerting.md` |
| 录音保活、自动恢复、完整性、G-004 | `specs/recording-health.md` |
| 实时诊断日志、脱敏、G-005 | `specs/diagnostics.md` |
| 转写与检索行为 | `specs/transcription-and-search.md` |
| 隐私与安全规则 | `privacy/privacy-and-security.md` |
| 命令与工具链 | `development/environment.md` |
| Git/PR/发布流程 | `development/workflow.md` |
| 代码风格 | `development/coding-style.md` |
| 测试要求 | `development/testing.md` |
| 已做/待做的技术决策 | `decisions/` |

### 什么时候必须改文档

| 代码改动 | 必须同步 |
| --- | --- |
| 用户可见行为 | `product/requirements.md` + 对应 spec |
| 音频格式、分片、传输 | `specs/recording.md` + `architecture/data-model.md` |
| 数据模型、迁移、保留策略 | `architecture/data-model.md` |
| 模块边界、依赖、第三方库 | `architecture/overview.md` + ADR |
| 权限、上传、日志、留存 | `privacy/privacy-and-security.md` |
| 构建命令、scheme、签名 | `development/environment.md` + `AGENTS.md` §5 |
| 测试策略 | `development/testing.md` |

### 写作约定

- 中文为主；代码标识符、API 名、命令保持英文。
- 需求用 `FR-xxx`、非功能需求用 `NFR-xxx`、开放问题用 `Q-xxx`，编号不复用。
- 规范级别用 RFC 2119 关键词：**MUST**（必须）、**SHOULD**（应该）、**MAY**（可以）。
- 日期用绝对日期（`2026-10-28`），不写“昨天”“下周”。
- 图用 Mermaid，保证 GitHub 可直接渲染。
- 不写真实姓名、设备 ID、录音内容、密钥。
- 文档中的“建议/待定”必须明确标注，不能伪装成已确认决策。

### 废弃与变更

- 过时文档不直接删除：在标题下标注 `> 状态：已废弃（原因，日期）`，并链接替代文档。
- 改变已接受决策时，新增 ADR 说明取代关系，不修改旧 ADR 的结论。
- 文档大幅重写时，在 PR 描述中说明原因与影响范围。

## 文档状态

| 状态 | 含义 |
| --- | --- |
| 草案 | 正在讨论，不能作为实现依据 |
| 活跃 | 当前有效，实现以它为准 |
| 已接受 | ADR 中的决策已生效 |
| 提议中 | ADR 中的方案等待验证或确认 |
| 已废弃 | 仅保留历史，不再生效 |
