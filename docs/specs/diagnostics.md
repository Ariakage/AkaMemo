# 实时诊断日志

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文定义应用内实时日志、脱敏、保留、导出与性能要求。决策见 `../decisions/0008-realtime-diagnostics.md`；隐私规则见 `../privacy/privacy-and-security.md`。
>
> 实现状态（2026-10-29）：iPhone 端内存环形缓冲、JSONL 每日路径/5MB 轮转/7 天保留、诊断页（实时/过滤/暂停/清空/导出提示/详细日志开关）与关键链路埋点已实现；Watch 端新增 500 条有界缓冲，记录录音状态、电量/存储阈值、定位开关、恢复与传输事件，每 30 秒或满 50 条通过 `transferUserInfo` 批量转发，iPhone 合并进同一缓冲/文件并带 `watch` 来源；离线时保留未发送条目。G-005 性能与真机验证未完成。

## 1. 目标与非目标

**目标**

- 在 iPhone 应用内实时查看录音、传输、转写、存储、电量、定位的健康状态。
- 支持按级别/分类过滤、暂停、清空、导出，便于用户与开发排查。
- 日志默认不含任何音频、转写、位置或用户内容。
- 日志写入不阻塞音频回调与主线程。

**非目标（MVP）**

- 远程日志上传、云端诊断、自动崩溃分析。
- 在 Watch 上提供完整日志查看器（仅 P1 紧凑视图）。
- 记录音频波形、转写全文、坐标等敏感内容。

## 2. 日志模型

```swift
struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: Level
    let category: Category
    let message: String
    let metadata: [String: String]  // 已脱敏
    let source: Source              // .watch / .iphone
}

enum Level: String, Codable, Sendable {
    case debug, info, warning, error
}

enum Category: String, Codable, Sendable {
    case recording, transfer, transcription, storage
    case location, battery, ui, diagnostics
}
```

规则：

- `message` 使用固定模板，不拼接用户内容；变量放 `metadata`。
- `metadata` 只放白名单键（如 `chunkSeq`、`durationMs`、`errorCode`、`state`、`count`、`succeeded`、`failed`）。
- 会话/分片 ID 截断为前 8 位；不记录完整 UUID 之外的设备标识。
- **MUST NOT** 记录音频、转写、经纬度、地址、文件名、联系人、搜索词。

## 3. 日志汇聚

| 目标 | 内容 | 默认 |
| --- | --- | --- |
| OSLog | 全部分类，系统级排查 | 开 |
| 内存环形缓冲 | 最近 2000 条，供实时 UI | 开 |
| JSONL 文件 | 结构化日志，7 天/5MB 轮转 | 开（可关） |
| 远程上传 | 无 | 永不 |

- 写入通过 actor/串行队列异步执行；音频回调只投递轻量事件，不做格式化/IO。
- 文件路径：`<Application Support>/AkaMemo/logs/<yyyy>/<MM>/<dd>/diagnostics.jsonl`。
- 文件保护：`.completeUntilFirstUserAuthentication`；文件名不含用户内容。
- 轮转：按天或 5MB；保留 7 天；用户可一键清空。
- 磁盘满：停止文件写入，保留内存缓冲；在诊断页提示。

## 4. 实时查看

`DiagnosticsView`（iPhone，Settings → 诊断）：

- 实时尾部滚动；新日志通过 `AsyncStream` 推送。
- 过滤：级别（debug/info/warning/error）、分类、来源（Watch/iPhone）。
- 暂停/继续、清空、搜索（只搜 message/metadata 白名单）。
- 显示 Watch 与 iPhone 日志，带来源徽标。
- 导出：生成 `.jsonl` 或 `.txt`，系统分享；导出前显示“日志可能包含设备标识，请确认接收方”。
- UI 刷新节流（≤10Hz）；大量日志时批量插入，避免主线程卡顿。
- Release 默认不显示 debug；用户可在诊断页开启“详细日志”，关闭时恢复 info。

## 5. Watch 集成

- Watch 端 `AppLogger` 记录 `recording`、`battery`、`storage`、`transfer` 等事件。
- 通过心跳/`transferUserInfo` 低频批量转发到 iPhone（例如每 30 秒或随分片确认）；不单独为每条日志建立连接。
- Watch 离线时本地环形缓冲（例如 500 条），回连后批量发送；丢弃最旧记录。
- Watch 端紧凑诊断视图（P1）：只显示最近事件与错误码，不显示完整日志。

## 6. 隐私与脱敏

- 白名单 metadata；新增日志字段必须经过隐私审查。
- 禁止 `print`、`debugPrint`、`dump`。
- 禁止把 `Error.localizedDescription` 直接写入日志（可能含路径/内容）；使用错误码。
- 导出前提示；导出文件不含音频/转写/位置。
- 日志保留 7 天；用户可清空；删除会话时不要求删除日志，但日志本身不含会话内容。
- 任何“上传日志”能力必须单独 ADR 与用户同意；MVP 不做。

## 7. 性能

- 音频回调/主线程不做日志格式化或文件 IO。
- 环形缓冲固定容量；超出丢弃最旧。
- 文件写入批量/异步；避免每条日志一次 `fsync`。
- UI 刷新节流；1000 条日志渲染 P95 < 100ms（测试机基线）。
- 24h 录音期间日志量受控：info 级为主，debug 默认关闭。

## 8. 失败与降级

| 情况 | 行为 |
| --- | --- |
| 磁盘满 | 停止文件日志；保留内存；诊断页提示 |
| 文件损坏 | 跳过损坏行；重建新文件；不崩溃 |
| Watch 不可达 | 本地缓冲；回连后批量发送；丢弃最旧 |
| 日志过多 | 丢弃最旧；提示“已截断” |
| 用户关闭详细日志 | 只保留 info/warning/error |
| 导出失败 | 提示原因；不影响录音 |

## 9. G-005 门禁

### 9.1 通过标准

| # | 标准 | 判定 |
| --- | --- | --- |
| 1 | 无敏感内容 | 日志/导出文件中无音频、转写、经纬度、地址、文件名 |
| 2 | 脱敏 | ID 截断；metadata 白名单；错误用错误码 |
| 3 | 配额 | 环形缓冲有界；文件 7 天/5MB；清空有效 |
| 4 | 导出 | 导出前提示；不自动上传 |
| 5 | 级别 | Release 默认 info；debug 需显式开启 |
| 6 | 性能 | 1000 条渲染 P95 < 100ms；音频回调无阻塞 |
| 7 | Watch 转发 | 批量、低频；离线缓冲；不显著增加耗电 |

任一失败 → G-005 失败；按 ADR-0008 降级，不得关闭脱敏。

### 9.2 测试条件

- 真机 + 模拟器；至少 2 种设备/系统组合。
- 场景：正常录音、24h 长录、强制退出、磁盘满、Watch 离线/回连、导出、清空、debug 开关。
- 用自动化测试扫描日志与导出文件中的敏感字段。

## 10. 验证矩阵

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 正常录音 30 分钟 | 实时日志滚动；无敏感内容 |
| 2 | 24h 长录 | 日志量受控；文件轮转；无卡顿 |
| 3 | 强制退出 | 已写日志保留；重启可查看 |
| 4 | 磁盘满 | 停止文件日志；内存仍可用；提示 |
| 5 | Watch 离线/回连 | 本地缓冲；回连批量发送 |
| 6 | 导出 | 文件可读；导出前提示；无敏感内容 |
| 7 | 清空 | 内存/文件清空；UI 更新 |
| 8 | debug 开关 | Release 默认 info；开启后 debug 可见 |
| 9 | 1000 条渲染 | P95 < 100ms；主线程不卡 |
| 10 | 敏感字段扫描 | 0 命中 |

## 11. 验收标准

- 应用内可实时查看 iPhone 与 Watch 的录音/传输/转写/电量状态。
- 日志与导出文件中无音频、转写、经纬度、地址、文件名。
- 环形缓冲有界；文件 7 天/5MB；清空有效；导出前提示。
- Release 默认 info；debug 需显式开启。
- 1000 条渲染 P95 < 100ms；音频回调无阻塞。
- G-005 通过。

## 12. 参考资料

- Apple Documentation: [`Logger`](https://developer.apple.com/documentation/os/logger)
- Apple Documentation: [`OSLog`](https://developer.apple.com/documentation/os/oslog)
- Apple Documentation: [`AsyncStream`](https://developer.apple.com/documentation/swift/asyncstream)
- 隐私规则：`../privacy/privacy-and-security.md`
- 录音健康：`recording-health.md`

> 日志字段与脱敏规则变更必须更新本文与 ADR-0008，并补充测试。
