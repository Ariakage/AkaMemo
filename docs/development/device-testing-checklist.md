# 待真机实测项

> 状态：活跃 · 最后更新：2026-10-28
>
> 本文件只列**无法在模拟器可靠验证、必须在 Apple Watch + iPhone 真机上完成**的项目。
> 通过标准以对应 spec 为准；本文件不复制阈值。模拟器结果只能用于 UI 与纯逻辑，不能作为录音链路验收依据（见 `environment.md` §7）。

## 使用方式

- 状态取值：`待实测` / `待实现` / `通过` / `失败` / `阻塞`。
- 每次涉及录音、后台、传输、GPS、通知、存储、迁移的 PR，更新相关行。
- 通过/失败必须记录：设备型号、watchOS / iOS 版本、日期、场景编号、分片数、丢失/损坏数、结果。
- 记录模板见 `environment.md` §6；结果回写对应 spec 与 ADR。
- 失败项保留，不删除；修复后重跑并追加重测记录。
- **MUST NOT** 把模拟器结果写成“通过”；至少标注“模拟器”。

## 当前基线

- 2026-10-28，`main` 已包含 PR #1～#17；PR #5 增加 `.parts` 启动恢复与损坏隔离；PR #6 增加 WatchConnectivity 传输与 iPhone inbox；PR #7 增加 envelope 校验；PR #8 增加 iPhone 会话列表与播放；PR #9 增加模拟器分片注入；PR #10 增加端上转写（FR-009）；PR #11 增加 FTS5 全文检索（FR-010）；PR #12 增加删除与墓碑传播（FR-012 部分）；PR #13 增加 iPhone 端实时诊断日志（FR-031 部分）；PR #14 增加低电量告警基础链路（FR-025～027 部分）；PR #15 增加 GPS 轨迹与 GPX 导出基础链路（FR-021/022 部分）；PR #16 增加低存储与录音保活通知基础链路（FR-013/028 部分）；PR #17 增加前台自动恢复与静默恢复（FR-029 部分）。
- 模拟器已验证：双端构建、单元测试、Watch 录音 UI、M4A 容器（`afinfo` 显示 `m4af`）、60 秒封口、`.parts` 启动恢复与损坏隔离。
- 模拟器**不能**验证：系统麦克风隐私指示、真实麦克风/后台/中断/断电/热/电量。
- 模拟器出现的异常短分片与音频停滞不代表真机行为，也不能证明真机不会出现。

## A. 已实现，待真机验证

| ID | 项目 | 期望 / 判定 | 依据 | 状态 |
| --- | --- | --- | --- | --- |
| D-001 | 麦克风权限与系统指示 | 授予权限并开始录音后，watchOS 状态栏出现橙色麦克风图标；停止后消失；App 不得也不能隐藏系统指示 | `specs/recording.md` §10、`privacy/privacy-and-security.md` | 待实测 |
| D-002 | 实际音频参数 | 文件为 M4A/AAC-LC，采样率、声道数、码率符合 ADR-0011；`afinfo` 与元数据一致；多声道按硬件实际值 | `specs/recording.md` §4、ADR-0011 | 待实测 |
| D-003 | 锁屏 / 放下手腕 30 分钟 | 持续录音；分片每 60 秒封口；UI 返回前台后状态一致 | `specs/recording.md` 矩阵 #1、#2 | 待实测 |
| D-004 | 后台 / 表盘切换 | 录音继续；音频会话保持；返回前台不伪造“录音中” | `specs/recording.md` §3.1 | 待实测 |
| D-005 | 来电 / Siri 中断 | 30 秒内进入 interrupted 并封口；中断结束后按 `shouldResume` 自动恢复，或提示用户前台继续 | `specs/recording.md` #3、#4；`recording-health.md` §3.4 | 待实测 |
| D-006 | 蓝牙耳机连接/断开 | 封口当前分片；按新路由继续；不产生短分片风暴 | `specs/recording.md` #5 | 待实测 |
| D-007 | 看门狗与自动恢复 | 音频进度停滞 10 秒进入 recovering；30 秒 interrupted；3 次 1/5/15 秒恢复；缺口可见；不伪造心跳 | `specs/recording-health.md` §3.1、§3.4、G-004 | 待实测（自动/静默恢复开关与 3 次重试已实现；活性信号需真机确认） |
| D-008 | 强制退出 / 断电 | 已封口分片 0 损坏；损失 ≤60 秒；`.parts` 可恢复或隔离 `.corrupt`；不把半截文件当完整 | `specs/recording-health.md` §5、G-004 #1、#2 | 待实测（启动恢复已实现） |
| D-009 | 正常停止 / 暂停 / 删除 | 状态正确；pending dead-man 通知取消；不触发中断告警 | `specs/recording-health.md` §3.2、G-004 #15 | 待实测（dead-man 取消已实现；真机通知待验证） |
| D-010 | 启动恢复真机 | 真实断电/强制退出后，下次前台启动恢复 `.parts`、sidecar 与 manifest；重复启动幂等；损坏段保留 | `specs/recording-health.md` §5.2 | 待实测（PR #5 实现） |
| D-011 | 存储阈值 | 可用空间 <1 GB 警告、<500 MB 停止新录音并提示；不覆盖未确认分片 | `specs/recording.md` §9.2 | 待实测（Watch 阈值与停止已实现；真机验证） |
| D-012 | 2 MB 提前封口 | 高码率或异常输入下按 2 MB 提前封口；正常输入按 60 秒封口 | `specs/recording.md` §5.2 | 待实测 |
| D-013 | 音频停滞检测边界 | 静音、风噪、蓝牙切换、系统音频服务重置下不误报；真实停录可检出 | `specs/recording-health.md` §3.3 | 待实测 |
| D-014 | 录音列表与播放 | 会话按开始时间聚合；播放/暂停/拖动进度与音频位置一致；切后台停止且不崩溃 | `product/requirements.md` FR-011、Q-018 | 待实测 |
| D-015 | 端上转写 | 已校验分片串行转写；仅端上（`requiresOnDeviceRecognition`）；降混单声道 16 kHz；时间戳映射正确；失败可见可重试；重启后续跑且幂等 | `specs/transcription-and-search.md` §2–§4、§9、ADR-0009 | 待实测（模拟器已接通权限与失败路径） |
| D-016 | 删除与墓碑传播 | chunk/session/all 级联删除音频、转写、索引、轨迹/GPX；先写墓碑；离线 Watch 重连后删除并回执；迟到分片拒绝且不复活；删除时转写不写回；新会话不被 delete-all 删除 | FR-012、AC-012、`architecture/data-model.md` | 待实测（模拟器集成测试通过；WatchConnectivity 未真机） |
| D-017 | 诊断日志与 G-005 | 实时滚动/过滤/暂停/清空/导出；日志与导出无音频、转写、坐标、文件名；7 天/5MB 轮转；Release 默认 info；1000 条渲染 P95 <100ms；Watch 批量转发 | FR-031、G-005、`specs/diagnostics.md` | 待实测（iPhone 端已实现；Watch 转发未实现） |
| D-031 | 全文检索与规模 | 中文单/双/三字与中英混合查询命中；搜索高亮、时间过滤、排序、跳转播放正确；删除后不可检索；10 万 segment P95 < 200 ms | `specs/transcription-and-search.md` §6、§9、ADR-0010 | 待实测（模拟器功能已用合成转写验证；规模与性能未测） |
| D-020 | WatchConnectivity 传输 | `transferFile` 传分片；iPhone inbox 校验/去重/入库；确认回执；重试退避；未确认不清理 | `specs/recording.md` §8、`architecture/data-model.md` | 待实测（PR #6 实现；模拟器配对后 Watch 显示 received，但 iPhone 模拟器未投递文件，且 `com.apple.Bridge` 会崩溃；需真机） |
| D-032 | 被杀后前台恢复 | 强制退出后重开 Watch App：显示“上次录音中断”与 3 秒倒计时，可取消；取消后手动继续；后台/锁屏不开麦；恢复后新分片序号续接、缺口可见；忽略后不再提示且不删音频 | `specs/recording-health.md` §3.4、G-004 #11、#12 | 待实测（模拟器逻辑已实现；真机待验证） |

## B. 尚未实现，实现后再真机验证

| ID | 项目 | 期望 / 判定 | 依据 | 状态 |
| --- | --- | --- | --- | --- |
| D-021 | 5% 低电量通知 + Live Activity | 5% 告警一次、去重、3% 安全停止；Live Activity 仅前台/点击启动；不得称警报级 | `specs/battery-alerting.md`、G-003 | 待实测（模拟器逻辑与权限弹窗已验证；真机/G-003 待验证） |
| D-022 | GPS 轨迹与 GPX | 5 分钟采样、拒绝权限仍录音、轨迹状态 degraded/unavailable、GPX 按会话起止裁剪 | `specs/gps-tracking.md`、G-002 | 待实测（采样/JSONL/导入/GPX 已实现；后台与功耗未验证） |
| D-023 | 诊断日志 | 实时、脱敏、7 天/5MB、导出过滤、无音频/转写/坐标/文件名 | `specs/diagnostics.md`、G-005 | 待实现 |
| D-024 | 24 小时连续录音 | 满电开始连续 24h；音频连续；0 丢失/损坏；设备未关机；结束电量 ≥5% | `specs/24h-feasibility.md`、G-001 | 待实现/待实测 |
| D-025 | 24h + GPS 组合 | 录音与轨迹并行；组合续航按 G-002 判定 | `specs/gps-tracking.md`、G-002 | 待实现 |
| D-026 | stateVersion 跨重启 | 同一会话跨 Watch 重启继续递增，不归零；新会话从 1；`health.json` 持久化 | `specs/recording-health.md` §3.3.1、G-004 #16 | 待实测（跨重启续录已实现；版本递增待真机确认） |
| D-027 | iPhone dead-man 通知 | 可达且 45 秒无心跳告警；90 秒 dead-man；stop/pause/delete 后取消 pending | `specs/recording-health.md` §3.2、G-004 #13、#15 | 待实测（45s/90s 已实现；真机通知/后台待验证） |
| D-028 | 通知/Live Activity 内容 | 仅电量与录音状态；无音频、转写、位置；状态与真实采集一致 | `privacy/privacy-and-security.md` | 待实现/待实测 |
| D-029 | iCloud 设备备份/恢复 | 备份包含音频；恢复后文件可读；备份回滚时提示并允许再次删除 | `privacy/privacy-and-security.md`（Q-016） | 待实测（系统能力） |
| D-030 | 迁移与升级安装 | 旧数据可读；迁移失败保留原库并可回滚 | `architecture/data-model.md`、`development/testing.md` | 待实现 |

## C. 门禁汇总

| 门禁 | 内容 | 当前状态 |
| --- | --- | --- |
| G-001 | 连续 24 小时录音 | 未开始 |
| G-002 | 24 小时 + GPS 组合 | 进行中（功能部分实现；24h 组合未测） |
| G-003 | 5% 低电量告警与 Live Activity | 进行中（模拟器逻辑；真机待验证） |
| G-004 | 录音保活、自动恢复、完整性 | 进行中（仅模拟器逻辑验证） |
| G-005 | 实时诊断日志 | 未开始 |

## D. 最近一次真机记录

尚无。完成首轮真机测试后在此追加，并同步更新上表状态。
