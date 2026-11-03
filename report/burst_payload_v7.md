# Payload-burst demodulation experiment

## Purpose and limits

This experiment tests payload decisions under short, nonstationary interference.
The traditional full-window detector, acquisition and synchronization are unchanged.
The AI remains a 10-16-8-2 integer MLP (330 parameter words, shifts 4/5).
The weight set is specialized for bursts, model version `0x00070001`.

The experiment protects the 64-symbol preamble and 32-symbol sync word. Bursts
affect the body (frame ID, 256 payload bits and CRC). This isolates body-bit
decisions; acquisition is evaluated separately using capture and loss counts.

Each 10 ms body symbol independently has approximately 50% probability of a
2.5 ms tone burst in one of four random quarters. The xorshift source is
independent of the transmitted PRBS. The jammer phase runs continuously. No
transmitted labels or timing signals have been added to the receiver.

## Software evidence

Commands, from this project directory:

```powershell
py -3.13 build/scripts/burst_experiment.py --epochs 50 --count 2400 --seeds 3
py -3.13 build/scripts/burst_experiment.py --heldout
py -3.13 build/scripts/burst_experiment.py --frames-only
py -3.13 build/scripts/burst_experiment.py --export
py -3.13 build/scripts/export_ai_golden.py
```

Training seed 71001, validation seed 72001; QAT seed selected on validation only.
Three independent symbol test seeds 73001/74001/75001:

| Test bits | Full-window errors | AI errors | Quarter-window majority errors |
|---:|---:|---:|---:|
| 38400 | 3075 | 0 | 0 |
| 38400 | 3384 | 0 | 0 |
| 38400 | 3353 | 0 | 0 |

Held-out frequencies 1020/1100/1850/1980 Hz, seed 77001: 38400 bits,
traditional 2439 errors, AI 0, majority 0. These tests assume known symbol
boundaries and do not model analog filtering or DAC quantization.

Complete-frame Python receiver test, seed 76001: 96 attempted and 96 captured
frames, 24576 payload bits; traditional 2173 errors and AI 0. Capturing uses
the received samples, not ground-truth frame boundaries. Detailed per-cell
BER and CRC counts are in `data/burst_experiment/frames.json`.

The simple majority detector also solves this selected channel. These results
demonstrate an improvement over the existing traditional full-window baseline,
not an exclusive AI capability or superiority over all traditional algorithms.

For the measured 1020 Hz continuous-tone case, the full-window detector recorded 0/25600 payload errors and the AI 4443/25600. Channel specialization is evaluated alongside burst performance.

The final weights are in `src/ai/model.npz`; QAT functions are in `src/ai/qat.py`.
Evaluation uses the final weights when no newly trained candidate is present.
The 64 fixed inputs in `sim/ai_golden_inputs.txt` reproduce the delivered golden
vectors without a historical training or test dataset.

## FPGA/host implementation

- `sample_path.sv`: 1000-DAC-sample symbol counter, randomized 250-sample gate.
- `control_core.sv`: gates burst injection until TX bit index 96. This signal
  controls the transmitter disturbance only; it is not an RX synchronization input.
- CMD 8 retains the legacy 4-byte continuous-tone payload. A fifth byte `1`
  selects burst mode (`0` selects continuous). Invalid modes are rejected.
- Apply jammer settings only while FSK is off and no test is pending/running.
  Commands during FSK return BUSY; accepted changes advance config_id.
  Validation is registered before committing jammer values and config_id
  together on the following clock. History snapshots the old configuration
  before this commit, avoiding a long command-decode-to-report timing path.
- STATUS page 2 byte 24 and REPORT page 1 byte 36: bit 0 enable, bit 1 burst.
  Other jammer fields retain their locations. CSV adds `jam_burst`.
- GUI adds a `Continuous / Payload burst` selection and displays the actual mode.

## RTL verification and build

```powershell
$env:VIVADO_BIN = 'E:/AMDDesignTools/2026.1/Vivado/bin'
py -3.13 build/scripts/run_checks.py
py -3.13 build/scripts/check_burst_host.py
$env:DDS_BUILD_DIR = (Join-Path $PWD 'build/rebuild_v7')
New-Item -ItemType Directory -Force $env:DDS_BUILD_DIR | Out-Null
& "$env:VIVADO_BIN/vivado.bat" -mode batch -log "$env:DDS_BUILD_DIR/build.log" -journal "$env:DDS_BUILD_DIR/build.jou" -source build/scripts/build_burst.tcl
# If initial implementation fails setup timing, continue from its routed checkpoint:
& "$env:VIVADO_BIN/vivado.bat" -mode batch -log "$env:DDS_BUILD_DIR/finish.log" -journal "$env:DDS_BUILD_DIR/finish.jou" -source build/scripts/finish_burst.tcl
py -3.13 build/scripts/report_burst.py
```

`tb_burst_tx` checks random quarter coverage, protected preamble and DAC clips,
and exports actual RTL DAC codes as ideal, linearly scaled ADC samples.
`tb_burst_receiver` replays these samples into the real RTL receiver, requiring
equal capture counts and lower AI payload errors/CRC failures. This is digital
simulation, with ideal ADC scaling; it is not a board or analog acceptance test.

Executed RTL result: `traditional=30/256 CRC=1 AI=0/256 CRC=0`, both branches
captured the same frame. `tb_burst_tx` emitted 212000 ideal ADC samples, exercised
all four random slots, and reported zero DAC clips. All 24 simulation tests
passed, including the original frequency/AGC/synchronization/loss regressions.
Host checks passed: `check_burst_host.py`, `check_gui.py` (980x740 and 800x640)
and `check_uart_capture.py` (91 packets, 25 complete snapshots, 23 CSV rows).

UART test fixtures drive defined ADC diagnostic values. Response CRC and
snapshot grouping are checked alongside payload statistics.

Delivered build reports: `build/burst_v7`; the only bitstream is in `board/burst_v7`.
`validation.json` binds the successful build to its design inputs and test logs.
Release contents are listed in `data/release_manifest.json`. Rebuilds and new
reports use DDS_BUILD_DIR.

Resource accounting: separately report `u_receiver/u_ai` for the inference
engine. Both branches share `u_receiver/u_mac` feature extraction and
acquisition; the AI module alone is not the cost of a standalone receiver.

Final routed results (Vivado 2026.1, XC7A35T, 100 MHz):

| Resource | Complete system |
|---|---:|
| LUT | 12945 |
| FF | 10747 |
| RAMB36 | 35 |
| RAMB18 | 9 |
| DSP | 21 |

The AI inference module is 406 LUT, 276 FF and 1 DSP, with no block RAM.
Setup WNS is 0.000 ns, TNS 0; hold WHS is +0.038 ns, THS 0, with zero failing
endpoints. This meets constraints with extremely narrow setup margin; it is
not a claim of timing headroom. A fresh implementation must be checked again.
DRC reports no errors or critical warnings. The initial implementation stopped
at WNS -0.170 ns; `finish_burst.tcl` closed timing from the routed checkpoint.

## Board experiment

1. Program the verified bitstream in `board/burst_v7`, then restart the GUI.
2. Check the AI branch's reported model version is `00070001` (the generic
   STATUS model header may still show the traditional model).
3. Exit FSK. Set FSK amplitude 32, bias 0, offset 0, noise scale 0.
4. Set jammer frequency 1050 Hz, amplitude 80, mode `Payload burst`, enable,
   and apply while FSK is off. The carrier peak is approximately 16 DAC codes,
   so this is a 5x peak burst, not a weak continuous jammer.
5. Run the disabled-jammer baseline first, then enable the burst and run at
   least 100 frames. Wait for the final report before exporting CSV.
6. Repeat at least three independent runs; report both branches' capture/loss,
   payload BER, CRC failures, ADC/DAC clips and all settings. Do not omit failed
   captures. Test 1000/1050/1950/2000 Hz to expose asymmetry.

Both receiver branches must see the same ADC samples and captured frames.
If analog filtering spreads a 2.5 ms burst across multiple quarters, AI's
software advantage may shrink. Only real measurements can establish the final
benefit. Measured analog-loopback records are indexed in `data/hardware_results.json` and report section 3.3.2; software and RTL results retain their own sample counts.
