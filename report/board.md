# 板级来源与验收边界

核对依据：DDS 开发包 `EGo1-开发包v1.61/.../EGo1-引脚约束文件/EGo1.xdc`、`EGo1-电路图/EGO1电路图.pdf`，以及工程 XDC。
原理图文本提取副本为本目录 `schematic_source.txt`；板卡与开发包器件对应。

| 本版端口 | FPGA 引脚 | 用途与依据 |
|---|---|---|
| sys_clk_in / sys_rst_n | P17 / P15 | 基线 100 MHz 时钟、低有效复位 |
| btn_pin[0..4] | R11,R17,R15,V1,U4 | KEY1..KEY5，默认低、按下高；开发包与原版约束 |
| uart_rx / uart_tx | N5 / T4 | 开发包 PC_Uart_rxd / PC_Uart_txd，115200 8N1 |
| noise_switch | P5 | 开发包 sw_pin[0]；原理图标 SW6，不能称为原理图 SW0 |
| knob_p / knob_n | C12 / B12 | XADC VAUX1P/N，非专用 VP/VN J10/K9 |
| fsk_bit_test_pin | B16 | 保留 J5 第 1 脚 TX bit 测试占用 |
| demod_bit_test_pin | A15 | 保留 J5 第 3 脚占用，用途为 TX frame_active，不是解调结果 |

DAC、LED 和数码管使用工程约束，完整映射见 `board/constraints/board.xdc`。
J5 第 33/34 脚为 GND，第 35/36 脚为 +3.3 V。AD7606 使用 J5-5/7/9/11/13/15，完整接线、模式电阻与高有效 RESET 见 `ad7606_integration.md`。该分配依据本地官方原理图第 6 页，不能把封装管脚当排针编号。

原理图第 7 页 W1 为 10 kΩ 电位器，跨 +1.0 V 与 GND，滑动端经 R110 1 kΩ 输出 VOL_IN；第 3 页 VOL_IN 接 C12（AD1P），B12 为配对 AD1N。
软件配置为 VAUX1 单极性、连续序列、ADCCLK 25 MHz；INIT_41 SEQ=0010，INIT_49 bit1 选 VAUX1。
I/O 的 LVCMOS33 属性沿用开发包以匹配 Bank 3.3 V；XADC 模拟输入仍需满足 0..1 V 及共模范围，这不是 3.3 V 模拟量输入。
旋钮电气检查记录应包含两端、滑动端和负端电压、B12 接地与 C12 实际范围，并与原始码对应；不外加未经确认电压。旋钮功能的实物展示见 `design_report.pdf` 3.3 节。

上板 UART 配置及双路统计展示见 `design_report.pdf`。复现时选择板卡对应 USB-UART 设备；JTAG USB 不等于可用串口。外接 TTL UART 时使用 3.3 V 并共地，不接 5 V。
噪声拨码 P5 的物理丝印和高低电平必须实板核对。

LED0..1 为 DDS 波形（00 正弦、01 方波、10 三角、11 锯齿），LED2 为 DDS pending，LED3..4 为旋钮模式，LED5 为接管，LED6 为 FSK，LED7 为实际帧内噪声许可，LED8 为帧内，LED9 为目标测试运行，LED10/11/12 为传统可用/AI可用/接收锁定，LED13..15 为零。AI 可用由真实 MLP 模块输出。可用标记表示 RTL 分支存在，不代替 ADC 电气或 BER 验收。
LED7 显示物理和软件许可的帧内逻辑与；强度为零时即使许可打开也没有新增噪声能量，可从 UART noise_scale 核实。
偏置显示使用 bias+128 的无符号码；普通状态显示已生效频率，FSK 显示帧序号低四位。

DAC、LED、数码管、UART 和测试口没有与 P17 同步的外部接收时钟，因此约束直接限定寄存器到引脚数据路径不超过 10 ns，而不假设虚构的 100 MHz 外部捕获沿。
这不是 J2 校准或 DAC 电气实测证明；DAC0832 驱动仍使用基线 120/100/10/100 周期时序。
异步数字输入均双触发器同步；入口复位异步置位、同步释放，经 BUFG 分发。新增主要 RTL 使用同步复位，保留基线相位、按键与 DAC 模块的异步复位。
仅切断异步输入到同步器的路径，不关闭内部时序或 DRC。BRAM 地址相关复位警告保留；复位清除样本有效标记，恢复后等待流水线产生新样本。板级连接、仪器输出及双路统计证据见 `report/design_report.pdf` 3.3 节和 `data/hardware_results.json`。

板级复查采用以下顺序：UART PING/STATUS、旋钮原始码与范围、五键、三种旋钮接管、DDS 幅值/偏置/J2 码值校准、FSK 帧持续与间隔、噪声物理总许可、削顶计数、测试目标停止与恢复。对应原始图片、测量表和统计索引位于 `data/hardware/`。
每次记录 bitstream SHA-256、接线、供电、仪器、实际范围、日期和操作者；完成前不得把 RTL 仿真报告作为下载或模拟验收证据。
