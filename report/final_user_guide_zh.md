# 系统使用指南

运行环境：Windows、Python 3.13、Vivado 2026.1。AI 模型号 `00070001`。

## 1. 文件与入口

| 文件/目录 | 用途 |
|---|---|
| `board/start_gui.cmd` | 双击启动，出错时保留窗口 |
| `board/launch_gui.ps1` | PowerShell 启动器，优先使用本目录可用虚拟环境，否则 Python 3.13 |
| `src/host/` | GUI、串口线程、协议和命令行程序 |
| `board/burst_v7/ego1_control_v3_jammer.bit` | 板端配置文件 |
| `board/burst_v7/routed.dcp` | 最终布线检查点，供 Vivado 打开审查 |
| `build/burst_v7/validation.json` | 仿真、时序、资源和哈希清单 |
| `data/release_manifest.json` | 发布包逐文件 SHA-256，含原始来源路径 |
| `report/final_demodulation_guide_zh.md` | 系统、传统/AI 原理详解 |
| `report/final_user_guide_zh.md` | 本指南 |
| `src/rtl/`、`board/constraints/`、`sim/` | 完整 RTL、约束和测试源码 |
| `src/ai/`、`data/burst_experiment/` | 最终定点模型、QAT 训练函数和 定点模型评估结果 |
| `sim/ai_golden_inputs.txt` | 最终模型黄金向量的固定输入，用于重新导出逐位参考 |

工程可由源码和脚本新建；逐文件校验见 `data/release_manifest.json`。

## 2. 首次启动

需要 Windows、Python 3.13、Tkinter 和 pyserial。通常官方 Python Windows 安装包已包含 Tkinter。GUI 不需要安装 NumPy 或 Vivado。
  
```powershell
Set-Location '<project_directory>'
py -3.13 -m pip install -r src/requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\board/launch_gui.ps1
```

也可双击 `board/start_gui.cmd`。后续正常启动无需每次安装依赖。

其他 GUI 实例和串口助手应先断开 COM8 等目标端口。GUI 在连接操作后打开串口，选择实际端口后点击 Connect。正常显示 `Connected - 115200 8N1`。

移动整个发布文件夹后，进入新位置再执行启动器即可，启动器按自身所在目录定位源码。不要只拷贝 src/host/gui.py。

## 3. FPGA 文件确认

AI 模型号为 `00070001`。右侧对照表中的 AI Model version 才是 AI 模型号；通用 STATUS 中的 model 可能为传统版本 `00030003`。收到第一份报告前，表格没有模型数据是正常现象。

在新设备复现时，请在 Vivado 2026.1 Hardware Manager 中选择当前实际设备，使用 `board/burst_v7/ego1_control_v3_jammer.bit`。项目已完成上板及仪器实测，结果见 `report/design_report.pdf` 3.3 节。

bitstream SHA-256：

```text
49b01e1e3a146384246fb4b714988e47766c0f0fb7e4ac291a6d64325f0ca761
```

核对命令：

```powershell
Get-FileHash .\board\burst_v7\ego1_control_v3_jammer.bit -Algorithm SHA256
```

## 4. 硬件连接

硬件连接依据板级说明与 XDC 核对。
既有接线来源和完整映射见 `report/board.md`、`report/ad7606_integration.md` 与 `board/constraints/board.xdc`。请按实际板卡资料核对，封装引脚名不能当作物理排针编号。

已有链路是 J2 模拟输出到 AD7606 AIN1，返回地共地；AD7606 VIO 为 3.3 V、模块供电为 +5 V。不要将 5 V 接入 FPGA IO。既有资料要求的 SPI 模式电阻、BUSY、RESET、CONVST、CS、SCLK、DOUT 接线见板级说明。

## 5. GUI 状态与结果

左侧分三个页签，800×640 窗口也不需要滚动长参数面板：

| 页签 | 控件 |
|---|---|
| FSK | 幅度、偏置、频偏、Apply FSK、Enter/Exit FSK、高斯噪声许可和强度 |
| Interference / test | 干扰启用、频率、幅度、模式、Apply jammer、目标帧数和 Start/Stop/Clear |
| DDS | 四种波形、频率、幅度、偏置和 Apply DDS |

右侧上部显示当前配置和已生效参数，中间直接并排比较传统与 AI 的 BER、错误数/位数、CRC、捕获、丢帧、频偏、AGC 和模型号。下部保留报告编号、收发异常/削顶、丢失报告、实验备注和 CSV 导出。

Diagnostics 打开当前状态和最近报告的只读快照，保留 ADC 状态、历史错误原因、复位计数等排障信息。该窗口打开后不会自动刷新，重新打开可查看新快照。

右侧 `Config` 是当前设备配置，`report config/run` 是正在显示的那份报告所属分组；修改设置后的短时间内二者可能不同，不要把旧组结果当成新条件的结果。

## 6. 干扰配置与忙状态

运行中的干扰参数由固件保护，以保证同一组统计对应一致条件。GUI 在设备忙时禁用 Apply jammer，串口线程发送前再检查状态；相同待确认命令合并处理。改变干扰时先 Stop / Exit FSK，等待当前帧与待处理动作结束，再应用参数。

Apply 成功后显示 `Settings accepted`，按右侧设备回读核对实际值。输入框是待提交参数，结果区按 report config/run 标识所属运行；DDS 当前幅度与 FSK 结果使用各自上下文。高斯噪声与单音干扰独立控制。

## 7. 推荐的双路对照实验

### 7.1 设置 FSK

1. 连接设备，先 Exit FSK；若有目标测试运行，点击 Stop 并等待停止。
2. 打开 FSK 页签：Amplitude=32、Bias=0、Offset=0，点击 Apply FSK。
3. 高斯噪声 Scale=0，点击 Apply noise。软件许可可保持勾选；强度为零时不会增加高斯噪声能量。
4. Gaussian gate 为物理许可/软件许可/帧内实际许可；即使 gate=1/1/1，Scale=0 仍无新增高斯能量。它不控制单音干扰。

### 7.2 先做无干扰基线

1. Interference / test 页签取消 Narrowband jammer enable，点击 Apply jammer。
2. 填写 Target frames=100。在 Experiment notes 记录无干扰、实际接线、电源、测量设备等。
3. 点击 Start。它启动目标帧测试，无需另按 Enter FSK；Enter FSK 用于持续发送。
4. 等待自动结束和 Final 报告，再导出一份 CSV。100 帧约 6 分 45 秒，取决于等待与恢复情况。
5. 确认 ADC errors、ADC/DAC clips、Dropped reports 均未增长，丢帧和两路 CRC/BER 在预期范围。

### 7.3 再做突发干扰

1. 等待停止，必要时 Exit FSK，使 Apply jammer 可用。
2. 勾选启用，频率 1050 Hz、幅度 80、模式 Payload burst，点击 Apply jammer。
3. 核对右侧 Interference 为 ON / Payload burst、1050 Hz、amplitude 80。
4. Target frames=100，备注本次条件，Start，等待 Final，再 Export CSV。
5. 至少重复三轮；再检查 1000、1950、2000 Hz，避免只展示对某个比特有利的一组频率。

FSK 幅度 32 时载波数字峰值约 16 DAC 码，干扰幅度 80 约为其五倍峰值；不等于实测接收端 SNR。前 96 个符号不加突发；随后每符号约一半概率在四分之一符号内加单音。

### 7.4 结果判定

两路捕获数量相近、ADC/DAC 无明显削顶和接口异常时，比较相同条件、相同分组的 errors/bits、CRC 和 lost。AI BER 低而丢帧更高时，不能只拿 BER 作结论。

右侧 Lost frames=0 但 Final incomplete 时仍应视为结果不完整。运行结束后再等最终报告，避免仅导出 Live 中间值。零误码时查看分母和 GUI 的 95% 近似上界，不能写“真实 BER=0”。

## 8. CSV、清零与重连

CSV 使用 UTF-8 BOM，便于 Excel 打开。保留时间、会话号、配置号、运行号、实时/最终标记、两支路原始计数、干扰参数、模型号和完整配置等字段。

Clear 向设备发出清统计请求，不删除电脑上的会话记录。重连继续保留当前 GUI 进程已收集记录；关闭 GUI 后内存记录不会自动保存，关闭前务必 Export CSV。

一次导出包含当前会话保留的多组报告。Experiment notes 是导出时填写的备注，会写到此次导出的所有记录，并非逐运行锁存的仪器元数据。不同条件建议分别导出并在备注中写清范围；按 config_id、run_id、final、incomplete 和 session_id 筛选。

Export 后底部显示目标路径。不要在 Excel 锁住同名 CSV 时覆盖它；换新文件名或关闭占用程序后再导出。

## 9. 常见问题

| 现象 | 操作 |
|---|---|
| Apply jammer 灰色 | Stop / Exit FSK，等待运行与 pending 清除；检查已连接并已取得状态 |
| 显示 Device busy | 常见于板上按键与 PC 同时操作；等待空闲后重试，输入不会丢 |
| 设置后仍是旧值 | 检查 Settings accepted 和设备回读；不要仅看输入框草稿 |
| AI unavailable | 等待报告、检查模型号/实际 bitstream，不将缺少数据当零误码 |
| COM8 无法打开 | 关闭旧 GUI、串口助手或其他占用程序，再连接实际端口 |
| 只有 lost 没有 bits | 优先检查捕获、信号幅度、接线与接口；网络无法修复未同步帧 |
| ADC errors 或 resets 不断增长 | Diagnostics 查看状态与计数变化，检查 BUSY/RESET/供电；历史 reason 不等于当前错误 |
| 输入幅度后无预期模拟电压 | 参数单位是数字码，不是伏特；用示波器实际测量并检查削顶 |
| 关闭软件噪声后单音仍有影响 | 两套噪声独立；取消单音 enable 并在空闲时 Apply jammer |
| 连续单音下 AI 没优势 | AI 为突发专用模型，连续干扰存在已知退化，详见原理文档 |

## 10. 开发复现

只使用 GUI 不需要下面步骤。复现 Python 模型需要额外依赖：

```powershell
py -3.13 -m pip install -r src/requirements-receiver.txt
py -3.13 build/scripts/check_gui_busy.py
py -3.13 build/scripts/check_burst_host.py
py -3.13 build/scripts/check_gui.py
py -3.13 build/scripts/check_uart_capture.py
py -3.13 build/scripts/check_serial_host.py
```

RTL 测试和新建工程使用 Vivado 2026.1：

```powershell
$env:VIVADO_BIN = 'E:/AMDDesignTools/2026.1/Vivado/bin'
py -3.13 build/scripts/run_checks.py
& "$env:VIVADO_BIN/vivado.bat" -mode batch -source build/scripts/create_project.tcl
# 工程将生成在 build/project/dds_control_v3.xpr。
```

重新实现应输出到新目录，避免覆盖交付证据：

```powershell
$env:DDS_BUILD_DIR = (Join-Path $PWD 'build/reproduce')
New-Item -ItemType Directory -Force $env:DDS_BUILD_DIR | Out-Null
& "$env:VIVADO_BIN/vivado.bat" -mode batch -log "$env:DDS_BUILD_DIR/build.log" -journal "$env:DDS_BUILD_DIR/build.jou" -source build/scripts/build_burst.tcl
```

初轮 setup 未通过时，保持 `DDS_BUILD_DIR` 指向自建目录，再运行 `build/scripts/finish_burst.tcl` 从该目录的布线检查点继续。构建、继续实现及报告脚本均拒绝覆盖交付的 `build/burst_v7` 和 `board/burst_v7`。重新实现结果必须重新检查时序、DRC 和模型权重。

最终模型训练、独立测试和黄金向量导出入口见 `report/burst_payload_v7.md`；QAT 函数位于 `src/ai/qat.py`。黄金向量直接使用已保存的 64 组输入，不依赖历史数据集。

## 11. 结果核查

RTL 日志、整机实现、模拟回环和仪器读数分别位于 `sim/results/`、`build/burst_v7/`、`data/hardware_results.json` 及 `data/hardware/`。报告 3.3 节集中给出四波形展示、12 点 DDS 读数、同次双路统计和检测器资源对照。复核结果时同时查看实验条件、Live/Final、分母、捕获/丢帧与异常计数。
