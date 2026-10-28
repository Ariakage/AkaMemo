# 开发环境

> 状态：活跃 · 最后更新：2026-10-28

## 1. 版本策略

| 工具/平台 | 版本 | 说明 |
| --- | --- | --- |
| macOS | 最新稳定版 | 以团队实际安装为准 |
| Xcode | 最新稳定版 | 团队统一；升级需在 PR 中说明 |
| Swift | Swift 6 语言模式 | 严格并发 |
| iOS Deployment Target | 18.0 | 已确认（ADR-0012） |
| watchOS Deployment Target | 11.0 | 已确认（ADR-0012） |
| swift-format | 随 Xcode 工具链 | `xcrun swift-format` |

版本升级规则：

- 升级 Xcode 或最低系统版本，必须单独 PR，并更新本表与 `AGENTS.md` §5（如命令变化）。
- 不得在功能 PR 中顺手升级工具链。
- 版本号以工程实际配置为准；本表是团队约定，不是 Apple 支持矩阵。

## 2. 账号与签名

- 需要 Apple Developer Program 账号（真机调试与 TestFlight）。
- 签名使用 Xcode 自动管理；**MUST NOT** 提交证书、Provisioning Profile、Team ID 以外的密钥材料。
- Team ID 与签名配置放在本地 `Local.xcconfig`（已被 `.gitignore` 忽略）；仓库只提交 `Local.xcconfig.example`。
- Bundle ID（已确认，ADR-0012）：

| Target | Bundle ID |
| --- | --- |
| iOS App | `com.ariakage.AkaMemo` |
| watchOS App | `com.ariakage.AkaMemo.watchkitapp` |
| Widget Extension | `com.ariakage.AkaMemo.widgets` |
| iOS Tests | `com.ariakage.AkaMemo.tests` |
| watchOS Tests | `com.ariakage.AkaMemo.watchkitapp.tests` |

修改 Bundle ID 属于发布契约变更，必须单独 PR 并由用户确认。

- 个人团队：Team ID 放本地 `Local.xcconfig`；TestFlight、iCloud/CloudKit 需要付费 Apple Developer Program，免费 Apple ID 只能短期真机调试。
- iCloud 容器预留 `iCloud.com.ariakage.AkaMemo`；**MVP 不启用**（ADR-0009）。

## 3. 创建工程（已完成，步骤保留作参考）

按以下顺序创建，完成后提交工程文件与共享 scheme：

1. **创建 iOS App**
   - Xcode → New Project → iOS → App。
   - Product Name：`AkaMemo`；Interface：SwiftUI；Language：Swift。
   - Organization Identifier：`com.ariakage`（已确认，ADR-0012）。
   - 保存到仓库根目录，生成 `AkaMemo.xcodeproj`。

2. **添加 watchOS App**
   - File → New → Target → watchOS → Watch App for iOS App（名称以当前 Xcode 为准）。
   - 名称：`AkaMemoWatch`；嵌入到 iOS App。
   - 确认 Watch App 的 Bundle ID 为 `com.ariakage.AkaMemo.watchkitapp`。

3. **添加共享包**
   - 创建 `Packages/AkaMemoCore`（Swift Package，库类型）。
   - 在 iOS 与 watchOS target 的 Frameworks 中添加本地包依赖。
   - Core **MUST NOT** 依赖 SwiftUI/UIKit/WatchKit。
   - 持久化用 SwiftData；全文索引用系统 SQLite FTS5 侧车（ADR-0010），不额外引入数据库依赖。

4. **添加测试 target**
   - `AkaMemoTests`（iOS 单元/集成测试）。
   - `AkaMemoWatchTests`（watchOS 单元测试）。
   - `AkaMemoCoreTests`（Package 内测试）。

5. **创建共享 scheme**
   - `AkaMemo`：iOS App + `AkaMemoTests`。
   - `AkaMemoWatch`：watchOS App + `AkaMemoWatchTests`。
   - `AkaMemoCore`：共享包测试。
   - 全部勾选 Shared，提交到 `AkaMemo.xcodeproj/xcshareddata/xcschemes/`。

6. **设置 Swift 6**
   - Build Settings → Swift Language Version = Swift 6。
   - Strict Concurrency Checking = Complete（或当前 Xcode 等价选项）。

7. **配置能力与 Info.plist**
   - iOS target：Microphone 用途描述；Q-018 不需要后台播放，**不声明** iOS Audio 后台模式。
   - watchOS target：Microphone 用途描述；音频后台模式。
   - iOS/watchOS target：`NSLocationWhenInUseUsageDescription`；Location Updates 后台模式；**不要**申请 Always。
   - 定位权限文案必须说明“录音时记录位置，默认只存本机”。
   - iOS target：Time Sensitive Notifications capability；`NSSupportsLiveActivities = YES`；添加 Widget Extension target `AkaMemoWidgets`。
   - 通知权限在 App 内请求；MVP 不申请 Critical Alerts，只配置 Time Sensitive。
   - **MVP 不启用 iCloud/CloudKit**；不要添加 iCloud capability 或云端 STT 配置。
   - Q-016 需要备份：设备级 iCloud 备份会包含 App 数据（音频约 2.07 GB/24h）；不需要 iCloud capability，但需在隐私说明中披露。
   - **必须验证** watchOS 后台音频的键名：`UIBackgroundModes` 还是 `WKBackgroundModes`。有开发者报告 `WKBackgroundModes` 不接受 `audio`，需以真机结果为准；结论回写本节。
   - 添加 `PrivacyInfo.xcprivacy`（按实际 API 与数据填写）。

8. **首次提交**
   - 提交 `AkaMemo.xcodeproj`、`Packages/`、测试 target、共享 scheme。
   - 不提交 `xcuserdata/`、`DerivedData/`、签名材料。

## 4. Scheme 契约

以下名称是 `AGENTS.md` 与 CI 的契约，**MUST NOT** 随意修改：

| Scheme | 用途 |
| --- | --- |
| `AkaMemo` | iOS App 构建与测试 |
| `AkaMemoWatch` | watchOS App 构建与测试 |
| `AkaMemoCore` | 共享包测试 |

`AkaMemoWidgets`（Widget Extension）属于 iOS App，随 `AkaMemo` scheme 构建，不单独设 scheme。

## 5. 构建与测试命令

```bash
# 查看 scheme
xcodebuild -list -project AkaMemo.xcodeproj

# 构建 iOS（模拟器）
xcodebuild -project AkaMemo.xcodeproj -scheme AkaMemo \
  -destination 'generic/platform=iOS Simulator' build

# 构建 watchOS（模拟器）
xcodebuild -project AkaMemo.xcodeproj -scheme AkaMemoWatch \
  -destination 'generic/platform=watchOS Simulator' build

# 查看可用模拟器
xcrun simctl list devices available

# 测试 iOS
xcodebuild test -project AkaMemo.xcodeproj -scheme AkaMemo \
  -destination 'platform=iOS Simulator,name=<可用设备名>'

# 测试 watchOS
xcodebuild test -project AkaMemo.xcodeproj -scheme AkaMemoWatch \
  -destination 'platform=watchOS Simulator,name=<可用设备名>'

# 共享包测试（纯 Swift 逻辑；产物放本地磁盘，避开 iCloud 扩展属性）
swift test --package-path Packages/AkaMemoCore --scratch-path /tmp/AkaMemoCoreBuild

# 格式检查 / 修复
xcrun swift-format lint --recursive AkaMemo AkaMemoWatch Packages
xcrun swift-format format --in-place --recursive AkaMemo AkaMemoWatch Packages
```

模拟器名称随 Xcode 版本变化；不要为了跑命令改 scheme 名。

- **iOS 模拟器测试统一使用 `iPhone 18 Pro`**（当前为 iOS 27.0）。同名设备可能有多个，必要时用 `xcrun simctl list devices available` 查到 UDID，并以 `-destination 'platform=iOS Simulator,id=<UDID>'` 指定。
- 仓库位于 iCloud Drive 时，SPM 产物会被文件提供器加上扩展属性，导致 codesign 报 `resource fork… not allowed`；共享包测试必须使用上面的 `--scratch-path` 指向本地磁盘。Xcode 构建同理，使用 `-derivedDataPath /tmp/AkaMemoDerived`。

## 6. 真机调试

录音相关的验收必须在真机完成。待测项与门禁状态集中维护在 [`device-testing-checklist.md`](device-testing-checklist.md)：

1. iPhone 开启 Developer Mode（设置 → 隐私与安全性 → 开发者模式）。
2. Apple Watch 开启 Developer Mode（Watch 设置 → 隐私与安全性 → 开发者模式），重启生效。
3. 在 Xcode → Window → Devices and Simulators 中确认 Watch 已配对并信任电脑。
4. 首次安装 Watch App 可能需要保持 Watch 解锁并在充电器上。
5. 无线调试可选；录音/传输测试建议有线优先，减少变量。

真机记录模板：

```text
设备：Apple Watch <型号> / watchOS <版本>
iPhone：<型号> / iOS <版本>
场景：<验证矩阵编号与描述>
GPS：开 / 关；定位权限：<>
通知权限：<>；Live Activity：可用 / 不可用
开始电量：<>% → 结束电量：<>%
时长：<> 分钟；分片：<> 个；丢失：<>；损坏：<>
中断/恢复：<> 次；日志导出：是 / 否
结果：通过 / 失败（附日志与复现步骤）
```

24h 可行性测试按 `../specs/24h-feasibility.md` 执行；GPS 组合按 `../specs/gps-tracking.md` 的 G-002；5% 低电量告警按 `../specs/battery-alerting.md` 的 G-003；录音保活/完整性按 `../specs/recording-health.md` 的 G-004；诊断日志按 `../specs/diagnostics.md` 的 G-005。结果回写对应文档与 ADR-0004～ADR-0008。

## 7. 模拟器限制

- 麦克风输入、后台音频、WatchConnectivity、蓝牙路由在模拟器上不可靠。
- 模拟器不会复现真实电量、热量、锁屏与佩戴遮挡。
- 模拟器可以模拟位置，但不能验证真实 GPS 信号、功耗与后台定位调度；G-002 必须真机。
- 模拟器可以预览 Live Activity/灵动岛布局，但不能验证 5% 真机电量、WatchConnectivity 送达与通知权限行为；G-003 必须真机。
- 看门狗、自动恢复、断电/强制退出、损坏注入必须真机；模拟器不能复现真实音频会话中断与文件系统断电。
- WatchConnectivity 在模拟器中依赖系统 `com.apple.Bridge`。配对 watch 与 iPhone 模拟器后，传输可能导致 `com.apple.Bridge` 断言崩溃且 iPhone 不投递文件；这是模拟器组件问题，不代表 AkaMemo 崩溃。传输与 inbox 必须在真机验证。
- 首次转写会弹出系统语音识别授权；模拟器可能没有对应语言的端上模型，授权后仍会返回 `engine_unavailable`。该路径只验证权限与失败展示，转写质量必须在真机验证。
- Watch 定位使用 When-In-Use 授权，并在 Info.plist 声明 `location` 后台模式；模拟器可用 `xcrun simctl privacy <UDID> grant location com.ariakage.AkaMemo.watchkitapp` 预授权。模拟器无法验证后台定位、功耗与 GPS 信号，G-002 必须真机。
- 模拟器可用于：UI 布局、纯逻辑、单元测试、导航流程。
- **不得**用模拟器结果作为录音链路验收依据。

### 7.1 模拟分片数据（仅 Debug）

为了让 iPhone 会话列表/播放/搜索/定位界面在没有配对 Watch 时也能测试，Debug 构建提供启动参数 `-AkaMemoSeedDemoChunks`。它会在启动后注入 3 个合成会话（共 9 个分片，6–12 秒正弦音），每个分片都走 `PhoneInboxService.receive` 的真实校验、去重、归档与 SwiftData 入库路径，等同于一次传输落地；随后为这些分片写入**合成转写文本**并建立 FTS5 索引，用于测试搜索与跳转播放；再为每个会话注入一条**合成 GPS 轨迹**（Null Island 附近的小弧线，2–10 个点），走 `TrackImporter` 的校验、校验和与入库路径，用于测试轨迹区、GPX 导出与设置页轨迹占用。不含任何真实录音、真实转写或真实位置。

```bash
xcrun simctl install <UDID> <构建产物>/AkaMemo.app
xcrun simctl launch <UDID> com.ariakage.AkaMemo -AkaMemoSeedDemoChunks
```

- 分片、会话与轨迹使用固定 UUID；带参数重复启动只会跳过已存在的分片/轨迹，不会重复入库。
- Debug 构建的会话列表左上角有虫子按钮，可直接打开演示会话的分片页；无窗口模拟器可用 `-AkaMemoOpenDemoSession` 启动参数自动打开同一页面，便于截图与无点击验证。
- 首次引导可用 `-AkaMemoOnboardingPreview` 强制显示，配合 `-AkaMemoOnboardingStep 1…3`（iPhone）/`1…4`（Watch）截图；`-AkaMemoSkipOnboarding` 仅 Debug 生效，用于跳过引导验证权限拒绝态，不会写入同意状态。
- 需要重置时删除模拟器上的 App（或抹掉模拟器数据）后重新安装。
- 该参数与代码仅在 Debug 构建存在，Release/TestFlight 不包含。

## 8. 故障排查

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| `No such module 'AkaMemoCore'` | 包未加入 target | 在 target 的 Frameworks 中添加本地包 |
| Watch App 安装失败 | 未开启 Developer Mode / 未信任 / Watch 未解锁 | 按 §6 检查 |
| 麦克风权限弹窗不出现 | Info.plist 缺少用途描述 | 检查 `NSMicrophoneUsageDescription` |
| 后台录音几秒后停止 | 音频会话未正确激活 / 后台模式未声明 | 检查能力与真机日志；确认前台启动 |
| 录音在锁屏后停止 | 后台音频键名/能力错误 | 验证 `UIBackgroundModes` vs `WKBackgroundModes` |
| 签名失败 | Team/Bundle ID 不匹配 | 检查 `Local.xcconfig` 与 Xcode 账号 |
| WatchConnectivity 收不到文件 | 未配对 / 不可达 / 传输队列阻塞 | 检查 `WCSession.activationState` 与未完成传输 |
| 转写一直 pending | 后台任务未调度 / 电量网络条件不满足 | 前台触发、充电、检查队列 |
| 定位权限弹窗不出现 | Info.plist 缺少用途描述 | 检查 `NSLocationWhenInUseUsageDescription` |
| 后台定位停止 | 未声明 Location Updates / 未在前台启动 / 后台重启 | 检查能力、启动顺序与 `CLBackgroundActivitySession` |
| 轨迹为空但录音正常 | 无权限、室内无信号、定位服务关闭 | 检查授权与轨迹状态；不要当作录音失败 |
| GPX 无法解析 | 时间/坐标格式错误、XML 非法 | 用 GPX 校验器检查，补单元测试 |
| 5% 通知不出现 | 通知权限被拒 / 能力缺失 / iPhone 不可达 | 检查权限、Time Sensitive capability、WatchConnectivity |
| Live Activity 不出现 | App 在后台 / Live Activities 被关闭 / 8h 上限 | 前台或点击通知启动；检查系统设置与活动状态 |
| 通知被称为“警报”但无 Critical 权限 | MVP 未申请 Critical Alert | 改为 Time Sensitive 文案，不得宣称警报级 |
| 录音中断但 iPhone 未通知 | 看门狗/通知权限/连接 | 检查 recording-health、Time Sensitive 权限、WatchConnectivity |
| 诊断日志为空 | 级别/文件日志关闭 | 检查 diagnostics 设置与文件权限 |

## 9. CI 计划

- 平台：GitHub Actions macOS runner。
- 阶段一（工程创建后）：模拟器构建 + 单元测试 + `swift-format lint`。
- 阶段二：共享包测试、覆盖率报告。
- 真机录音/传输测试不进入 CI，作为发布前手动验证。
- CI 不签名；不得在 CI 中存放证书或密钥。
- 工作流文件在工程创建后添加，并更新本节。

## 10. 本地配置文件

`Local.xcconfig.example`（可提交）：

```text
// 复制为 Local.xcconfig，填入本地值；Local.xcconfig 已被 git 忽略
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

**MUST NOT** 在示例文件中放真实 Team ID、证书名或密钥。
