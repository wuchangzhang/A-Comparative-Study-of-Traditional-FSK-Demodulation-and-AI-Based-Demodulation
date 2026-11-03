"""Version 2 control protocol; version 1 captures remain readable offline."""
import binascii
import struct
import time
from dataclasses import dataclass

ACK, NACK, STATUS, REPORT, PONG = range(0x80, 0x85)
ERRORS = {1: 'BAD_CRC', 2: 'BAD_LENGTH', 3: 'OUT_OF_RANGE',
          4: 'UNSUPPORTED_PROFILE', 5: 'BUSY', 6: 'SEQ_CONFLICT', 7: 'UNKNOWN_CMD'}


def crc16(data):
    return binascii.crc_hqx(data, 0xffff)


@dataclass(frozen=True)
class Packet:
    cmd: int
    seq: int
    payload: bytes = b''

    def encode(self):
        if len(self.payload) > 64:
            raise ValueError('payload exceeds 64 bytes')
        body = struct.pack('>BBH', self.cmd, len(self.payload), self.seq) + self.payload
        return b'\x55\xaa' + body + struct.pack('>H', crc16(body))


class Parser:
    def __init__(self, timeout=0.1):
        self.buffer = bytearray()
        self.last = 0.0
        self.timeout = timeout
        self.errors = 0

    def feed(self, data, now=None):
        now = time.monotonic() if now is None else now
        if self.buffer and now - self.last > self.timeout:
            self.buffer.clear()
        if data:
            self.last = now
        self.buffer.extend(data)
        packets = []
        while len(self.buffer) >= 2:
            start = self.buffer.find(b'\x55\xaa')
            if start < 0:
                self.buffer[:] = b'\x55' if self.buffer[-1] == 0x55 else b''
                break
            del self.buffer[:start]
            if len(self.buffer) < 6:
                break
            cmd, length, seq = struct.unpack('>BBH', self.buffer[2:6])
            if length > 64:
                self.errors += 1
                del self.buffer[0]
                continue
            size = length + 8
            if len(self.buffer) < size:
                break
            frame = bytes(self.buffer[:size])
            if crc16(frame[2:-2]) != int.from_bytes(frame[-2:], 'big'):
                self.errors += 1
                del self.buffer[0]
                continue
            packets.append(Packet(cmd, seq, frame[6:-2]))
            del self.buffer[:size]
        return packets


def dds_payload(hz=1000, wave=0, amplitude=255, bias=0):
    return struct.pack('>IBBh', hz, wave, amplitude, bias)


def fsk_payload(amplitude=128, bias=0, offset=0, f0=1000, f1=2000, bitrate=100):
    return struct.pack('>IIHBhh', f0, f1, bitrate, amplitude, bias, offset)


def jammer_payload(enable=0, amplitude=0, frequency=1500, burst=False):
    payload = struct.pack('>BBH', enable, amplitude, frequency)
    return payload + b'\x01' if burst else payload


def decode_dds(data):
    values = struct.unpack('>IBBh', data)
    return dict(zip(('hz', 'wave', 'amplitude', 'bias'), values))


def decode_fsk(data):
    values = struct.unpack('>BhhBHB', data)
    return dict(zip(('amplitude', 'bias', 'offset_hz', 'software_noise', 'noise_scale', 'physical_noise'), values))


class Snapshots:
    """Only publish complete, matching snapshots; never merge configurations."""
    def __init__(self):
        self.pending = {}

    def feed(self, packet):
        if packet.cmd not in (STATUS, REPORT) or len(packet.payload) != 59:
            return None
        version, page, count, snap, config = struct.unpack('>BBBII', packet.payload[:11])
        if version not in (1, 2) or count != 3 or page >= count:
            raise ValueError('unsupported telemetry layout')
        key = (version, packet.cmd, packet.seq, snap, config)
        pages = self.pending.setdefault(key, {})
        pages[page] = packet.payload[11:]
        while len(self.pending) > 12:
            del self.pending[next(iter(self.pending))]
        if len(pages) != count:
            return None
        del self.pending[key]
        result = {'kind': 'status' if packet.cmd == STATUS else 'report',
                  'snapshot_id': snap, 'config_id': config, 'protocol_version': version,
                  'request_seq': packet.seq}
        if packet.cmd == STATUS:
            p = pages[0]
            result.update(zip(('run_requested', 'fsk_active', 'frame_active', 'knob_mode',
                               'knob_taken', 'dds_pending', 'fsk_pending', 'test_running'), p[:8]))
            result['dds_requested'] = decode_dds(p[8:16])
            result['dds_active'] = decode_dds(p[16:24])
            result['fsk_requested'] = decode_fsk(pages[1][:9])
            result['fsk_active_config'] = decode_fsk(pages[1][9:18])
            result['noise_actual'] = pages[1][18]
            result['knob_raw'] = int.from_bytes(p[24:26], 'big')
            result['frame_id'] = int.from_bytes(p[26:28], 'big')
            result['target_frames'] = int.from_bytes(p[28:32], 'big')
            if version >= 2:
                result['test_pending'], result['report_space'] = p[32:34]
            result['rtl_version'], result['model_version'] = struct.unpack('>II', pages[2][:8])
            result['calibrated'], result['rx_available'], result['ai_available'] = pages[2][8:11]
            result['rx_lock'] = pages[2][11]
            result['offset_estimate'], result['agc_exponent'] = struct.unpack('>hh', pages[2][12:16])
            result['signal_peak'] = struct.unpack('>H', pages[2][16:18])[0]
            result['adc_state_code'] = pages[2][18] >> 4
            result['adc_error_reason'] = pages[2][18] & 0x0F
            result['adc_busy_level'] = (pages[2][19] >> 7) & 1
            result['adc_dout_level'] = (pages[2][19] >> 6) & 1
            result['adc_reset_count'] = struct.unpack('>I', pages[2][20:24])[0]
            if len(pages[2]) > 27:
                result['jam_enable'] = pages[2][24] & 1
                result['jam_burst'] = (pages[2][24] >> 1) & 1
                result['jam_amplitude'] = pages[2][25]
                result['jam_hz'] = int.from_bytes(pages[2][26:28], 'big')
        else:
            names = ('tx_frames', 'dac_clips', 'run_id', 'test_frames', 'adc_errors', 'adc_clips', 'dropped_reports', 'flags')
            result.update(zip(names, struct.unpack('>8I', pages[0][:32])))
            result['fsk_active_config'] = decode_fsk(pages[0][32:41])
            result['rtl_version'] = int.from_bytes(pages[0][41:45], 'big')
            result['final'] = bool(result['flags'] & 2)
            result['incomplete'] = bool(result['flags'] & 4)
            for branch, page in (('trad', pages[1]), ('ai', pages[2])):
                if branch == 'trad' and len(page) > 39:
                    result['jam_enable'] = page[36] & 1
                    result['jam_burst'] = (page[36] >> 1) & 1
                    result['jam_amplitude'] = page[37]
                    result['jam_hz'] = int.from_bytes(page[38:40], 'big')
                values = struct.unpack('>8I', page[:32])
                for name, value in zip(('valid', 'errors', 'bits', 'crc_failures', 'captured_frames', 'lost_frames', 'last_frame', 'model_version'), values):
                    result[branch + '_' + name] = value
                result[branch + '_ber'] = (values[1] / values[2]) if values[0] and values[2] else None
                result[branch + '_incomplete'] = bool(result['flags'] & (16 if branch == 'trad' else 32))
                if version >= 2:
                    result[branch + '_offset_estimate'], result[branch + '_agc_exponent'] = struct.unpack('>hh', page[32:36])
        return result
