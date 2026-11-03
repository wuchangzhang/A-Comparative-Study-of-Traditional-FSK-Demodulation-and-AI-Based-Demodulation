# DDS 多波形信号源与传统/AI 双路 FSK 解调系统

平台为 EGO1 / Artix-7 `xc7a35tcsg324-1`，顶层 `ego1_control_top`，工具为 Vivado 2026.1。系统经 DAC0832 / LM324 / J2 输出模拟信号，由 AD7606 采回；共享接收前端并行比较整窗相关与定点 AI 判决。AI 模型号为 `00070001`。

## 目录与阅读入口

| 路径 | 内容 |
|---|---|
| `src/` | RTL、ROM、上位机、定点权重、训练函数及依赖 |
| `sim/` | 24 项测试台、黄金向量和逐项仿真日志 |
| `build/` | 可复现脚本、整机及检测器资源/时序/DRC 报告 |
| `board/` | XDC、GUI 启动器、配置文件和布线检查点 |
| `data/` | 仪器读数与原图、实测统计、同输入对照、参考数据和哈希 |
| `skill/` | 原子化工程 Skill、用法、适用边界与验证记录 |
| `report/` | 设计报告、协作记录、操作指南及接口说明 |

设计报告：`report/design_report.pdf`。操作指南：`report/final_user_guide_zh.md`。要求与证据对照：`report/amd_review.md`。

## 启动

Windows / Python 3.13（含 Tkinter），从工程根目录执行：

```powershell
py -3.13 -m pip install -r src/requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File board/launch_gui.ps1
```

也可双击 `board/start_gui.cmd`，选择实际串口并连接。板端配置文件为 `board/burst_v7/ego1_control_v3_jammer.bit`；Vivado Hardware Manager 下载前按 `report/board.md`、`report/ad7606_integration.md` 和 `board/constraints/board.xdc` 核对实际器件、电平与接线。

## 从源码复现

建议复制工程至新的英文路径，在副本中执行。冻结权重已随包提供，复现推理和回归直接使用这些权重；训练入口及随机种子见 `report/burst_payload_v7.md`。

```powershell
py -3.13 -m pip install -r src/requirements-receiver.txt
py -3.13 -B build/scripts/verify_submission.py --verify .
py -3.13 build/scripts/verify_host.py
py -3.13 -B -m unittest discover -s skill/amd-fpga-embedded-dev-workflow/scripts -p 'test_*.py' -v
$env:VIVADO_BIN = 'E:/AMDDesignTools/2026.1/Vivado/bin'
py -3.13 build/scripts/run_checks.py
& "$env:VIVADO_BIN/vivado.bat" -mode batch -source build/scripts/create_project.tcl
$env:DDS_BUILD_DIR = (Join-Path $PWD 'build/reproduce')
New-Item -ItemType Directory $env:DDS_BUILD_DIR | Out-Null
& "$env:VIVADO_BIN/vivado.bat" -mode batch -log "$env:DDS_BUILD_DIR/build.log" -journal "$env:DDS_BUILD_DIR/build.jou" -source build/scripts/build_burst.tcl
```

`VIVADO_BIN` 按本机 2026.1 安装位置设置。新工程为 `build/project/dds_control_v3.xpr`。需要继续实现时，在同一 `DDS_BUILD_DIR` 下运行 `build/scripts/finish_burst.tcl`，重新检查报告、时序及 DRC 后使用该次产物。模型重新训练时，按报告完成导出、黄金向量、RTL 和整机核验。

## 主要结果

24 项 RTL 回归通过。整机 100 MHz 实现：12945 LUT、10747 FF、21 DSP、35 RAMB36、9 RAMB18；WNS 0.000 ns、TNS 0、WHS +0.038 ns、THS 0。

J2 三波形 12 点实测最大绝对频差 0.80 Hz，最大相对误差 0.300%。1050 Hz 突发单音的 100 帧 Final 中，两路各捕获 100 帧、丢帧 0，传统载荷错误 4061/25600、AI 0/25600。1900 Hz 200 帧及 1050 Hz 205 帧 Live 分别留档。1020 Hz 持续单音下传统为 0/25600、AI 为 4443/25600。完整条件和统计见 `data/hardware_results.json` 与报告 3.3 节。

同输入数字回放中，移位四分之一突发的整窗/投票/剔除/AI 错误数为 1856/1040/706/436（各 18432 bit）。AI OOC 检测器使用 1038 LUT、731 FF、17 DSP，处理时间 41.47 us；100 MHz 下 WNS -0.529 ns、TNS -9.479 ns。该独立模块结果与整机实现分别列示。结论为指定突发场景的可靠性改善及其资源、延迟和时序代价。

原始结果和有限样本分母分别保存；参数码以数字单位表示。`data/release_manifest.json` 覆盖全部交付文件，`data/layout_manifest.json` 绑定工程来源和设计哈希；`data/hardware/evidence_manifest.json` 绑定测量图片和读数。

检测器对照与图表复现先安装 `build/requirements-analysis.txt`，依次执行 `build/scripts/compare_detectors.py`、`run_detector_checks.py`、Vivado `compare_detector_resources.tcl`、`summarize_detector_comparison.py`。此路径使用冻结模型，生成同输入回放、RTL 对照、OOC 报告和成本图；计算范围与模拟实测分别保存。
