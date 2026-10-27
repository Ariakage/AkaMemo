# ADR-0012: 发布标识、最低系统版本与个人团队

- 状态：已接受
- 日期：2026-10-28
- 决策者：用户
- 关联：`Q-007`、`Q-012`、ADR-0009、`../development/environment.md`

## 背景

用户确认：

- 最低系统版本：**iOS 18 / watchOS 11**。
- 使用**个人 iCloud 账号**与域名 **ariakage.com**。

需要固定 Bundle ID、Organization Identifier、签名与 iCloud 容器，避免创建工程后反复修改发布契约。

## 选项

1. **以 `ariakage.com` 反转为 `com.ariakage`，个人团队签名（已选）**
   - 优点：与域名一致、清晰、可长期使用。
   - 缺点：个人团队在 iCloud/TestFlight/配额上有限制。
2. 使用默认 `com.example` 或随机前缀
   - 缺点：后续迁移麻烦，不适合发布。
3. 企业/组织团队
   - 当前不适用。

## 决定

1. Deployment Target：
   - iOS **18.0**
   - watchOS **11.0**
2. Organization Identifier：`com.ariakage`
3. Bundle ID：

| Target | Bundle ID |
| --- | --- |
| iOS App | `com.ariakage.AkaMemo` |
| watchOS App | `com.ariakage.AkaMemo.watchkitapp` |
| Widget Extension | `com.ariakage.AkaMemo.widgets` |
| iOS Tests | `com.ariakage.AkaMemo.tests` |
| watchOS Tests | `com.ariakage.AkaMemo.watchkitapp.tests` |

4. 签名：个人 Apple Developer 团队；Team ID 放本地 `Local.xcconfig`，不入库。
5. iCloud/CloudKit：
   - 容器预留 `iCloud.com.ariakage.AkaMemo`；
   - **MVP 不启用**（ADR-0009）；启用时需要付费 Apple Developer Program 与 iCloud capability。
6. 个人账号限制：
   - 免费 Apple ID 可在设备上短期调试，但 **TestFlight、iCloud/CloudKit、推送等能力需要付费 Apple Developer Program**；
   - 如果当前只有免费 iCloud 账号，MVP 本地构建可继续，但发布/iCloud 路径需先升级账号。
7. Bundle ID 与 Deployment Target 是发布契约；修改必须单独 PR 并由用户确认。

## 后果

**正面**

- 标识与域名一致，后续上架/iCloud 不需要迁移。
- 版本目标明确，UI/API 可按 iOS 18/watchOS 11 设计。
- 个人团队配置简单。

**负面**

- 个人团队在 iCloud/TestFlight/配额上受限；可能需要升级付费账号。
- 未来若改为组织团队，Bundle ID 可保留，但签名/协议需重新配置。
- iOS 18/watchOS 11 会排除更旧设备。

**必须验证**

- 使用个人团队在真机安装 iOS/watchOS App。
- 如启用 iCloud：CloudKit 容器可创建、同步可用（MVP 不启用）。
- TestFlight 构建（需付费账号）。

## 验证

- `xcodebuild -showBuildSettings` 确认 Bundle ID/Deployment Target。
- 真机安装、Watch 配对安装。
- TestFlight 上传（若账号支持）。

## 回退

- 如果必须支持更旧系统：新写 ADR，评估 API 降级。
- 如果 Bundle ID 需要变更：在首个 TestFlight 前完成；上架后变更视为新 App。
- 如果个人账号无法满足 iCloud/TestFlight：升级 Apple Developer Program，不改变 Bundle ID。
