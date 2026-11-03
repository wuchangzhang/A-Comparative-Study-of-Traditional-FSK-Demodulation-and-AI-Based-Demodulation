"""Independent frame and DAC arithmetic reference for simulation vectors."""
import struct
from protocol import crc16


def prbs_payload():
    state = 1
    bits = []
    for _ in range(256):
        bits.append(state >> 14)
        state = ((state << 1) & 0x7fff) | (((state >> 14) ^ (state >> 13)) & 1)
    return bits


def pack_bits(bits):
    return bytes(sum(bits[i+j] << (7-j) for j in range(8)) for i in range(0, len(bits), 8))


def frame_bytes(frame_id):
    body = struct.pack('>H', frame_id & 0xffff) + pack_bits(prbs_payload())
    return bytes.fromhex('0000ffffaaaaaaaa1acffc1d') + body + struct.pack('>H', crc16(body))


def scale_sample(code, amplitude, bias, noise=0):
    centered = code - 128
    scaled = centered if amplitude == 255 else (centered * amplitude) >> 8
    raw = 128 + scaled + bias + noise
    return min(255, max(0, raw)), int(raw < 0 or raw > 255)


def legal_shape(amplitude, bias):
    return (-128 <= bias <= 127 and
            not scale_sample(0, amplitude, bias)[1] and
            not scale_sample(255, amplitude, bias)[1])
