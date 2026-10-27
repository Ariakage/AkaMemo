# AGENTS.md — AkaMemo 代理工作契约

本文件面向所有 AI 编码代理（Codex、Claude Code、Cursor 等），是仓库内的最高优先级工程约定。开始任何任务前先读本文件，再按需读 `docs/`。

> 与用户当前指令冲突时，以用户指令为准；但涉及隐私、安全、数据完整性的硬规则（§4）不得绕过，除非用户明确知情并确认。

## 1. 项目是什么

AkaMemo 是一个 Apple Watch + iPhone 双端应用：

- **Apple Watch**：全天候录音与位置采集入口，负责采集、分片、缓存与断点续传。
- **iPhone**：负责管理、转写、检索、轨迹导出、播放与隐私控制。
- **MVP 范围**：稳定录音 → 可靠传输 → 转写 → 全文检索。AI 总结、对话式回忆、说话人分离不在 MVP 内。
- **产品目标**：连续 24 小时不间断录音 + 录音期间记录 GPS 轨迹 + 5% 低电量告警/Live Activity（ADR-0004 / ADR-0005 / ADR-0006）。当前处于 G-001 / G-002 / G-003 可行性验证阶段；门禁通过前，任何对外材料不得承诺 24h、24h + GPS 或“自动灵动岛/警报级”。
- **可靠性目标**：录音保活、中断通知、自动恢复、已封口分片 0 损坏（ADR-0007）；实时诊断日志（ADR-0008）。
- **MVP 边界**：端上转写 + 本地存储，**不上云**（ADR-0009）。混合转写、iCloud、自建后端仅作为后续路线。

事实来源：

| 内容 | 唯一来源 |
| --- | --- |
| 产品目标与边界 | `docs/product/overview.md` |
| 功能需求与验收标准 | `docs/product/requirements.md` |
| 模块与依赖方向 | `docs/architecture/overview.md` |
| 数据模型与文件布局 | `docs/architecture/data-model.md` |
| 录音行为与技术约束 | `docs/specs/recording.md` |
| 24h 可行性门禁与测试方法 | `docs/specs/24h-feasibility.md` |
| 24h 产品目标 | `docs/decisions/0004-24h-recording-requirement.md` |
| GPS 轨迹与 GPX | `docs/specs/gps-tracking.md` |
| GPS 产品目标 | `docs/decisions/0005-gps-tracking.md` |
| 低电量告警与 Live Activity | `docs/specs/battery-alerting.md` |
| 低电量告警产品目标 | `docs/decisions/0006-low-battery-alerting.md` |
| 录音保活/自动恢复/完整性 | `docs/specs/recording-health.md` |
| 录音健康产品目标 | `docs/decisions/0007-recording-health-and-integrity.md` |
| 实时诊断日志 | `docs/specs/diagnostics.md` |
| 诊断日志决策 | `docs/decisions/0008-realtime-diagnostics.md` |
| MVP 本地优先/混合路线 | `docs/decisions/0009-mvp-local-first-hybrid-roadmap.md` |
| SwiftData + FTS5 检索 | `docs/decisions/0010-swiftdata-and-search-index.md` |
| 音频参数 | `docs/decisions/0011-audio-parameters.md` |
| 发布标识/最低版本 | `docs/decisions/0012-bundle-ids-and-deployment.md` |
| 转写与检索 | `docs/specs/transcription-and-search.md` |
| 隐私与安全 | `docs/privacy/privacy-and-security.md` |
| 已确认/待确认决策 | `docs/decisions/README.md` |

## 2. 开始任务前

按顺序读：

1. `docs/README.md` — 文档地图与维护规则
2. `docs/product/overview.md` — 产品边界与开放问题
3. `docs/architecture/overview.md` — 模块与依赖方向
4. `docs/development/environment.md` — 环境与命令
5. 与任务相关的 `docs/specs/*` 或 `docs/development/*`

然后：

- 用一两句话复述任务与验收标准。
- 列出要改的文件与验证方式。
- 需求不清时先问，不要臆造产品决策；临时假设写入 `docs/decisions/README.md` 的待决策清单。

## 3. 仓库结构（目标形态）

```text
AkaMemo.xcodeproj          # 纯 Xcode 工程（已确认，见 ADR-0001）
AkaMemo/                   # iOS app target
AkaMemoWidgets/            # Widget Extension：低电量 Live Activity
AkaMemoWatch/              # watchOS app target
Packages/AkaMemoCore/      # 双端共享：模型、协议、音频工具、存储抽象
Packages/AkaMemoCore/Tests # 共享层单元测试
AkaMemoTests/              # iOS 集成/单元测试
docs/                      # 产品、架构、规格、隐私、开发规范
```

规则：

- 共享代码只放 `Packages/AkaMemoCore`；两端 app 不得互相 import。
- 依赖方向：App → Core；Core 不依赖 SwiftUI / UIKit / WatchKit。
- 新增顶层目录前先更新本文件与 `docs/architecture/overview.md`。

## 4. 硬规则（MUST，违反即视为未完成）

### 4.1 隐私与数据

- 不得提交任何真实录音、转写文本、个人日程、设备标识或用户数据到仓库。测试音频必须是合成音频或明确授权的公开素材。
- 不得提交任何真实 GPS 轨迹、GPX 文件或可识别位置的数据；测试轨迹必须使用合成路线或明确授权的公开路线。
- GPS 首次授权后默认开启，但设置中必须可全局关闭；不得隐藏定位状态或每次录音反复弹窗。
- 通知/Live Activity 只含电量与录音状态，不含音频、转写、位置；MVP 不申请 Critical Alert，不得称“警报级”，不得承诺后台自动灵动岛或 24h 常驻。
- 自动恢复不得后台静默开麦；“静默恢复”仅关闭应用提示音/触觉，系统麦克风指示必须可见。
- 不得删除或隐藏损坏分片；不得把半截文件当作完整；不得伪造“录音中”。
- 诊断日志不得含音频、转写、经纬度、地址、文件名；不得上传。
- 未经用户明确同意，不得新增任何音频/转写数据的上传路径。
- **MVP 不得调用云 STT、接入自建后端或启用 iCloud/CloudKit 同步**；任何云路径必须新写 ADR 并获得用户同意。
- 日志、崩溃上报、分析事件不得包含音频内容、转写文本、经纬度、地址、轨迹、含用户信息的文件名。使用 `OSLog`，敏感字段加 `privacy: .private`。
- 删除必须是真删除：删除录音时同时删除分片、转写、索引、位置轨迹、GPX 缓存；不得只删数据库记录。
- 任何改变数据保留、上传、共享范围的改动，必须在 PR 中单独列出并由用户确认。

### 4.2 安全

- 不提交签名证书、Provisioning Profile、API Key、Token、`.xcconfig` 中的真实密钥。密钥走本地配置或环境变量，仓库只放 `.example`。
- 不关闭 ATS，不添加 `NSAllowsArbitraryLoads`，不绕过证书校验。
- 新增第三方依赖前必须：写 ADR（`docs/decisions/`）、说明许可证/体积/隐私影响、获得用户确认。

### 4.3 录音链路完整性

- 录音链路（采集 → 分片 → 落盘 → 传输 → 入库）的任何改动，必须覆盖：前台启动、退到后台、来电/Siri 中断、蓝牙切换、低电量、磁盘满、进程被杀、重复传输。
- 不得静默丢弃音频。失败必须可观测、可重试、可恢复。
- 分片文件写入必须原子化（临时文件 + rename），不得产生半截文件被当作完整分片。
- 不得在未验证的情况下修改音频格式、采样率、分片时长或文件命名；这些是跨版本兼容契约。

### 4.4 平台边界

- watchOS 不是 iOS：不得假设后台执行、网络、文件系统、内存能力与 iPhone 相同。
- 录音必须由用户在前台启动；后台只允许延续已开始的会话。中断后可在仍持有音频会话/后台执行时自动重试；若平台要求重新前台启动，必须由用户在前台确认。自动恢复不得在后台/锁屏/重启后无可见提示地开麦。
- 任何依赖新系统 API 的方案，必须写明最低系统版本与降级路径。

### 4.5 工程与协作

- 不直接 push `main`；所有改动走分支 + PR。
- 不擅自修改 bundle identifier、签名团队、最低系统版本、scheme 名称。这些是发布契约（ADR-0012）。
- 不删除或跳过测试来让 CI 变绿；不把失败测试标记为 skip，除非有 issue 链接与负责人。
- 不做任务范围外的大规模重构；必要重构单独 PR。
- 改行为必须同步改文档；新增架构决策必须写 ADR。

### 4.6 24h / GPS 可行性门禁

- 任何涉及续航、热、存储、传输积压的改动，必须参考 `docs/specs/24h-feasibility.md`。
- 不得通过缩短测试时长、降低判定标准、关闭关键日志等方式让 G-001“通过”。
- G-001 / G-002 / G-003 / G-004 / G-005 未通过前，不得在 README、TestFlight、App Store 或对外文案中承诺 24h 连续录音、24h + GPS、自动灵动岛、警报级通知、“绝不丢失/绝不损坏”或开放日志导出。
- G-001～G-005 结果变化必须回写 `docs/specs/24h-feasibility.md`、`docs/specs/gps-tracking.md`、`docs/specs/battery-alerting.md`、`docs/specs/recording-health.md`、`docs/specs/diagnostics.md` 与对应 ADR。

## 5. 常用命令

工程创建后，以下 scheme 名称与命令是契约（详见 `docs/development/environment.md`）：

```bash
# 列出 scheme
xcodebuild -list -project AkaMemo.xcodeproj

# 构建 iOS
xcodebuild -project AkaMemo.xcodeproj -scheme AkaMemo \
  -destination 'generic/platform=iOS Simulator' build

# 构建 watchOS
xcodebuild -project AkaMemo.xcodeproj -scheme AkaMemoWatch \
  -destination 'generic/platform=watchOS Simulator' build

# 共享包测试（纯 Swift 逻辑，最快）
swift test --package-path Packages/AkaMemoCore

# 单元测试（先查可用模拟器：xcrun simctl list devices available）
xcodebuild test -project AkaMemo.xcodeproj -scheme AkaMemo \
  -destination 'platform=iOS Simulator,name=<可用设备名>'

# 格式检查 / 修复
xcrun swift-format lint --recursive AkaMemo AkaMemoWatch Packages
xcrun swift-format format --in-place --recursive AkaMemo AkaMemoWatch Packages
```

注意：

- 模拟器名称随 Xcode 版本变化；命令跑不通时先查可用设备，不要改 scheme 名。
- watchOS 录音、WatchConnectivity、麦克风在模拟器上不可靠；涉及录音的验证必须在真机完成，并在 PR 中注明设备与系统版本。
- 工程尚未创建时，上述命令是目标契约；创建工程时必须使用相同的 scheme 名称。

## 6. 代码规范（摘要）

完整规范见 `docs/development/coding-style.md`。

- Swift 6 语言模式，严格并发；跨 actor 传递的类型必须 `Sendable`。
- SwiftUI + Observation（`@Observable`）；业务逻辑不写在 `View` 里。
- 4 空格缩进，行宽 100；提交前跑 `swift-format`。
- 禁止 `try!`、无依据的强制解包、`print`；错误必须显式处理或记录。
- 并发：UI 状态 `@MainActor`；音频采集/文件 IO 用专用 actor 或串行队列；不要用 `Task.detached` 逃避隔离。
- 日志用 `Logger(subsystem:category:)`，分类固定为 `recording`、`transfer`、`transcription`、`storage`、`location`、`battery`、`ui`、`diagnostics`。
- 新增用户可见文案必须进 `Localizable.xcstrings`，代码中不写死中文/英文。
- 命名遵循 Swift API Design Guidelines；类型用名词，方法用动词，布尔用 `is/has/should`。
- 文件按功能分目录，不按类型堆积；一个文件一个主要类型（小私有类型可同文件）。
- 持久化用 SwiftData；全文检索用 SQLite FTS5 侧车；不引入第三方数据库依赖，除非先写 ADR（ADR-0010）。
- 音频参数锁定为 AAC 96 kbps/声道 / 44.1 kHz / 立体声（多声道按硬件）/ 60 秒或 2 MB 分片；变更必须写 ADR 并更新 `docs/specs/recording.md`（ADR-0011）。

## 7. 测试与完成定义

最低要求：

- 共享层纯逻辑（分片、状态机、去重、检索排序）必须有单元测试。
- 录音链路改动必须有真机验证记录（设备、系统版本、场景、结果）。
- 数据迁移必须有升级测试或可回滚方案。
- UI 改动至少提供模拟器截图；关键流程（开始录音、停止、删除、搜索）保持可走通。

完成定义（Definition of Done）：

- [ ] 代码通过构建与现有测试
- [ ] 新增/修改逻辑有对应测试，或说明为何无法自动化
- [ ] `swift-format lint` 通过
- [ ] 无新增隐私/安全风险；如有，已在 PR 中说明
- [ ] 相关文档已更新（行为、架构、规格、ADR）
- [ ] PR 描述包含验证方式与未验证项
- [ ] 没有提交真实用户数据、密钥或本地产物

## 8. Git 与 PR

### 8.1 提交信息（强制）

所有提交 **MUST** 使用 Conventional Commits 格式；禁止空提交信息、`update`、`fix bug`、`WIP` 等无信息内容。

格式：

```text
<type>(<scope>): <subject>

<body>

<footer>
```

- `type` 必填，取值：`feat`、`fix`、`docs`、`refactor`、`test`、`chore`、`perf`、`build`、`ci`、`style`、`revert`。
- `scope` 必填，取值：`recording`、`transfer`、`transcription`、`search`、`storage`、`ui`、`watch`、`ios`、`core`、`docs`、`build`。
- `subject` 必填，动词开头，不超过 50 个字符，不加句号；中文或英文均可，但同一 PR 保持一致。
- `body` 说明“为什么”和影响范围；每行不超过 72 个字符；涉及录音、数据、隐私的改动 **MUST** 写。
- `footer` 用于 `BREAKING CHANGE:` 或 `Refs #123`；破坏兼容性 **MUST** 标注。

示例：

```text
feat(recording): 支持中断后从前台恢复录音

watchOS 在后台无法自动恢复音频会话，改为回到前台时提示用户续录，
避免 UI 显示“录音中”但实际已停止。

Refs #42
```

规则：

- 一次提交只做一件事；不要把重构、格式化、功能混在同一提交。
- 提交信息中 **MUST NOT** 出现真实录音内容、转写文本、个人信息、密钥。
- 推荐启用仓库模板：`git config commit.template .gitmessage`。
- 合并 PR 时使用 squash merge，squash 后的提交信息仍 **MUST** 符合上述格式。

### 8.2 分支与 PR

- 分支：`feat/<slug>`、`fix/<slug>`、`docs/<slug>`、`chore/<slug>`、`spike/<slug>`。
- PR：一个 PR 只解决一个问题；标题与提交同格式；描述写清背景、改动、验证、风险、文档影响。
- 合并：squash merge；合并前至少一次 review；不自行合并未经用户确认的 PR。
- 发布：版本号 SemVer，build number 单调递增；TestFlight 说明写用户可见变化与风险。

## 9. 代理工作方式

- 先读后写；先计划后改代码；小步提交，及时验证。
- 不确定的产品问题：停下来问用户，或写入待决策清单，不要用代码“替用户决定”。
- 发现与任务无关的问题：记录并告知，不顺手大改。
- 修改完成后的汇报必须包含：改了什么、怎么验证的、哪些没验证、风险是什么。
- 不得声称“已完成/已测试”，除非真的运行过对应命令；无法运行的验证要明确标注。

## 10. 任务导航

| 任务 | 先读 |
| --- | --- |
| 改录音行为/参数 | `docs/specs/recording.md`、`docs/architecture/data-model.md` |
| 24h 可行性/续航 | `docs/specs/24h-feasibility.md`、`docs/decisions/0004-24h-recording-requirement.md` |
| GPS / GPX / 定位权限 | `docs/specs/gps-tracking.md`、`docs/decisions/0005-gps-tracking.md` |
| 低电量告警 / 通知 / Live Activity | `docs/specs/battery-alerting.md`、`docs/decisions/0006-low-battery-alerting.md` |
| 录音保活 / 自动恢复 / 完整性 | `docs/specs/recording-health.md`、`docs/decisions/0007-recording-health-and-integrity.md` |
| 实时诊断日志 | `docs/specs/diagnostics.md`、`docs/decisions/0008-realtime-diagnostics.md` |
| 改持久化/检索 | `docs/architecture/data-model.md`、ADR-0010 |
| 改音频参数 | `docs/specs/recording.md`、ADR-0011 |
| 加云端/同步 | 先读 ADR-0009；必须新写 ADR，MVP 不得引入 |
| 改传输/同步 | `docs/architecture/overview.md`、`docs/specs/recording.md` |
| 加转写引擎 | `docs/specs/transcription-and-search.md`、`docs/decisions/` |
| 改数据模型/迁移 | `docs/architecture/data-model.md`、`docs/development/testing.md` |
| 改 UI/交互 | `docs/product/overview.md`、`docs/development/coding-style.md` |
| 改隐私/权限/上传 | `docs/privacy/privacy-and-security.md`（必须） |
| 搭环境/建工程 | `docs/development/environment.md` |
| 发版 | `docs/development/workflow.md` |
