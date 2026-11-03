# AMD FPGA 工程开发与验证 Skill

入口：[SKILL.md](amd-fpga-embedded-dev-workflow/SKILL.md)。技能标识为 `amd-fpga-embedded-dev-workflow`，元数据版本为 5.3.1。

## 适用范围

面向已有 FPGA 工程的只读审阅、局部修复、仿真与实现组织、板级诊断和提交核查。EGO1 / XC7A35T 参考配置使用 Vivado 2026.1。21 个 Markdown 文件构成入口、公共契约、14 个原子职责、平台配置及专题参考；三个标准库助手支持候选扫描、目录/ZIP 收包、版本日志解析、输入快照、显式命令留证和流式哈希清单。其他 AMD 平台由实际 part、平台文件和工具版本决定适用步骤。

## 使用方法

将 `amd-fpga-embedded-dev-workflow/` 安装到支持 Skill 的 Agent 技能目录，或让 Agent 阅读入口。用自然语言提供目标、工程路径与停止边界，例如：

> 使用这个 Skill，审阅当前工程的 FSK 接收链及实现时序，列出有文件依据的问题；只读分析，到报告结论为止。

> 使用这个 Skill，对已定位的时序路径做局部修复，保存输入快照并运行受影响回归；时序与 DRC 检查通过后生成配置文件，到此停止。

Agent 从真实文件整理 top、part、XDC、测试和验收条件，再选择相关原子。只读或文档任务采用对应入口。完整说明见 [usage.md](amd-fpga-embedded-dev-workflow/references/usage.md)、[receiving.md](amd-fpga-embedded-dev-workflow/references/receiving.md) 和 [timing-recovery.md](amd-fpga-embedded-dev-workflow/references/timing-recovery.md)。

从工程根目录运行离线回归：

```powershell
py -3.13 -B -m unittest discover -s skill/amd-fpga-embedded-dev-workflow/scripts -p 'test_*.py' -v
py -3.13 -B skill/amd-fpga-embedded-dev-workflow/scripts/receive_check.py .
py -3.13 -B skill/amd-fpga-embedded-dev-workflow/scripts/workflow.py inventory .
```

## 经验来源与效果

| 工程观察 | 提炼规则 | 验证与作用 |
|---|---|---|
| 工程输入与技能、预检输出混放 | 收包先确认源码/约束/脚本类别 | 目录与 ZIP 分类、空输入和路径异常回归 |
| 工具横幅与进程退出状态含义不同 | 保存原始日志，分开判定版本身份与执行状态 | 大小写、编码、冲突横幅和退出码回归 |
| 仿真通过后输入仍可能变化 | 同范围输入清单绑定仿真、实现与产物 | 源文件、配置、目录成员、快照变更检测 |
| 报告阶段异常发生在布局布线完成之后 | 核对 checkpoint 与输入，受限续跑并重新检查准入 | 保存解释器、argv、cwd、返回码及原始报告 |
| 大型归档清单序列化占用内存 | 逐条 JSONL、分块哈希、完成 footer | 中断、篡改、选择范围和 ZIP 成员回归 |

79 项行为回归通过；结构与本地链接检查、当前工程输入及 bitstream/DCP 的哈希核验见 [validation/validation.md](validation/validation.md)。测试结果支持所列辅助功能，工程完整性的判断同时依赖实际源清单、仿真/实现报告和板级实测。

## 失效条件

输入缺失或冲突、目标器件/工具版本不符、板级资料不适用、命令超时或验收失败时，按公共契约返回状态、依据和恢复条件。板卡替换需重新提供 XDC、电平、接口与测量设置。脚本是证据助手，实际 Vivado/MCP/仪器由执行环境提供；模型训练由工程训练脚本完成。通用 HLS、PS、AIE 步骤按目标工程选择，作品的实测结论对应 EGO1 RTL 平台。
