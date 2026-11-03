# Control protocol v2

All integers are big endian. Envelope: `55 AA CMD LEN SEQ[2] PAYLOAD CRC[2]`.
CRC-16/CCITT-FALSE covers CMD through PAYLOAD. LEN <= 64. RX inter-byte
timeout is 100 ms. Request payloads follow specification section 11.4.
Noise scale is an unsigned Q8.8 coefficient for the unit-sigma discrete Gaussian
LUT, in DAC codes before clipping. Noise uses symmetric nearest rounding (ties
away from zero). Actual integer-code sigma differs at low scale: scale=1 rounds
every LUT entry to zero, rather than producing fractional DAC codes. It is not SNR.
DDS frequency accepts integer Hz 100..2000 (knob uses 10 Hz steps).
Wave 0/1/2/3 = sine/square/triangle/sawtooth. Values >=4 are rejected.
Sawtooth support is identified by RTL version 0x00030001; older 0x00030000 rejects wave=3.
Unsupported FSK profiles are rejected.
Signal amplitude/bias combinations that clip even without noise are rejected.

| Request CMD (hex) | LEN | Payload in wire order |
|---|---|---|
| 01 SET_DDS | 8 | frequency:u32, wave:u8, amplitude:u8, bias:i16 |
| 02 SET_FSK | 15 | f0:u32=1000, f1:u32=2000, bitrate:u16=100, amplitude:u8, bias:i16, offset:i16 |
| 03 RUN | 1 | enable:u8 (0/1) |
| 04 NOISE | 3 | software_enable:u8 (0/1), scale:u16 |
| 05 GET_STATUS | 0 | empty |
| 06 PING | 0 | empty |
| 07 TEST | 1 or 5 | action:u8 (0 stop, 1 start, 2 clear); start additionally target_frames:u32 |

FSK offset is -100..100 Hz; amplitude is 0..255 and bias is -128..127.
ACK pending=1 for setting commands means accepted for boundary handling, not
proof that active has changed; compare requested/active and pending in STATUS.
GET_STATUS ACK pending=0. PING replies with PONG directly.

| Response CMD | Payload |
|---|---|
| 80 ACK | request CMD:u8, pending:u8, config_id:u32 |
| 81 NACK | request CMD:u8, error:u8 |
| 82 STATUS | header + one 48-byte status page |
| 83 REPORT | header + one 48-byte report page |
| 84 PONG | protocol:u8=2, RTL version:u32=0x00030003 |

Error codes: 1 BAD_CRC, 2 BAD_LENGTH, 3 OUT_OF_RANGE,
4 UNSUPPORTED_PROFILE, 5 BUSY, 6 SEQ_CONFLICT, 7 UNKNOWN_CMD.
Unknown CMD is never executed. SEQ is echoed for direct replies.
PING establishes a session, clears the 8-entry retry cache and unsent old STATUS
pages (an already accepted UART page finishes), changes no settings,
and must be followed by STATUS. Identical cached requests replay their ACK/NACK;
same SEQ with different CMD/LEN/payload returns SEQ_CONFLICT. Host uses one
outstanding request and waits for the complete STATUS snapshot before the next.
Telemetry is outside retry caching. REPORT SEQ is zero; every STATUS page echoes
the originating GET_STATUS SEQ. A successful GET_STATUS requires its ACK and a
complete version-2 snapshot with that same SEQ. Old in-flight snapshots cannot
complete a new request. Host live connections require PONG protocol=2; offline
version-1 captures remain readable, without frozen branch measurement fields.
After PONG the host clears partial parsing, assembled status pages and last STATUS
before GET_STATUS, so reused sequence values across reconnects cannot publish an
old complete snapshot. REPORT history remains intact.

Telemetry header (11 bytes): version:u8=2, page:u8, count:u8=3,
snapshot_id:u32, config_id:u32. Every page contains 48 data bytes; unused bytes
are zero. Three pages are frozen together. Report transmission may coalesce
periodic updates. Final configuration snapshots use a four-entry FIFO with
valid/ready handshakes. One slot is reserved for the current group; at three queued
groups the sender holds the inter-frame DC gap and TEST START/CLEAR return BUSY.
STOP remains available. Configuration commits resume with frame preparation when
capacity returns. Consumers group by version/CMD/SEQ/snapshot/config.

STATUS page 0 offsets: 0 run_requested:u8, 1 fsk_active:u8,
2 frame_active:u8, 3 knob_mode:u8 (0 frequency,1 bias,2 amplitude),
4 knob_taken:u8, 5 dds_pending:u8, 6 fsk_pending:u8, 7 test_running:u8,
8 DDS requested (8 bytes), 16 DDS active (8 bytes), 24 knob_raw:u16,
26 frame_id:u16, 28 target_frames:u32, 32 test_pending:u8, 33 report_space:u8.
DDS record: frequency:u32,wave:u8,amplitude:u8,bias:i16.

STATUS page 1: offset 0 requested FSK record, 9 active FSK record,
18 actual frame noise:u8. FSK record (9 bytes): amplitude:u8,bias:i16,
offset:i16,software_noise:u8,noise_scale:u16,physical_noise:u8.
FSK nominal profile is fixed at 1000/2000 Hz,100 bit/s.
STATUS page 2: 0 RTL version:u32,4 model version:u32,8 calibrated:u8,
9 receiver available:u8,10 AI available:u8,11 receiver lock:u8,
12 estimated offset:i16,14 AGC exponent:i16.

REPORT page 0: eight u32 values: tx_frames,dac_clips,run_id,test_frames,
adc_errors,adc_clips,dropped_reports,flags (bit0 test running, bit1 final,
bit2 final receiver drain incomplete, bit4 traditional incomplete, bit5 AI incomplete).
Offset 32: active FSK record (9 bytes); offset 41: RTL version:u32.
These values are frozen with the counters, including final configuration reports.
Pages 1 (traditional) and 2 (AI): eight u32 values: available,errors,bits,
crc_failures,captured_frames,lost_frames,last_frame_id,model_version.
Offset 32: estimated offset:i16; offset 34: AGC exponent:i16. Each branch's
measurements are frozen with its accepted tagged counter snapshot and exported
as explicit CSV columns, independently of the most recently received STATUS.
Counters saturate at 0xffffffff. RX counters are absolute snapshots supplied
independently per branch, tagged with config_id/run_id/frame_id. Stale snapshots
are rejected by live statistics. Closed groups continue accepting matching tagged
updates until both expected branches have captured_frames+lost_frames >= tx_frames,
or RX_DRAIN_CLKS expires (default one second at 100 MHz). The addition uses 33 bits.
Availability must be established before a run and held through its closure; a
branch absent at closure is not awaited. No receiver means immediate TX-only
finalization. On timeout incomplete flags explicitly mark partial statistics.
Sealed reports never change, even under backpressure; later updates are ignored.
Unavailable branches have available=0 and BER=null, not BER=0.

Receiver integration 0x00030003 uses these existing fields without changing
commands or page sizes. Traditional captured_frames includes aligned CRC-failed
frames; their payload errors and all 256 bits remain in BER. Whole uncaptured
frames increment lost_frames after the evaluator drain and contribute no BER
bits. ADC errors/clips count events/samples separately. AGC is a signed power-of-two
exponent (-3..3). AI remains available=0. A CRC-valid air ID is extended across
16-bit wrap for last_frame_id; invalid IDs do not select the payload reference.

Test START requires target_frames>0, no active/pending test action and FIFO space,
enters FSK and resets
statistics at the next frame prepare boundary after committing pending settings.
STOP and CLEAR apply at the next gap; CLEAR during
a running/pending test is BUSY. STOP cancels a pending START; a local KEY5 or RUN=0
exit also cancels it. Reaching the target closes the group and exits FSK while its
tagged receiver results drain. Re-entering after a closed group starts a fresh
run_id and counters before the next frame. Repeated same-tag closure is deduplicated.
Changing effective FSK configuration ends the active test and starts a new
configuration counter group without automatically starting a new target test.
