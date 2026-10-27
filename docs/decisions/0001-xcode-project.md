# ADR-0001: 采用纯 Xcode 工程

- 状态：已接受
- 日期：2026-10-28
- 决策者：用户
- 关联：`Q-012`

## 背景

AkaMemo 需要同时构建 iOS App、watchOS App 与共享代码。仓库当前为空，需要先确定工程管理方式，因为它直接影响：

- 构建命令与 CI；
- 多 target/共享代码的组织；
- 多人/多代理协作时的合并冲突；
- 新成员的上手成本。

## 选项

1. **纯 Xcode 工程（`.xcodeproj`）**
   - 优点：Xcode 原生、零额外工具链、Apple 平台支持最直接。
   - 缺点：`project.pbxproj` 可读性差、合并冲突较多、scheme 需手工维护。
2. **XcodeGen（`project.yml`）**
   - 优点：声明式、diff 友好、易生成多 target。
   - 缺点：额外工具链；生成结果与 Xcode 手工修改可能漂移。
3. **Tuist**
   - 优点：模块化、缓存、适合大型工程。
   - 缺点：学习与维护成本高，对当前规模偏重。
4. **纯 Swift Package**
   - 优点：无 `.xcodeproj` 冲突。
   - 缺点：不适合直接产出 iOS/watchOS App、资源与签名管理受限。

## 决定

采用**纯 Xcode 工程**：

- 仓库提交 `AkaMemo.xcodeproj`。
- iOS 与 watchOS 两个 App target，共享代码放在本地 Swift Package `Packages/AkaMemoCore`。
- 提交共享 scheme：`AkaMemo`、`AkaMemoWatch`、`AkaMemoCore`。
- 不引入 XcodeGen/Tuist；未来若工程复杂度显著上升，另写 ADR 评估迁移。

## 后果

**正面**

- 新成员只需 Xcode，无额外安装步骤。
- Apple 平台能力（签名、预览、设备调试）开箱即用。
- 共享代码仍有清晰的包边界。

**负面**

- `project.pbxproj` 冲突风险高，尤其在多人同时添加文件时。
- 文件增删需要 Xcode 操作或谨慎手改。
- scheme 名称是人工契约，容易被误改。

**缓解**

- 小步 PR；新增文件尽量集中在功能目录，减少并发编辑。
- 不提交 `xcuserdata/`；共享 scheme 统一放在 `xcshareddata`。
- `AGENTS.md` 与 `environment.md` 固定 scheme 名称；改动需单独 PR。
- 合并冲突时以 `xcodebuild -list` 与构建结果为准，不盲目接受某一侧。

## 验证

- 工程创建后，以下命令可独立通过：
  - `xcodebuild -list -project AkaMemo.xcodeproj`
  - `xcodebuild -scheme AkaMemo build`
  - `xcodebuild -scheme AkaMemoWatch build`
- 新克隆仓库在未安装额外工具的情况下可构建。

## 回退

如果工程冲突或模块化需求显著增加：

1. 新增 ADR 评估 XcodeGen/Tuist；
2. 保留现有 `.xcodeproj` 一个版本周期；
3. 迁移后验证构建、测试、签名与 CI；
4. 不直接删除旧工程，直到新方案稳定。
