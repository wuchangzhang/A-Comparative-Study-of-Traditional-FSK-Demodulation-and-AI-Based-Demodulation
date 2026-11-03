# 修复、续跑与流式留证

用于时序修复、报告兼容失败后的 checkpoint 续跑，以及大型目录归档。依据是 EGO1 u_receiver 的实际使用问题；不是可直接运行的通用 Vivado 适配器。

## 时序修复与验收口径

- 从 routed 路径的起终点定位 RTL 决策/使能逻辑，确认组合计算是否跨越 MAC、搜索和投票逻辑；不只按源码行长判断。
- 增加流水寄存器时检查周期对齐、valid/enable、状态跳转、复位、非阻塞赋值读旧值、位宽、signed 和截断。阈值、搜索步长和偏置等算法参数不随时序修复顺手修改。
- 原始只读快照、修复后验证基线、生成产物分别管理。保存原字节、两侧哈希与 unified diff；格式化 `Compare-Object` 输出只是展示记录。
- 先受影响测试，再验收规定的全部回归；冻结修复后输入，重新建立 S04 → S05 绑定。允许修改路径清单不能替代回归。
- 最终数字来自最终交付 DCP 对应报告，记录其 SHA-256、报告文件及生成命令。中间 route 的裕量只作历史数据；小幅正裕量只证明本次实现通过，不证明其他 seed、工具或硬件条件的裕量。
- 机器准入记录 setup/hold 失败端点、WNS/TNS/WHS/THS、DRC、声明时钟与未约束检查。检查不支持或无法解析时填 unknown/null 并停止最终放行，不能跳过该项。
- `no_input_delay` 等警告逐端口/路径记录实际用途、同步/异步结构、适用约束和依据；“都是异步端口”或计数相同不足以豁免。DRC 0 errors 不等于无 warning。

## 已有 checkpoint 的续跑条件

报告参数错误、版本兼容问题和归档内存溢出分别记为脚本/工具/归档失败，不能把它们写成 RTL 验证失败。保留初始失败 attempt、原脚本及原始日志。

只有同时满足以下条件，才在用户原授权内发起新的报告/准入/bitgen attempt：

1. 原作业已停止，状态明确；确认 checkpoint 完整且确由本次已完成 route 生成，记录哈希与生成日志。
2. 工具发行版/build、top/part、源文件、XDC、ROM/IP、参数、宏、编译配置和设计构建脚本与该 DCP 的输入绑定一致，S04 证据仍有效。无法追溯不能仅凭 DCP 文件存在继续签核。
3. 新脚本只打开 DCP、读取信息、生成报告、检查准入并生成 bitstream；不重新综合/布局/优化、不修改 netlist、时钟、时序例外或约束。独立登记新脚本哈希，不改旧输入清单以掩盖差异。
4. 输出写到新 attempt；旧报告和 bitstream 不覆盖。新状态引用该 DCP、原 S04/S05、续跑脚本、实际命令和日志，并逐阶段保留失败/成功状态。

Vivado 2026.1 案例中 `get_timing_paths -slack_type unconstraint` 已实际失败；不得再复制该用法或猜换成 `-unconstrained`。执行获授权时先根据当前版本帮助确认适用的约束报告接口，保留 `check_timing` 等原始输出；不能删除未约束检查来让脚本退出 0。归档已完成但脚本出错时，可以离线修订说明和清单；这不需要启动 Vivado。

设计输入或设计构建脚本改变仍须按公共契约重新验证。独立报告脚本的兼容修正只有在上述绑定完整时才不废止原 S04；这不是复用旧 RTL 测试结果的例外。

## 命令调用容易踩到的错误

- 先读脚本确认解释器和参数。案例把 `build/scripts/run_checks.py` 传给 Vivado `-source` 并使用 `--`，报 `Unknown option '--'`。Python 驱动脚本由声明的 Python 运行；Vivado `-source` 接 Tcl，脚本参数用该版本支持的 `-tclargs`。不能把另一个命令的分隔符照搬过来。
- 需要原始日志时显式指定新路径的 `-log`/`-journal`，置于 `-source` 前，不同时使用 `-nolog`/`-nojournal`。检查日志实际存在且非空；VS Code 工具输出摘录不能等同于完整原生日志。
- PowerShell 包装器同时检查 PowerShell 错误和原生进程退出码；检查输出文件可解析且完整。案例中两次外层返回 0 的输出仍含 `OutOfMemoryException`；不能只看 shell 返回 0。

## 固定范围清单

`scripts/evidence.py` 使用 Python 3.10+ 标准库，逐文件分块哈希，JSONL 逐条写入；不构造整个目录的 PowerShell FileInfo/进程对象再 `ConvertTo-Json`。比较时仍需保存文件路径/哈希索引，内存随文件数增长，不随文件内容大小增长。

在 skill 目录中运行，示例路径和选择项必须由 Agent 按真实编译依赖补齐。以下仅展示 RTL/板级资料的局部比较，不构成完整仿真清单：

```powershell
py -3.13 scripts/evidence.py manifest 'F:/任务/work_copy' --out 'F:/任务/inputs-before.jsonl' --select src/rtl --select board
# 完成本次已授权修改后，使用完全相同的选择策略。
py -3.13 scripts/evidence.py manifest 'F:/任务/work_copy' --out 'F:/任务/inputs-after.jsonl' --select src/rtl --select board
py -3.13 scripts/evidence.py compare 'F:/任务/inputs-before.jsonl' 'F:/任务/inputs-after.jsonl' --allow-change src/rtl/fsk_receiver.sv
py -3.13 scripts/evidence.py verify 'F:/任务/work_copy' 'F:/任务/inputs-after.jsonl'
```

- `--select` 必填，可多次指定文件/目录；`--exclude` 是显式、区分大小写的相对路径 glob，记录进清单。输入范围须覆盖真实测试、配置、脚本及依赖，避免选择持续变化的 results/build。完整输入快照仍可使用 `workflow.py snapshot` 保存副本和配置。
- 前后策略、目录成员均须一致；新增/删除成员阻塞，只有精确列出的已变化文件可由 `--allow-change` 接受。允许变更只是差异检查，不是仿真或实现准入。修复后再建立固定验证基线。
- 输出要求新文件，不能覆盖。建议把清单放在被扫描范围外；落入所选范围时记录自排除路径，前后自排除策略不同则不能比较。位于根内但不在所选子目录的清单不影响比较策略。
- 完成 footer 绑定记录数、字节总数和记录摘要；中断留下的无 footer 清单无效。哈希期间可见文件变化会阻塞，日志停止写入后再重做；起止校验不保证中途未修改再恢复，也不是数字签名。
- `verify` 只检查列出文件；发现新增/删除需重新生成同策略清单并 `compare`。链接/路径越界不作为可移植输入接受。

## 产物归档与可执行复现

所有临时 finalizer、清单、错误日志放在本次输出目录，不先写入原始工程再清理。停止日志写入后单独列出产物，必需原始日志不得为压缩体积而静默删除；波形按范围采集或明确说明未纳入。

```powershell
py -3.13 scripts/evidence.py manifest 'F:/任务' --out 'F:/审计/artifacts.jsonl' --select work_copy/build/repro_ureceiver_fix --select work_copy/sim/results --select run_metadata_final.json --select reproduction.md --select commands.log
py -3.13 scripts/evidence.py verify-zip 'F:/任务/run.zip' 'F:/审计/artifacts.jsonl'
```

ZIP 若含单一外层目录，增加 `--prefix 实际外层目录名`。助手核对列出成员的字节数和 SHA-256；它**不检查未列出的成员哈希，也不宣称全包 CRC 已验证**。完整发布另需检查所有 ZIP 成员 CRC、包外 ZIP SHA-256，以及所声明完整清单的成员/哈希覆盖。清单明确标注 full/selected；未被清单覆盖的文件不能算已完成哈希绑定。ZIP 哈希放包外，避免自引用。

顶层 `reproduction.md` 指向唯一当前状态 JSON 与稳定脚本，给出完整命令、cwd、环境、步骤及停止条件；实际执行记录保存扁平 `argv:string[]`、返回码、时间、原始日志及哈希。只写“运行 tools/某脚本”不够。补录命令标 `reconstructed`；未经真实执行的复现入口标 `not_run`。

复现必须明确选择：使用已核对哈希的修复后副本，或使用原版快照、核对原版哈希后应用登记的 unified diff。不得只复制原版、遗漏时序补丁。重放使用新的输出目录；历史失败脚本只留作证据，不列为推荐步骤。
