# 使用入口与离线自动化

## 用户怎样提出任务

独立复现先确认原始工程归档已收到；**skill、队友预检输出和 handoff 补充包都不能代替完整工程归档**。只需提供完整归档或正确解压路径，不要求用户先逐项手填 RTL/top/part。Agent 应先运行 [收包检查](receiving.md)，空目录时立即列出恢复条件，不继续工具探测。

无需理解 S01-S14。给出任务、路径和停止边界即可；技术字段由 Agent 从当前资料核对。

| 场景 | 可直接使用的指令 |
| --- | --- |
| 审阅已有工程 | 使用这个 skill，检查 `F:\工程` 的 FSK 接收链。先只读审阅，列出有文件位置和证据的问题，不修改代码。 |
| 修复指定问题 | 使用这个 skill，修复 `F:\工程` 中这个仿真失败，日志在 `F:\日志`。允许修改相关 RTL 和测试台，运行受影响回归；不综合、不下载。 |
| 生成下载文件 | 使用这个 skill，从 `F:\工程` 完成输入核对、仿真和综合实现，目标 Vivado 2026.1。时序和 DRC 通过后生成 bitstream，到此停止。 |
| 核对成功归档 | 使用这个 skill，只读审计 `F:\结果.zip` 和协作记录，核对修复后的输入、最终报告、产物哈希和日志覆盖范围，列出已验证范围及缺口，不启动开发工具。 |
| 复现修复后版本 | 使用这个 skill，以 `F:\结果.zip` 中已修复的 work_copy 为输入，建立独立快照；完成 Vivado 2026.1 输入核对、真实仿真、综合实现、报告检查和归档，保留原始日志，交付唯一当前状态和可执行复现命令，生成 bitstream 后停止。 |
| 从零开发 | 使用这个 skill，为 EGO1 设计指定功能。先给出方案和验收标准，确认后开发；板卡资料在 `F:\资料`。 |

“继续”“按方案执行”沿用当前已确认范围，不要求重新复制计划。任务跨 chat 时提供方案路径和已有结果路径；不能假设另一 chat 的上下文已存在。

## Agent 的最短操作顺序

1. 识别本次范围和用户已有授权，只读检查当前相关资料。只加载本次 atom。
2. 输出已核对项及来源，将关键缺失项集中询问；不阻断与缺项无关的已授权只读工作。
3. 新工程/架构改动先确认方案；明确的小任务使用简短目标、文件范围和验收说明。
4. 进入执行前完成对应 preflight；按需使用下述辅助器。执行后交付改动、实际测试、产物路径及未完成项。

## 辅助器的能力与边界

`scripts/workflow.py` 只依赖 Python 3.10+ 标准库。当前离线验证环境及日志见外层 validation/validation.md。它不自动寻找 Vivado 安装、不决定 top、不解释 Tcl、不检查实际工具版本，也不自动批准任何硬件操作。EGO1 清单声明的版本必须是 2026.1，实际版本仍须由工具探测确认。

在技能目录中执行（其他环境可用 `python` 替代 `py -3.13`）：

```powershell
py -3.13 scripts/workflow.py inventory 'F:/工程'
py -3.13 scripts/receive_check.py 'F:/收到的完整工程.zip'
py -3.13 scripts/workflow.py parse-version 'F:/日志/vivado_version.stdout.log' --returncode 1
py -3.13 scripts/workflow.py snapshot --spec 'F:/任务/inputs.json' --out 'F:/任务/snapshot-01'
py -3.13 scripts/workflow.py verify 'F:/任务/snapshot-01/manifest.json'
py -3.13 scripts/workflow.py run --manifest 'F:/任务/snapshot-01/manifest.json' --command 'F:/任务/command.json' --out 'F:/任务/run-01'
py -3.13 -B -m unittest discover -s scripts -p 'test_*.py' -v
```

`inventory` 仅列出候选文件；不执行工程里的脚本。`snapshot` 按显式选择保存输入副本和配置哈希，`verify` 校验原文件、副本和所选目录成员。输出目录必须是新目录，位于所选输入目录之外；失败可能留下部分输出，换新目录重试，保留失败现场。

### 输入清单

以下 JSON 由 Agent 根据真实工程编写，示例值不能直接作为实际项目配置。文件和目录相对于 `workspace_root`；选目录时递归纳入其中全部文件，因此不要选择持续写入构建结果的目录。源文件、XDC、ROM/IP、include、测试和构建脚本均须审阅纳入；外部依赖需复制到工作区并记录原始来源。`configuration` 可扩展时钟复位、硬件来源和验收引用等字段，所有字段参与哈希。

```json
{
  "workspace_root": "F:/工程",
  "files": ["rtl", "sim", "constraints", "rom", "scripts"],
  "configuration": {
    "top": "actual_top",
    "part": "xc7a35tcsg324-1",
    "tool_version": "2026.1",
    "compile_order": ["rtl/actual_top.sv", "sim/actual_tb.sv"],
    "defines": [],
    "include_dirs": [],
    "parameters": {},
    "test_scope": ["actual_tb: reset and protocol assertions"]
  }
}
```

清单始终带 `dependency_completeness=agent_review_required`。哈希只能证明纳入文件的一致性，不能证明未列入的依赖不存在，也不是防恶意篡改的数字签名。运行前后校验不检测“中途修改再恢复”的情况；需要更强隔离时，应配置工具在快照副本上构建，并审查脚本中的绝对路径和外部引用。

### 显式命令留证

```json
{
  "argv": ["py", "-3.13", "scripts/check_results.py"],
  "cwd": ".",
  "timeout_seconds": 120
}
```

示例只表示参数格式，不能假设工程存在 `scripts/check_results.py`。只执行用户已授权范围内、经审阅的实际命令。`argv` 是参数数组，`shell=False`，不拼接用户字符串；需要 Windows `.bat`、重定向或管道时使用经核对的专用适配器，不能把 shell 语法直接当参数数组。命令本身具有用户权限，助手不是沙箱，不会限制命令的写入范围或净化工具日志中的秘密。

助手同步等待，保存 `stdout.log`、`stderr.log`、`result.json`、起止时间、参数、返回值、日志哈希和输入绑定。输出本身为新目录，禁止覆盖旧结果。

- 返回 0：命令正常退出且纳入清单的输入未变化；`acceptance=not_evaluated`，仍需检查断言、报告和验收项。
- 返回 2：输入缺失、改变、规格错误或输出冲突。
- 返回 4：子进程非零退出，保留原始 `process_returncode`。此处只表示命令失败；Agent 须先依据日志区分设计、工具和环境问题，再映射 atom 退出码，不自动修复。
- 返回 6：启动/服务异常，或超时后后代进程状态未经确认。超时会尝试终止进程树，必须检查状态，禁止自动重新启动。它不实现 atom 的异步取消确认协议。

## 怎样描述“已验证”

| 证据 | 可以支持的表述 |
| --- | --- |
| 交互截图 | 在该案例中被调用、进行了需求澄清或工作流尝试；工具成功仍需原始结果佐证 |
| 本包脚本回归日志 | 对应版本的离线辅助功能通过列出的测试 |
| 输入清单、实际工具版本、原始仿真与实现报告 | 对应工程和范围的执行步骤已验证 |
| 下载记录及接线、测量条件、原始数据 | 对应硬件测试项已验证 |

一次成功案例不能证明跨平台适用、自动修复可靠或完整无人值守。已有项目的测试结果只有绑定到当时实际使用的 skill、工程输入和执行记录后，才能作为对应 skill 流程的验证证据。

## 恢复执行后的交接

顶层复现说明必须指向唯一当前状态 JSON 和稳定复现入口。恢复后的状态引用最新完成的 attempt；初始阻塞状态单独标为历史。命令记录采用 `argv:string[]` 与 `cwd`，保留返回值、原始日志及哈希。重建命令注明来源，不伪装成当时捕获。修正后的脚本与保留的失败脚本分开标注；只做离线测试不能声称已通过真实工具验证。

旧归档保持原样，交接修订用新清单和补充包发布。并行开发使用独立输入快照，不能用历史仿真通过记录给修改后的设计放行。

时序修复后怎样选取固定输入、从 checkpoint 续跑，以及避免归档序列化内存溢出，见 [修复、续跑与流式留证](timing-recovery.md)。`evidence.py` 支持 `manifest`、`verify`、`compare` 和 `verify-zip`，明确区分所选文件哈希核对与完整工程验收。
