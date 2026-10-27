# 编码规范

> 状态：活跃 · 最后更新：2026-10-28
>
> 适用于 `AkaMemo/`、`AkaMemoWatch/`、`Packages/AkaMemoCore/` 与测试代码。

## 1. 格式与工具

- 缩进 4 空格，行宽 100，UTF-8，LF。
- 使用 `swift-format`，配置见仓库根目录 `.swift-format`。
- 提交前运行：

```bash
xcrun swift-format format --in-place --recursive AkaMemo AkaMemoWatch Packages
xcrun swift-format lint --recursive AkaMemo AkaMemoWatch Packages
```

- 不手工对齐冒号或等号；不引入与 `.swift-format` 冲突的格式化工具。
- 不在功能 PR 中做全文件格式化；格式化单独提交。

## 2. Swift 语言规范

### 2.1 版本与并发

- 使用 Swift 6 语言模式，严格并发检查。
- 跨 actor 传递的类型必须 `Sendable`；优先使用不可变 `struct`。
- UI 状态与 UI 相关方法标记 `@MainActor`。
- 可变共享状态用 `actor` 保护；不要用全局可变变量 + 锁。
- 禁止用 `Task.detached` 逃避 actor 隔离；如确需，必须注释原因并审查。
- 异步 API 支持取消；长任务定期检查 `Task.isCancelled`。
- 不使用 `@unchecked Sendable`，除非有注释说明不变量与保护方式。

### 2.2 访问控制

- 默认 `private` / `fileprivate`；模块内用 `internal`。
- `public` 只用于 `AkaMemoCore` 对外 API，并配文档注释。
- 不为了测试把内部类型改成 `public`；测试用 `@testable import`。

### 2.3 命名

遵循 Swift API Design Guidelines：

- 类型/协议：名词，`UpperCamelCase`；协议描述能力时可用 `-able`/`-ing`。
- 方法：动词开头，`lowerCamelCase`；布尔属性用 `is/has/should/can`。
- 常量：`lowerCamelCase`；避免魔法数字，提取为具名常量。
- 缩写统一：`URL`、`ID`、`UUID` 保持大写；不要自造缩写。
- 不使用匈牙利命名法；不在名称中重复类型。

```swift
// 推荐
func startRecording() async throws
var isTransferring: Bool
let maximumChunkDuration: Duration = .seconds(300)

// 避免
func doStartRecordingAction()
var transferringFlag: Bool
let MAX = 300
```

### 2.4 可选值与强制解包

- 禁止 `!` 强制解包，除非是不变量可证明且紧跟注释的极少数场景。
- 禁止 `try!`、`as!`。
- 用 `guard let` 提前返回，减少嵌套。
- 不对用户输入、文件内容、网络响应做强制解包。

### 2.5 错误处理

- 使用具体错误类型，不用字符串错误：

```swift
enum RecordingError: Error, Equatable {
    case permissionDenied
    case audioSessionFailed(code: Int)
    case storageFull
    case interrupted

    var userMessage: String {
        switch self {
        case .permissionDenied:
            String(localized: "recording.error.permission")
        case .audioSessionFailed:
            String(localized: "recording.error.audio")
        case .storageFull:
            String(localized: "recording.error.storage")
        case .interrupted:
            String(localized: "recording.error.interrupted")
        }
    }
}
```

- 不静默 `catch {}`；至少记录错误码，必要时上报 UI。
- 面向用户的错误信息与内部错误码分离；不要把底层错误直接展示给用户。
- 跨层错误用统一包装保留 `underlying`，便于排查。

### 2.6 值与引用类型

- 模型、消息、配置优先 `struct` + `Sendable`。
- 需要身份与共享可变状态时用 `final class` + `actor`/`@MainActor`。
- 不在 `struct` 中放大型可变缓冲区；音频缓冲用专门类型管理。

## 3. 架构与依赖

- 依赖方向：App → `AkaMemoCore`；Core 不依赖 UI 框架。
- 依赖通过初始化注入；不在业务代码中直接 `Singleton.shared`。
- 允许的全局单例：`Logger`（无状态）、系统 `NotificationCenter`；其他需 ADR。
- 时间为可注入依赖（`Clock`/`DateProvider`），便于测试。
- 文件系统路径通过 `FileManager` 抽象或注入根目录，便于测试与迁移。
- 协议定义在 Core；实现放在对应平台模块。

```swift
// 示意
protocol RecordingCoordinating: Sendable {
    func start() async throws
    func stop() async throws
    func pause() async throws
}
```

## 4. SwiftUI

- View 只做布局与事件转发；业务逻辑放 `@Observable` 的 ViewModel/Model。
- 优先 `@Observable`，不新引入 `ObservableObject`（除非需要 Combine）。
- `@State` 只放视图局部状态；跨视图状态放共享模型。
- 使用 `.task` 启动异步工作；利用其自动取消；不要在 `body` 中启动任务。
- 不在 `body` 中做文件 IO、解码、排序大数组。
- 拆小 View；单个 `body` 超过约 80 行时拆分。
- 列表使用稳定 ID（模型 UUID），不要用索引。
- 所有用户可见字符串走本地化资源。
- 关键控件提供 accessibility label/value/hint；支持 Dynamic Type。
- 颜色/字号用语义化资源（Asset Catalog / `.font(.body)`），不写魔法 RGB。
- 预览使用假数据与固定状态；预览不得访问真实文件或麦克风。

## 5. 音频与文件 IO

- 音频采集、编码、写文件在专用串行队列或 actor 中执行；不阻塞主线程。
- 不在音频回调中分配大对象、做文件 IO、打日志；回调只拷贝到预分配缓冲。
- 分片写入必须原子化：`.part` → 校验 → rename。
- 大文件不使用 `Data(contentsOf:)`；使用流式读写或 `AVAudioFile`。
- 文件路径只存相对路径；不要持久化绝对容器路径。
- 设置文件保护等级（见 `../architecture/data-model.md`）。
- 处理磁盘满、权限失败、文件被占用等错误，不得崩溃。

## 6. 日志

- 使用 `OSLog`：

```swift
private let logger = Logger(
    subsystem: "com.ariakage.AkaMemo",
    category: "recording"
)
```

- 固定分类：`recording`、`transfer`、`transcription`、`storage`、`location`、`battery`、`ui`、`diagnostics`。
- 敏感内容用 `privacy: .private`；转写文本、搜索词、文件名中的用户信息 **MUST NOT** 记录。
- 禁止 `print`、`debugPrint`、`dump` 进入提交。
- 发布版本不输出 debug 级日志；不记录高频循环日志。

## 7. 本地化与可访问性

- 用户可见文案放 `Localizable.xcstrings`，key 用点分命名：`recording.start.button`。
- 不在代码中写死中文/英文；测试断言用 key 或本地化后的字符串，不依赖某一种语言。
- 日期/时长用 `DateFormatter`/`Duration.FormatStyle`；不要手拼字符串。
- 布局考虑长文案与阿拉伯语等 RTL（未来）；避免固定宽度截断。
- 录音状态不只靠颜色表达；提供文本/图标/VoiceOver 描述。

## 8. 注释与文档

- 注释解释“为什么”，不重复代码“做了什么”。
- 公共 API 用 `///` 文档注释，说明参数、返回、错误与副作用。
- 复杂状态机、兼容性处理、平台限制必须有注释，并链接相关文档。
- 不保留被注释掉的代码；用 Git 历史。
- TODO 必须带负责人或 issue：`// TODO(#123): ...`。

## 9. 测试代码风格

- 测试命名表达行为：`func testChunkWriter_whenInterrupted_flushesCurrentChunk() async throws`。
- 一个测试只验证一个行为；避免巨型测试。
- 使用固定时钟、固定 UUID、临时目录；不依赖真实时间与网络。
- 测试音频用合成素材，不提交真实录音。
- 不为了测试在生产代码中开洞；用协议注入。

## 10. 反模式

| 反模式 | 替代 |
| --- | --- |
| `try!` / `as!` / 无依据 `!` | `guard let` + 明确错误 |
| `print` 调试 | `Logger` + 分类 |
| `DispatchQueue.main.async` 满天飞 | `@MainActor` + `async/await` |
| 巨型 View / 巨型 ViewModel | 拆分组件与用例 |
| 业务逻辑写在 `body` | 移到 Model/Service |
| 字符串错误码 | 具体 `Error` 类型 |
| 全局可变单例 | 初始化注入 |
| 主线程读写大文件 | 后台 actor/队列 |
| 静默 `catch {}` | 记录 + 可重试 |
| 硬编码用户文案 | 本地化资源 |
| 魔法数字 | 具名常量 |
| 把密钥放 UserDefaults | Keychain / 本地配置 |

## 11. 代码示例

```swift
@MainActor
@Observable
final class RecordingViewModel {
    private let coordinator: any RecordingCoordinating
    private(set) var state: RecordingViewState = .idle

    init(coordinator: any RecordingCoordinating) {
        self.coordinator = coordinator
    }

    func toggleRecording() async {
        do {
            switch state {
            case .recording:
                try await coordinator.stop()
                state = .idle
            default:
                try await coordinator.start()
                state = .recording
            }
        } catch let error as RecordingError {
            state = .failed(message: error.userMessage)
        } catch {
            state = .failed(message: String(localized: "recording.error.generic"))
        }
    }
}
```

```swift
actor ChunkWriter {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func write(_ data: Data, sequence: Int, startEpochMs: Int64) throws -> URL {
        let finalURL = directory.appending(path: "\(sequence)-\(startEpochMs).m4a")
        try data.write(
            to: finalURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        return finalURL
    }
}
```

> 示例是示意；实现时以 `docs/specs/` 与测试为准。
