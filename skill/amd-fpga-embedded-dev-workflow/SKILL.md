---
name: amd-fpga-embedded-dev-workflow
description: >
  编排 AMD FPGA/嵌入式加速工程的需求计划、工程配置、RTL/HLS/AIE 分析、仿真、实现、报告、诊断、板级验收与提交归档。
  以 EGO1/XC7A35T 为 RTL 参考，同时兼容经确认的 Zynq/Versal/AI Engine 目标；工具版本和器件由实际工程确认。
  按请求选择原子步骤；只读分析或文档修改不触发开发执行。不负责模型训练、通用软件发布或未经工具验证的硬件结论。
metadata:
  version: 5.3.1
  constraint: skill-only-execution
---

# AMD Vivado AI FPGA/嵌入式开发原子 Skill 编排

## 0. 范围与优先级

本入口声明原子职责、契约及路由。Agent 负责依据真实输入推理和选择步骤，不强制运行完整流水线。用户本次授权范围优先；只修改 Skill 文档时，不运行仿真、综合、实现、下载、工具探测或测量。

本队参赛配置为**自主选题初级组**；EGO1 / XC7A35T 仍是默认 RTL 参考，板级参数见 [profiles/ego1.md](profiles/ego1.md)。若目标是 Zynq/MPSoC、Versal、AI Engine、Vitis HLS 或 Vitis AI，必须先提供并核对 part、平台、工具版本和运行时边界；不把 EGO1 约束套用于其他器件。通用目标的工具版本不得凭猜测切换，必须与工程声明及实际探测结果一致；EGO1 / XC7A35T 配置例外，固定使用 Vivado 2026.1，禁止自动切换其他发行版。

AMD Vivado AI 扩展能力按以下边界接入：Vivado RTL lint/elaboration、IP/Block Design 配置、RTL 仿真、时序方法学、Vitis HLS、AI Engine/Versal 以及 ILA/VIO 硬件调试均可路由到原子步骤；Vitis AI 模型量化/编译只记录为外部依赖和证据，不由本 skill 猜测模型效果。

`skill-only-execution` 表示开发动作必须落到下表相应 atom 并遵守契约，不代表本清单已经提供可调用的原生工具。未安装的工具、占位 MCP 端点和未验证脚本不得宣称可用。

所有步骤共享 [runtime-contract.md](runtime-contract.md)。调用前必须读对应 atom，不得凭记忆猜参数。`knowledge/` 指本技能包的经验目录，不是用户个人记忆。

## 0.1 使用条件与使用说明

### 自然语言入口

用户只需先给出“要做什么、工程或资料路径、做到哪一步停止”。不要求用户手填 atom、JSON、top 或源文件清单。Agent 先只读检查当前文件，整理有来源的配置，再按本次范围做 preflight。可运行 `scripts/workflow.py inventory <工程路径>` 获得候选文件；候选列表不等于完整依赖，也不能自动确定 top 或器件。

- 只读审阅、报告分析：直接读取相关文件，不要求先制定完整开发方案或提供无关板级资料。
- 小范围修改：用简短说明列出目标、拟改文件、验收方法与未知项。用户已有指令明确覆盖这些内容时，视为该范围已确认，不重复索取批准；新增范围或高影响歧义仍须确认。
- 新工程或接口/架构改动：先 S02，确认方案后再执行。缺少源码不妨碍需求规划；从零编写代码前仍须明确规格及适用的平台依据。
- 已有工程：从当前源码、工程配置、约束和构建脚本提取字段，附路径和来源；不要求用户重复抄写已核对的信息。冲突或无法确认的关键项集中成一份清单询问，保存已确认项，补充后只重新核对受影响内容。
- 仿真等纯数字任务不索取与本次验证无关的接线、仪器设置。修改板级接口或进行板级操作时，硬件资料门槛仍适用。

具体提示词、输入规格和离线辅助命令见 [使用入口与自动化](references/usage.md)。这些脚本负责文件与命令留证，不代替 atom 的工程判断或验收。时序修复、checkpoint 续跑或大目录归档时，另读 [修复、续跑与流式留证](references/timing-recovery.md)。

独立复现先按 [收包与工具预检](references/receiving.md) 检查实际收到的输入，再进入工程/工具检查。可用 `scripts/receive_check.py <目录或ZIP>`：空目录、只有 skill、只有预检结果或只有补充包时，返回 `blocked/2`，集中要求完整首次归档或正确路径，停止该复现链；不为此继续探测 MCP、启动 Vivado 或重复复制相同 skill。不得从 skill 的历史验证文件推断工程已收到。收包通过只表示候选结构存在，仍需核对哈希、依赖、配置和当前状态。

本 skill 只能在输入完整且来源可追溯时进入执行 atom。使用顺序如下：

1. 用户先提供任务目标、功能边界、现有工程状态和验收目标；S02 据此生成详细技术方案、执行路线和验收矩阵。
2. 用户确认方案后，再提供或确认工程路径、top、完整 part/board、源文件清单、XDC/平台文件、时钟复位、工具版本及测试范围。已有明确授权的小任务按上文处理；未经确认的新增方案不得进入 S01、S03-S05、S09 或 S11-S14。字段由 Agent 从当前资料整理，用户负责补充缺失事实或解决冲突。
3. 涉及板卡、器件、接口、引脚或外设时，还须提供对应原始硬件资料，至少包括适用项：板卡型号与 revision、器件手册、板卡用户手册、原理图、当前 XDC/pin map、连接器映射、电压与 I/O standard、时钟/复位、ADC/DAC/存储器/PS/NoC/AIE 接口资料、接线图、仪器及测量设置。
4. HLS/AIE/PS/Vitis 任务另须提供适用的平台 XSA/PFM、component/top/kernel、运行时目标、配置文件、测试台或 golden reference，以及 Vivado/Vitis/Vitis HLS/Vitis AI 的确切版本。
5. Agent 先执行公共 preflight。任何必需项缺失时，列出缺失项及具体问题；可继续已授权且不依赖该项的只读分析，不进入被阻塞的执行步骤。用户补齐且核对通过后，才可重新 preflight 并进入下一步。

不允许用历史工程、默认 EGO1 配置、文件名、截图、模型记忆或已有 bitstream 替代缺失输入。只读报告解析可以不要求与其无关的板级资料，但仍必须具备完成该次解析所需的报告、来源上下文和验收口径。

### 硬件资料查询规则

涉及硬件事实时按固定顺序取证：

1. 先探测本会话实际可用的 AMD Vivado AI / Vivado extension MCP 能力与工程上下文。
2. 优先通过该 MCP 查询或读取器件手册、板卡手册、原理图、XDC/pin mapping、IP、PS、NoC、AIE 及当前工程信息，并记录查询对象、来源和结果。
3. MCP 不可用、不支持目标操作、查询失败或没有对应资料时，禁止自行联网搜索，也禁止凭通用知识或记忆补全。
4. Agent 必须明确告知缺少哪份原始资料、需要用户以文件/路径/原文何种方式提供，以及补齐后的恢复条件。
5. 在资料提供并核对前，相关硬件 atom 返回 `status=blocked`、`exit_code=2`；不得创建异步作业、修改工程、生成 bitstream/PDI、连接或下载硬件、驱动 VIO、执行测量。

## 1. 原子清单

下表列出主要字段；完整类型、输出和行为以 atom 与公共契约为准。

| ID | Skill | 职责 | 主要输入 | 主要输出 | 默认执行时限 |
| --- | --- | --- | --- | --- | --- |
| S01 | project-init | 创建或复用工程、加源、挂约束 | approved_plan、mode、part、top、xdc、sources、tool_adapter | project_path、files、input_manifest | 120s |
| S02 | plan-gen | 明确范围、技术路线及验收矩阵 | requirements | plan_path、tech_route_path、acceptance_path | 30s |
| S03 | code-gen | 小范围修改 RTL/XDC/tb/host | module_spec、write_allowlist | written_files、snapshot_path、diff_path | 60s |
| S04 | simulate | 编译、展开、自检仿真 | testbenches、sim_mode、input_manifest | passed、failed、simulation_evidence | 异步，3600s |
| S05 | synth-impl | 综合、实现、生成 bitstream | project_path、part、input_manifest、simulation_evidence | bitstream_path、timing、utilization | 异步，7200s |
| S06 | report-read | 结构化解析与评估报告 | report_paths | timing、utilization、findings | 30s |
| S07 | diagnose | 分类、取证、选择修复位置 | logs 或 report_paths 或 evidence_paths | issue_class、candidates、repair_target | 60s |
| S08 | asset-sink | 追加有来源的经验和脚本 | entry 或 script | written_path、validation_status | 30s |
| S09 | board-verify | 下载、数字验证、模拟实测 | bitstream_manifest、board_profile、schematic、pin_mapping、wiring_plan、test_plan | programming、measurements、board_evidence | 异步，1800s |
| S10 | release-pack | 证据审计、离线打包、复现归档 | release_spec、evidence_paths | package_path、manifest_path、missing_items | 120s；重建另走 S04/S05 |
| S11 | rtl-quality | RTL lint、elaboration 与时序方法学检查 | project_or_sources、reports、tool_adapter | quality_report、findings、repair_target | 180s |
| S12 | hls-accelerator | Vitis HLS 的 csim/csynth/cosim/impl 与 QoR 证据 | hls_component、top_function、part/platform、testbench、golden_reference | hls_evidence、reports、status | 异步，7200s |
| S13 | aie-versal | AI Engine/Versal 设计边界、编译/仿真/PDI 路由 | platform、xsa、part、aie_sources、runtime_target | aie_evidence、pdi_manifest、open_items | 异步，7200s |
| S14 | hw-debug | ILA/VIO 发现、触发、采集与板级证据 | bitstream_manifest、debug_hub_manifest、debug_plan、hw_target | capture_paths、debug_findings、status | 异步，1800s |

契约：[S01](atoms/s01.md)、[S02](atoms/s02.md)、[S03](atoms/s03.md)、[S04](atoms/s04.md)、[S05](atoms/s05.md)、[S06](atoms/s06.md)、[S07](atoms/s07.md)、[S08](atoms/s08.md)、[S09](atoms/s09.md)、[S10](atoms/s10.md)、[S11](atoms/s11.md)、[S12](atoms/s12.md)、[S13](atoms/s13.md)、[S14](atoms/s14.md)。

## 2. 按任务选择入口

```text
新项目：    S02 → S01 → 按需 S03 → S04 → S05 → S06
已有工程：  核对输入与验收范围 → 按需 S01/S03/S11 → S04 → S05 → S06
只读分析：  S06 / S07 → 输出证据与建议
RTL 质量：  S11 → 按需 S03 → S04
HLS 加速器：S02 → S12 → S06 → 按需 S05/S09
Versal/AIE：S02 → S01/S13 → S12 或 S04 → S05/S06 → S09/S14
板级验收：  核对 S05/S06 对应产物与准入结果 → S09
经验提炼：  S08
提交归档：  S10（缺少证据时列缺失项，不隐式启动构建）
完整交付：  开发阶段 → S09/S14 → S08（有经验时）→ S10
```

- 不重复生成已有且仍有效的计划、工程或代码；已有工程先核对真实 top、part、XDC、源文件集和复位。
- 禁止跳过仿真直接综合。S04 必须以 `exit_code=0` 完成，证据与 S05 当前完整输入快照一致；旧版本 PASS 不适用于新输入。
- 先验证最小模块即可进入对应实现和上板阶段，不必等待完整 DDS/FSK 系统完成。
- 仅 `exit_code=4` 允许 `S07 → 修复 → 回归`。S07 判定 RTL/tb/XDC 修改走 S03，工程组织修复走 S01；接线或仪器问题转 S09 的人工处理事项。
- `exit_code=2/3/5/6` 终止当前执行链，输出原因与恢复条件，不自动诊断改码。用户之后补齐条件可发起新执行。
- 每次任务最多 3 轮自动修复；相同错误连续出现 2 次且无新证据时提前停止。不得降低 DRC、放宽验收标准或修改黄金参考来掩盖失败。
- 修复后重新运行受影响验证；影响 RTL、参数、约束、ROM/IP、编译配置或设计构建脚本时，S04 旧准入证据失效。仅修改独立的报告/准入/bitgen 续跑脚本时，按 [续跑条件](references/timing-recovery.md) 核对原设计输入、仿真和 checkpoint 绑定，不能借此放行修改后的 RTL。

## 3. 工具适配与版本

仅在本次输入审查允许进入工具阶段，或用户单独要求环境诊断时进行工具探测。版本横幅解析不区分 `vivado` 大小写；完整且一致的发行版及 SW/IP/SharedData Build 可用于身份记录，`-version` 返回 1 时保留异常，但不据此反复重试或判成 RTL 失败。使用 `workflow.py parse-version` 可离线解析原始日志；其成功不证明启动或综合许可。需要启动探测时最多一次明确的无工程、无 GUI batch 查询；出现环境错误保留记录并按恢复条件处理，不能自动提权、关沙箱或换版本。具体记录要求见 [收包与工具预检](references/receiving.md)。

优先级：① 已配置且实际探测通过的 VS Code AMD Vivado AI 扩展/MCP 能力；② 与工程版本一致的 Vivado/Vitis/Vitis HLS 批处理工具。扩展技能（例如 vivado-rtl-lint、vivado-simulate-rtl、vivado-ip-configurator、hls-run-flow、hw-ila-debug）是能力路由提示，不是本机工具存在的证明。

```json
{
  "preferred": null,
  "fallback": {
    "vivado_bat": null,
    "mode": "batch",
    "script_path": null
  },
  "version_check": {
    "required_release": null,
    "allow_other_releases": false,
    "args": ["-version"]
  }
}
```

`null` 表示尚未配置，禁止作为真实工具名或路径执行。配置由实际探测结果填写，不猜测 MCP server/tool 名。MCP 探测须包含工具签名、目标操作、工程上下文及任务状态查询能力。该示例是运行时待填配置，不表示技能包附带可执行适配器。

执行 S01、S04、S05、S09、S11、S12、S13 或 S14 的工具操作前，检查将实际使用的 Vivado/Vitis/Vitis HLS 版本；版本必须满足项目声明，记录完整版本及补丁/build。无法确认版本、平台或目标器件返回 3；不自动安装、迁移或替换工具。

每次进入 S04/S05/S11/S12/S13/S14 先探测 MCP 对应操作。未启动任务且 MCP 不可用或不支持时才走同版本批处理。已启动任务后连接中断，先查询原 `job_id`；状态不明返回 6，不重复启动构建。XSIM、HLS csim/cosim、AIE 仿真和 Vitis 编译均须记录实际命令/配置和原始日志，不假设所有流程只需一条 batch 命令。

批处理回退只适用于已具备完整工程输入后的开发工具操作，不适用于补找硬件资料。硬件资料查询失败时必须按 §0.1 请求用户提供，不能以批处理工具、普通网页搜索或模型记忆代替。

## 4. 证据与权限

公共隔离、退出码、异步状态、快照、日志格式和来源绑定见 [runtime-contract.md](runtime-contract.md)。

必须分别报告：源码审阅、lint/elaboration、RTL/HLS/AIE 仿真、综合、实现时序、bitstream/PDI 生成、下载、ILA/VIO 数字调试、数字验证、J2 模拟实测、外部 ADC 回环及模型推理实测。任何阶段成功都不能替代后续阶段；HLS/AIE 的 QoR 不能直接等同于板级吞吐或 BER。

S09 不具备硬件或仪器条件时返回阻塞及人工步骤。S10 不因存在 bitstream 或截图就宣告整机验收通过。未经实测的 AD7606、AI 解调和 BER 均不得标为已完成。

## 5. 经验来源与验证

工程接收、时序修复和归档过程形成以下可复用规则：先确认收到完整工程，再探测工具；以同范围输入哈希绑定仿真与实现；解释最终 checkpoint 的时序、约束和 DRC；报告脚本异常时按输入与检查点来源进行受限续跑；以流式 JSONL 保存逐文件证据，核对目录及 ZIP 成员。

三个标准库助手分别承担任务留证、收包核对和流式清单核验。使用方式见 [使用入口与自动化](references/usage.md)，续跑判断见 [修复、续跑与流式留证](references/timing-recovery.md)。离线回归、项目文件核验和可执行复查命令见外层 `validation/validation.md`。验证范围以对应日志和输入哈希为准；工程仿真、实现与实测分别使用各自原始证据。
