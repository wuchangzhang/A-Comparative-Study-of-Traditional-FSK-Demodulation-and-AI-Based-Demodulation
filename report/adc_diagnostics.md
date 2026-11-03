# ADC 诊断字段说明

诊断版 bitstream 在 GUI 状态栏新增一行 ADC 诊断信息，用于不借助示波器定位 AD7606 卡点。

## 显示格式

```
ADC state N(名称) | BUSY b DOUT d | reason R(原因) | resets C
```

## 字段含义

### 1. `state`（ADC 状态机当前所处状态，编码 → 名称）

| 编码 | 名称 | 含义 |
|---|---|---|
| 0 | RESET | 复位脉冲中 |
| 1 | IDLE | 空闲，等待下一次转换 |
| 2 | CONV_LOW | CONVST 拉低 |
| 3 | WAIT_HIGH | 等待 BUSY 变高（转换开始） |
| 4 | WAIT_LOW | 等待 BUSY 变低（转换完成） |
| 5 | READ_LOW | SCLK 低半周期 |
| 6 | READ_HIGH | SCLK 高半周期（读位） |
| 7 | FINISH | 完成一次采样 |

正常情况下状态会在 IDLE→CONV_LOW→WAIT_HIGH→WAIT_LOW→READ…→FINISH 之间循环，
且大部分时间停在 **IDLE**（等待 20us 采样周期）。如果状态**卡死在某个值不动**，
就是卡在了对应环节。

### 2. `BUSY` / `DOUT`（两级同步后的实时电平）

- 空闲时 BUSY 应为 **0**；转换期间 BUSY 应为 **1**。
- 如果 BUSY 一直 0 → 芯片没在转换（供电/复位/接线问题）。
- 如果 BUSY 一直 1 → 芯片卡在转换，或 BUSY 线接错/悬空读到高。

### 3. `reason`（最近一次错误的原因，锁存）

| 编码 | 含义 | 排查方向 |
|---|---|---|
| 0 | 无错误 | — |
| 1 | IDLE 时 BUSY 为高 | BUSY 线悬空/接错读到高，或芯片一直 busy |
| 2 | WAIT_HIGH 超时（BUSY 始终不高） | 拉 CONVST 后芯片没开始转换：供电/VIO/RST/接线 |
| 3 | WAIT_LOW 超时（BUSY 始终不降） | 转换不结束：芯片异常、模式电阻（R1/R2）不对 |
| 4 | FINISH 超期（事务超过采样周期） | SCLK/读取太慢或 cadence 异常，极罕见 |

### 4. `resets`（ADC 状态机复位次数，饱和计数）

- 每次发生 error 都会回 RESET 并 +1。正常工作时这个数应该**很小甚至不增长**。
- 如果 `resets` 持续快速增长，说明 ADC 在反复超时复位，硬件链路有问题。

## 典型判读

| 现象 | 结论 |
|---|---|
| reason=1，BUSY 恒 1 | BUSY 线（J5-11/B13）悬空或接错，读到高 |
| reason=2，BUSY 恒 0，resets 暴涨 | 芯片没开始转换：查 +5V、VIO=3.3V、RST、共地 |
| reason=3，BUSY 先高后不降 | 模式电阻 R1/R2 不对（SPI 应 R1=10k、R2 空），或芯片坏 |
| reason=0，state 正常循环，但 peak=0 | SPI 状态机正常但数据无摆幅：查 DOUT 线（J5-13/D14→DB7）或信号源 |
| reason=0，peak 有几千码，但 lock=0 | ADC 正常、信号已到，问题在接收机 SYNC 对齐 |

## 与接收机字段联动

- `peak`：ADC 采到的信号峰值（本次新增）。峰值接近 0 说明没采到有效摆幅。
- 结合 `peak` 和上述 `reason`/`BUSY`/`state`，可完整区分「ADC 硬件链路问题」
  与「接收机同步问题」。
