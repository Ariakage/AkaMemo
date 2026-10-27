# 开发流程

> 状态：活跃 · 最后更新：2026-10-28
>
> 提交信息的强制格式定义在仓库根目录 `AGENTS.md` §8.1，本文不重复，只补充分支、PR 与发布流程。

## 1. 分支模型

采用短生命周期分支 + squash merge：

| 分支 | 用途 | 生命周期 |
| --- | --- | --- |
| `main` | 可发布、始终可构建 | 长期 |
| `feat/<slug>` | 新功能 | 合并后删除 |
| `fix/<slug>` | 缺陷修复 | 合并后删除 |
| `docs/<slug>` | 文档 | 合并后删除 |
| `chore/<slug>` | 构建、依赖、杂项 | 合并后删除 |
| `spike/<slug>` | 技术验证，可不合并 | 验证结束后删除或转 ADR |

规则：

- `main` 受保护：禁止直接 push，必须 PR。
- 分支从最新 `main` 切出；长期分支需定期 rebase/merge `main`。
- 一个分支只做一件事；超过约 400 行有效 diff 时，考虑拆分。

## 2. 提交

- **MUST** 使用 `AGENTS.md` §8.1 规定的 Conventional Commits 格式。
- 推荐执行一次：

```bash
git config commit.template .gitmessage
```

- 提交前自检：
  - 没有真实录音、转写、个人信息、密钥；
  - 没有 `xcuserdata/`、`DerivedData/`、`.DS_Store`；
  - 提交信息能说明“为什么”，不只是“改了什么”。

## 3. PR 流程

### 3.1 创建前

1. 从最新 `main` 切分支。
2. 完成实现与最小验证集（见 `testing.md`）。
3. 自读 diff；删除调试代码、临时日志、无关格式化。
4. 更新相关文档（见 `../README.md` 的维护规则）。

### 3.2 PR 描述

使用 `.github/pull_request_template.md`，至少包含：

- 背景与目标；
- 主要改动；
- 验证方式（命令、设备、场景、结果）；
- 隐私与数据影响；
- 文档更新；
- 风险与未验证项。

UI 改动附模拟器/真机截图；录音链路改动附验证矩阵编号与结果。

### 3.3 Review

Reviewer 检查：

- 行为是否符合 `product/requirements.md` 的验收标准；
- 是否违反 `privacy/privacy-and-security.md`；
- 录音链路是否覆盖失败场景；
- 并发、错误处理、资源释放是否正确；
- 测试是否覆盖新增逻辑；
- 文档是否同步；
- 是否有范围外改动。

规则：

- 至少一次 review 才能合并。
- 作者不能自己批准自己的 PR（单人项目可由用户明确批准例外）。
- AI 代理生成的改动 **MUST** 在 PR 中标注，并由人 review；代理不得自行合并。
- 未解决的 blocking comment 不得合并。

### 3.4 合并

- 使用 squash merge，squash 后的提交信息仍须符合 Conventional Commits。
- 合并后删除远程分支。
- 合并前确认 CI 通过（工程创建后启用）。
- 不启用 auto-merge，除非用户明确要求。

## 4. 版本与发布

### 4.1 版本号

- SemVer：`MAJOR.MINOR.PATCH`。
- `MAJOR`：不兼容的数据/行为变更（如音频格式版本升级导致旧分片不可读）。
- `MINOR`：向后兼容的新功能。
- `PATCH`：向后兼容的修复。
- Build number 单调递增，不复用。

### 4.2 发布检查清单

- [ ] 所有 P0 验收标准通过
- [ ] 录音验证矩阵 P0 场景通过（真机）
- [ ] G-001 通过，或本版本未对外承诺 24h 连续录音
- [ ] G-002 通过，或本版本未对外承诺 24h + GPS
- [ ] G-003 通过，或本版本未对外承诺自动灵动岛/警报级
- [ ] G-004 通过，或本版本未宣称“绝不丢失/绝不损坏”
- [ ] G-005 通过，或本版本未开放诊断日志导出
- [ ] MVP 无云上传：网络审计无云 STT/后端/iCloud 同步
- [ ] 立体声 96 kbps/声道音频按 2.07 GB/24h 评估存储与传输
- [ ] 定位权限文案、Location Updates 后台模式与隐私标签已更新
- [ ] 通知权限、Time Sensitive、Live Activities 能力已配置；Critical Alert 未申请/未启用
- [ ] 隐私文档与 App Store 隐私标签更新
- [ ] `PrivacyInfo.xcprivacy` 与实际 API/数据一致
- [ ] 版本号与 build number 正确
- [ ] TestFlight 说明写清用户可见变化、已知问题、数据影响
- [ ] 回滚方案明确（至少可回退到上一 TestFlight 构建）
- [ ] 没有提交密钥、证书、真实用户数据

### 4.3 TestFlight

- 内部测试优先；涉及录音链路的改动必须至少一轮真机内部测试。
- 说明中写明：
  - 新增/变化的行为；
  - 已知问题；
  - 需要重点验证的场景；
  - 数据是否兼容旧版本。

### 4.4 热修复

- 从 `main` 切 `fix/<slug>`，最小改动，单独 PR。
- 修复后补测试与文档；不得只改代码。
- 若涉及数据迁移，必须评估降级与回滚。

## 5. 文档与代码同步

| 改动 | 同步文档 |
| --- | --- |
| 用户可见行为 | `product/requirements.md` + 对应 spec |
| 音频格式/分片/传输 | `specs/recording.md` + `architecture/data-model.md` |
| 数据模型/迁移 | `architecture/data-model.md` |
| 模块/依赖/第三方库 | `architecture/overview.md` + ADR |
| 权限/上传/日志/保留 | `privacy/privacy-and-security.md` |
| 构建命令/scheme/签名 | `development/environment.md` + `AGENTS.md` §5 |
| 测试策略 | `development/testing.md` |

## 6. Issue 与决策

- 缺陷用 issue 记录：现象、复现步骤、设备/系统版本、期望行为、日志（不含内容）。
- 技术决策用 ADR：背景、选项、决定、后果、验证方式。
- 需求争议先写开放问题（`../decisions/README.md`），不要在 PR 里悄悄决定。

## 7. 代理协作

- 代理开始任务前读 `AGENTS.md` 与相关文档。
- 代理必须报告：改了什么、怎么验证、哪些没验证、风险。
- 代理不得：
  - 直接 push `main`；
  - 自行合并 PR；
  - 修改签名/证书/Bundle ID；
  - 提交真实数据；
  - 删除/跳过测试来让 CI 变绿。
- 代理产出的 PR 需要人工 review；review 重点见 §3.3。
