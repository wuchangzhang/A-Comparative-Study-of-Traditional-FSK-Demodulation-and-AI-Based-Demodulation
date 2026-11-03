# 公共运行契约

## 1. 通用输入与结果信封

每个 atom 的必填公共输入：`run_id:string`、`task_scope:string`、`workspace_root:string`、`output_dir:string`、`preflight:object`。路径执行前解析为绝对路径，检查读写范围。具体 atom 列出其业务字段；未特别标为可选的字段均必填。

`preflight` 至少包含：

```yaml
complete: false
checked_items: []
missing_items: []
questions: []
hardware_sources: []
resume_condition: null
```

`checked_items` 记录字段、值或路径、来源和核对结果；`hardware_sources` 记录 MCP 查询或用户提供资料的名称、版本/revision、路径及适用范围。所有会创建/修改工程、启动工具或操作硬件的 atom 必须先取得 `complete=true`。S02 可在需求输入完整时生成待用户确认的详细方案，但方案确认前不得路由到执行 atom。

需要工具的 atom 另接收 `tool_adapter:object`，结构见入口。需要来源绑定的 atom 接收 `input_manifest:string`，指向不可变输入清单。

统一结果字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| run_id / atom_id | string | 所属任务与原子编号 |
| status | string | queued/running/succeeded/failed/blocked/cancelled |
| exit_code | integer 或 null | 运行中为 null，终态按 §2 |
| job_id | string 或 null | 异步作业标识 |
| outputs | object | 对应 atom 结果；缺少的测量值用 null |
| logs | object[] | §4 日志记录 |
| artifacts | object[] | path、sha256、kind、producer_run_id、input_manifest_hash |
| error | object 或 null | code、message、evidence_paths、recovery_condition |
| preflight | object | 完整性结论、缺失项、已提问题和恢复条件 |
| started_at / finished_at | string 或 null | ISO 8601，含时区 |

数值未知时不得填写 0。解析不到的字段返回 null 并解释原因。终态 `succeeded` 必须对应退出码 0。

## 1.1 输入完整性与交互阻塞

独立复现先检查收到的归档确有工程输入。指定目录为空、只有 skill/补充包/预检输出时，立即形成输入阻塞结论；不得为了补全记录继续启动 MCP/Vivado/许可证探测，除非用户明确另行授权独立环境检查。参考 [收包与工具预检](references/receiving.md)。一次保存的 skill 快照可由后续预检 attempt 按哈希引用，不重复复制同一历史验证树。

路由 atom 前逐项检查本次范围所需的方案、工程、工具、验收和硬件资料。必需输入缺失、值互相冲突、来源不适用或尚未经用户确认时：

- 返回 `status=blocked`、`exit_code=2`，并在 `preflight.missing_items` 中逐项记录；
- 用明确问题向用户索取每一项信息，问题写入 `preflight.questions`；
- 在 `resume_condition` 中说明哪些资料经核对后才可继续；
- 不进入目标 atom 的流程，不创建 `job_id`，不以默认值或历史上下文补齐；
- 用户补充后重新执行 preflight；仍有缺项则继续提问，直到 `complete=true`。

涉及硬件事实时，先探测并使用实际可用的 AMD Vivado AI / Vivado extension MCP 查询相关手册、原理图、约束、pin mapping、IP 和工程上下文。MCP 不可用、失败或无资料时，不得自行联网搜索或凭记忆补全；必须将具体资料列为缺失项并请求用户提供原始文件、路径或原文。用户资料未到位前，相关流程保持 blocked。

## 2. 退出码

以下为本修订版统一定义，不继承未提供的旧 atom 隐含定义。

| 码 | 语义 | 路由 |
| --- | --- | --- |
| 0 | 本 atom 范围内完成并满足判据 | 可进入下一阶段 |
| 2 | 请求或输入契约不完整/不合法 | blocked，终止当前链 |
| 3 | 版本、工具能力或必需依赖不满足 | blocked，终止当前链 |
| 4 | 已取得证据的设计/工程验证失败，可按范围修复 | failed，允许 S07 |
| 5 | 作业执行总时限届满或被取消 | failed 或 cancelled，终止当前链 |
| 6 | I/O、服务异常或任务状态不确定 | failed，终止当前链 |

缺少板卡、仪器或未确认接线属于输入/前置条件不足，返回 2。连接异常不伪装成设计失败。S06 成功解析失败报告时可以返回 0，但 `outputs.acceptance` 必须为 fail，不能据此放行上板；S07 成功完成诊断返回 0，不表示故障已经解决。

## 3. 异步与时限

S04/S05/S09/S12/S13/S14 启动后返回 `job_id`、running 和 null 退出码；S11 通常为同步分析，除非适配器另有声明。状态查询沿用同一 job_id。记录输出目录及可用的查询/取消操作。回调仅在配置了真实可达端点时使用，否则轮询。

上述是 atom 适配器的契约。随包 `scripts/workflow.py run` 是同步命令留证助手，不实现异步 atom 协议，`job_id=null`；不得伪造异步 ID 或将其 result.json 当作 S04/S05 的最终准入证据。

默认单次状态查询等待不超过 30s。查询等待结束但作业仍运行时继续返回 running，不记为执行超时。入口所列为默认总执行时限，可由本次配置显式覆盖并记录。

到达总时限时尝试取消，保存日志和已生成产物；确认停止后返回 5。无法确认停止时返回 6 并记录进程/作业标识，不自动重启。用户取消后不继续修复链。

## 4. 日志

`logs[]` 的每条记录含 `timestamp:string`、`level:string`（debug/info/warning/error）、`stage:string`、`message:string`；可选 `tool_code:string`、`path:string`、`line:integer`。原始工具日志单独保留，结构化摘要不能覆盖原文。

不在日志和提交物中保留密钥、令牌或认证信息。不得编造不存在的工具输出。

## 5. 隔离、快照与写入

- 每次 atom 使用 `output_dir/<atom_id>/<attempt>/` 独立目录，交接使用显式产物路径和哈希。
- 原始 RTL、约束、host、ROM/IP 和原始资料只读；只有 S03 在 `write_allowlist` 内可修改工程源文件。S01 可创建/更新其声明的工程配置和构建文件，不能改源文件内容。
- S03 写入前保存被修改文件的原字节、哈希和原路径；新建文件记录为原先不存在。快照失败则停止，不能先改后补。
- 输入清单覆盖源文件、top、part、XDC、宏、include、编译顺序、ROM/IP 初始化、参数、工具版本、测试及构建脚本。缺失外部依赖则不得宣称完整快照。
- 可用 `scripts/workflow.py snapshot` 保存所选输入及配置，`verify` 检查原文件、副本、配置哈希和所选目录新增/删除文件。脚本不会解析 HDL/IP 依赖；清单完整性仍由 Agent 审阅，配置中显式列出实际编译顺序、宏、参数、include 和测试范围。外部依赖须先经授权复制到工作区并记录来源，不能静默忽略。
- S04/S05/S12/S13 使用同一组可验证的不可变输入。开始和结束检查清单；检测到输入变化返回 2，废止本次准入资格。
- 修复前原件、修复后验证基线和生成产物分别建清单。前后比较必须采用相同选择/排除策略，不能拿原始输入列表与含全部 build/sim 输出的列表作整体比较。允许路径的修改仍须重新仿真，不等于准入。
- `input_manifest_hash` 绑定所有验证证据。S05 另绑定 S04 证据哈希；bitstream 记录文件哈希和生成阶段；S09 记录实际下载文件的哈希、器件身份和实测条件。
- `knowledge/` 全 atom 只读，只有 S08 可在声明的路径追加或修改。不得借 S08 修改用户个人记忆。
- 不删除、不覆盖无关文件；打包副本采用英文路径，不重命名原始资料。

## 6. 验收与追溯

每项验收含 `check_id`、`requirement`、`method`、`threshold`、`reference_source`、`evidence_paths`、`result`（pass/fail/not_run/blocked/not_applicable）。阈值不得临时调整以迁就结果；确需修改时先修订需求基线，保留原因并重新验证。

综合成功、实现完成、时序通过、bitstream 生成、下载成功分别记录。上板准入至少要求当前输入对应的仿真通过、实现完成、声明时钟/约束检查通过、setup/hold 无失败、无未解释的未约束关键路径和阻断 DRC。

保留工具版本、完整命令或结构化调用参数、时间、输入/输出哈希、测试条件、参考值、原始数据和结论。没有实测证据时不得报告硬件功能通过。

仅报告兼容性或归档工具失败时，保留原失败状态并区分设计阶段。已停止的作业可按 [续跑条件](references/timing-recovery.md) 从可追溯 checkpoint 发起新 attempt；不修改原记录，不自动将工具失败映射为 RTL 失败。归档按冻结后的文件逐项处理，明确完整清单与关键文件清单的覆盖范围。
