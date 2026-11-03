# AD7606 SPI 与最终双路 FSK 接收机

工程：`<project_directory>`。协议为 v2；RTL/传统接收器版本 `0x00030003`，AI 模型号 `0x00070001`。两路共享采样、同步和相关器，独立判决、CRC 与 BER 统计。四波形、五键、XADC 旋钮、噪声开关、DAC、FSK 发送及上位机接口见最终使用指南。

## 接线表

依据 `0-EGo1资料文档-v1.1/EGo1-电路图/EGO1电路图.pdf` 第 3、6 页、官方 `EGo1.xdc`，以及HW-AD7606-F4 / D029-1 正反面照片。J5 是 EGO1 的 2x18 扩展排针；按板上 pin-1 标记定位，不根据照片观看方向猜左右。封装 A13 等不是排针编号。

| EGO1 实际位置 | 官方 exp_io / 封装 | AD7606 照片丝印 | 方向 |
|---|---|---|---|
| J5-5 | exp_io[2] / A13   | CVA、CVB 并接 | FPGA 输出 CONVST |
| J5-7 | exp_io[3] / B18 | RD | FPGA 输出 RD/SCLK |
| J5-9 | exp_io[4] / F13 | CS | FPGA 输出，低有效 |
| J5-11 | exp_io[5] / B13 | BUSY | FPGA 输入 |
| J5-13 | exp_io[6] / D14 | DB7 | FPGA 输入 DOUTA |
| J5-15 | exp_io[7] / B11 | RST | FPGA 输出，高有效 |
| J5-35 或 J5-36 | +3.3 V | VIO | 数字接口电源 |
| J5-33 或 J5-34 | GND | GND | 共地 |
| 板上 5V0 电源测试点，先测量确认 | +5 V，原理图第 10 页 | +5V | 模块供电；J5 没有 +5 V |
| J2 的模拟信号端 | DAC/LM324 输出 | CN2 的 V1 | AIN1 信号 |
| J2 GND | 模拟地 | CN2 的 V1G | AIN1 返回地 |

也可用稳压外部 +5 V 给模块供电并与 EGO1 共地。不要把两个独立电源的 +5 V 输出直接并联。先确认 VIO=3.3 V 和共地，再连 BUSY/DB7。

保留调试输出：J5-1 / B16 是 TX bit；J5-3 / A15 是 TX frame-active。旧 BOARD.md 中 A15=J5-2 是误记，已按原理图修正。它们不参与接收同步。

模块模拟排针上每通道是 Vn/VnG 一对；只把 J2 信号接 V1，不能接 CN1 的数字 DB 引脚。AIN2..AIN8 的 Vn 接对应 VnG/AGND，依据 AD7606 英文手册第 26 页，未用模拟输入接 AGND。

## 模块模式

本地 `AD7606模块接口简要说明.txt` 用 GBK 编码。原文明确：SPI 模式 R1 贴 10 kΩ，R2 悬空不贴；并口模式相反。不是 R2 短接。照片不能替代电阻和通断检查，接线前核对实物。

模块硬件检查记录为 R1 空焊、R2 标记 `103`（10 kΩ），并已完成改焊后使用 SPI。采用本工程时，R2 的 10 kΩ 电阻已移装到 R1，R2 留空；焊盘检查和接线均已完成。DB15 接地不能替代 R1/R2 模式配置。最终版的板级连接、仪器记录和双路统计已归档于 `data/hardware/`，索引见 `report/hardware_evidence.md` 与 `data/hardware_results.json`。

| 模块丝印 | 连接 |
|---|---|
| RAGE | GND，选择 ±5 V；照片拼写就是 RAGE |
| OS2、OS1、OS0 | 均接 GND，OS=000 |
| DB15 | GND，串行接口选择 |
| DB8 / DOUTB | 不接，未使用的串行输出不能短接到地 |
| DB0..DB6、DB9..DB14 | 不接，按模块说明可处理未使用数字输入 |
| FRST | 不接 |
| RST | 接 J5-15；虽然顶层历史端口叫 adc_rst_n，物理 RESET 高有效 |

输入满量程 ±5 V 不代表 J2 已校准。接线前用示波器确认 J2 峰值留有余量，不能以 ±16.5 V 输入保护耐受值当作正常量程，也不能向 FPGA 数字 IO 输入 5 V。

## 驱动与时序

`ad7606_spi_rx.sv` 以 100 MHz 时钟使能产生 50 kSPS CONVST 和 10 MHz SCLK。RESET 高脉冲 100 ns；CONVST 低脉冲 100 ns；转换在其上升沿开始。等待 BUSY 先高后低，再拉低 CS，读取完整 8x16=128 位，仅导出第一个有符号二补码 AIN1。

SCLK 空闲高。CS 下降使 MSB 有效，AD7606 在后续上升沿更新 DOUT；内部在下一上升沿前取得经两级同步的上一位，留出一整周期的访问/同步时间，最后一个完整时钟后保留半周期再释放 CS。最长转换约 4.15 us，加 12.8 us 串行读取及控制裕量，正常落在 20 us 周期内。

`sample_valid` 只在完整且未超期的读数后脉冲；`sample_index` 只计有效样本。BUSY 缺失、卡死或事务超期触发一次异常，重新复位 ADC 并重新建立节拍。近满量程阈值为正负 0x7A00，`adc_clip` 按有效样本计数。复位/异常不能重复导出旧样本。

## 双路接收链

当前接收前端、500 点整窗传统相关判决、10 维能量特征及 10→16→8→2 定点 MLP 以 `final_demodulation_guide_zh.md` 和当前 RTL 为准。两路使用同一采样流与同步结果，独立判决并统计 CRC、捕获、丢帧和载荷 errors/bits。

TX frame_end 仅用于统计评价，不控制接收缓存窗口、频偏估计或符号判决。CRC 错误但已对齐的帧仍计入 BER；完全未捕获的帧计为 lost，不进入 BER 分母。模拟采样异常或最终报告 incomplete 时，不能用零误码代替完整验收。

## 重建与验证

使用 Python 3.13 与 Vivado 2026.1。ROM 已随包提供；`build/scripts/generate_receiver_tables.py` 可重建接收 ROM，`build/scripts/run_checks.py` 运行最终 24 项 RTL 测试。默认工具目录为 `E:\AMDDesignTools\2026.1\Vivado\bin`，可用 VIVADO_BIN 指定同版本路径。

新增 `tb_ad7606_spi` 检查真实 100 MHz/50 kSPS、完整 128 时钟、有符号码、最坏访问延迟、削顶和超时恢复。`tb_fsk_receiver` 从独立正弦采样流验证频偏、任意采样起点、幅度/DC、噪声、±100 ppm、同步容错/拒绝、CRC、真实 BER、漏捕与 statistics 对接。测试的约 18 dB 是采样 SNR，噪声为确定性 12 均匀分布和近似高斯，不能标成 Eb/N0 或硬件带内 SNR。

`py -3.13 build/scripts/check_receiver_reference.py` 另跑独立浮点参考（需 numpy），每个频偏 100 帧，使用解析正余弦而非 RTL ROM，验证随机相位/起点/幅度/DC 下的算法；该结果不能替代逐位定点等价或硬件证据。

交付的构建记录位于 `build/burst_v7`，bitstream 与最终布线检查点位于 `board/burst_v7`。重新构建使用最终使用指南中的独立 `DDS_BUILD_DIR`、单线程及保留层级设置。具体时序、资源和 bitstream 结论见构建记录及 `final_demodulation_guide_zh.md`；项目上板与仪器实测结果见 `design_report.pdf` 3.3 节和 `data/hardware_results.json`。

上板顺序：电源/VIO -> 静态电压与 ADC 二补码 -> 1/2 kHz 正弦 -> J2/V1 环路 -> UART PING/STATUS -> 无噪声 FSK -> 频偏/噪声扫描。静态 ADC 码可在 Vivado ILA/仿真探针观察 u_adc.adc_sample_data、adc_sample_valid、sample_index；当前 UART 不新增原始波形流命令。每步记录 bitstream 哈希、波形、电源与实际接线后再做 BER 长时测量。
