# AkaMemo

> 把 Apple Watch 变成全天候的记忆入口：Watch 负责录音与轨迹，iPhone 负责整理与回忆。

AkaMemo 是一个 Apple Watch + iPhone 双端应用。Apple Watch 承担全天候可用的录音与位置采集入口，iPhone 承担管理、转写、全文检索、GPX 导出与隐私控制。

**当前状态：文档先行 + 24h 可行性验证待执行。** 产品目标已确认为连续 24 小时不间断录音；**MVP 不上云**（端上转写 + 本地存储），音频参数立体声 AAC 96 kbps/声道 / 44.1 kHz；Xcode 工程尚未创建。创建步骤见 `docs/development/environment.md`，可行性门禁见 `docs/specs/24h-feasibility.md`。

## 核心原则

- **隐私优先**：App 不主动上传录音与转写；系统 iCloud 备份可能包含音频（Q-016），见隐私文档。
- **不丢音频**：先落盘、再传输；分片、校验、幂等、断点续传是底线。
- **全天候可用**：Watch 端录音必须在真实佩戴场景下可靠，而不是只在演示里可用。
- **可检索**：转写不是终点，能按时间、关键词快速找回才是。
- **可诊断**：中断、损坏、恢复都有可见状态与实时日志，不静默失败。
- **MVP 不上云**：音频、转写、索引由 App 本地处理；不集成云 STT/后端/CloudKit；系统备份例外见隐私文档。

## MVP 范围

1. Watch 端录音（前台启动、后台延续、中断可恢复；目标连续 24 小时，需通过 G-001 门禁）
2. 录音期间记录 GPS 轨迹，支持 GPX 导出（需通过 G-002 门禁）
3. Watch 电量 5% 时向 iPhone 发高优先级通知，低电量 Live Activity/灵动岛（需通过 G-003 门禁）
4. 分片可靠传输到 iPhone
5. 端上转写（MVP 不上云；混合/云端为后续）
6. 全文检索与录音管理
7. 录音保活、中断通知、自动恢复与完整性校验（需通过 G-004 门禁）
8. 实时诊断日志（需通过 G-005 门禁）

不在 MVP 内：AI 总结、对话式回忆、说话人分离、多端同步、Web 端、云转写、自建后端、iCloud/CloudKit 同步、音频/转写导出（Q-014）。

立体声 96 kbps/声道 / 44.1 kHz 下 24 小时音频约 **2.07 GB**；存储、传输与电量按此评估（ADR-0011）。

## 文档

| 文档 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | AI 编码代理的工作契约（先读这个） |
| [docs/README.md](docs/README.md) | 文档地图与维护规则 |
| [docs/product/overview.md](docs/product/overview.md) | 产品定位、场景、边界、风险 |
| [docs/product/requirements.md](docs/product/requirements.md) | 功能需求与验收标准 |
| [docs/architecture/overview.md](docs/architecture/overview.md) | 系统架构、模块、数据流 |
| [docs/architecture/data-model.md](docs/architecture/data-model.md) | 实体、状态机、文件布局 |
| [docs/specs/recording.md](docs/specs/recording.md) | 录音规格与 watchOS 约束 |
| [docs/specs/24h-feasibility.md](docs/specs/24h-feasibility.md) | 连续 24 小时可行性验证（G-001） |
| [docs/specs/gps-tracking.md](docs/specs/gps-tracking.md) | GPS 轨迹、GPX 与 G-002 |
| [docs/specs/battery-alerting.md](docs/specs/battery-alerting.md) | 5% 低电量通知、Live Activity 与 G-003 |
| [docs/specs/recording-health.md](docs/specs/recording-health.md) | 录音保活、自动恢复、完整性与 G-004 |
| [docs/specs/diagnostics.md](docs/specs/diagnostics.md) | 实时诊断日志与 G-005 |
| [docs/specs/transcription-and-search.md](docs/specs/transcription-and-search.md) | 转写与检索规格 |
| [docs/privacy/privacy-and-security.md](docs/privacy/privacy-and-security.md) | 隐私、安全、合规、审核 |
| [docs/development/environment.md](docs/development/environment.md) | 环境搭建与建工程清单 |
| [docs/development/workflow.md](docs/development/workflow.md) | Git、PR、发布流程 |
| [docs/development/coding-style.md](docs/development/coding-style.md) | Swift / SwiftUI 编码规范 |
| [docs/development/testing.md](docs/development/testing.md) | 测试策略与完成定义 |
| [docs/decisions/README.md](docs/decisions/README.md) | 已确认决策与待决策清单 |
| [docs/decisions/0004-24h-recording-requirement.md](docs/decisions/0004-24h-recording-requirement.md) | 连续 24 小时产品目标与门禁 |
| [docs/decisions/0005-gps-tracking.md](docs/decisions/0005-gps-tracking.md) | GPS 记录与 GPX 产品决策 |
| [docs/decisions/0006-low-battery-alerting.md](docs/decisions/0006-low-battery-alerting.md) | 5% 低电量告警与 Live Activity 决策 |
| [docs/decisions/0007-recording-health-and-integrity.md](docs/decisions/0007-recording-health-and-integrity.md) | 录音保活、自动恢复与完整性决策 |
| [docs/decisions/0008-realtime-diagnostics.md](docs/decisions/0008-realtime-diagnostics.md) | 实时诊断日志决策 |
| [docs/decisions/0009-mvp-local-first-hybrid-roadmap.md](docs/decisions/0009-mvp-local-first-hybrid-roadmap.md) | MVP 本地优先与混合/云端路线 |
| [docs/decisions/0010-swiftdata-and-search-index.md](docs/decisions/0010-swiftdata-and-search-index.md) | SwiftData + FTS5 检索 |
| [docs/decisions/0011-audio-parameters.md](docs/decisions/0011-audio-parameters.md) | 立体声 96 kbps/声道 / 44.1 kHz 音频参数 |
| [docs/decisions/0012-bundle-ids-and-deployment.md](docs/decisions/0012-bundle-ids-and-deployment.md) | Bundle ID 与最低系统版本 |

## 仓库结构（目标）

```text
AkaMemo.xcodeproj
AkaMemo/                  # iOS app
AkaMemoWidgets/           # Widget Extension：低电量 Live Activity
AkaMemoWatch/             # watchOS app
Packages/AkaMemoCore/     # 双端共享代码
AkaMemoTests/             # iOS 测试
docs/                     # 文档
```

## 参与开发

1. 先读 [AGENTS.md](AGENTS.md)。
2. 再读 [docs/README.md](docs/README.md) 选择与任务相关的文档。
3. 所有改动走分支 + PR；不要直接 push `main`。
4. 录音、隐私、数据删除相关的改动必须附真机验证记录。

## 隐私提醒

本项目处理的是高度敏感的个人音频与位置轨迹。请勿在 issue、PR、提交信息或测试夹具中放入任何真实录音、转写文本、GPS 轨迹或个人信息。详见 [docs/privacy/privacy-and-security.md](docs/privacy/privacy-and-security.md)。

## License

TBD.
