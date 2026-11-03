"""Independent floating-point receiver checks, never an online PC demodulator.

Same search geometry as RTL; analytic sine/cosine references intentionally do
not reuse the quantized ROM. This verifies algorithms, not RTL bit equivalence.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/host'))
from reference import frame_bytes, prbs_payload
from protocol import crc16

FS = 50000
SPB = 500


def powers(x, frequencies):
    n = np.arange(x.shape[-1])
    ref = np.exp(-2j * np.pi * np.asarray(frequencies)[:, None] * n / FS)
    c = x @ ref.T
    return c.real**2 + c.imag**2


def receive(x):
    centered = x - np.mean(x[:500])
    blocks = centered[:len(x)//100*100].reshape(-1, 100)
    p = powers(blocks, [1000, 2000])
    zeros = 0
    boundary = None
    for i, value in enumerate(p):
        if value[0] > value[1] and value[0] > 4096:
            zeros += 1
        elif value[1] > value[0] and value[1] > 4096 and zeros >= 50:
            boundary = i*100
            break
        else:
            zeros = 0
    if boundary is None:
        raise AssertionError('no preamble candidate')
    stable0 = centered[boundary-6000:boundary-1904]
    stable1 = centered[boundary+2000:boundary+6096]
    offsets = np.arange(-100, 101, 10)
    scores = powers(stable0, 1000+offsets) + powers(stable1, 2000+offsets)
    delta = int(offsets[np.argmax(scores)])
    dc = np.mean(np.concatenate((x[boundary-6000:boundary-1904], x[boundary+2000:boundary+6096])))
    centered = x-dc
    expected = np.array([1 if i % 2 == 0 else -1 for i in range(32)])
    def timing_score(shifts):
        indices = boundary+8000+shifts[:, None, None]+np.arange(32)[None, :, None]*SPB+np.arange(SPB)
        energy = powers(centered[indices], [1000+delta, 2000+delta])
        return ((energy[:, :, 1]-energy[:, :, 0])*expected).sum(axis=1)
    shifts = np.arange(-150, 151, 25)
    best = shifts[np.argmax(timing_score(shifts))]
    shifts = np.arange(best-24, best+25)
    aligned = boundary+shifts[np.argmax(timing_score(shifts))]
    indices = aligned+24000+np.arange(320)[:, None]*SPB+np.arange(SPB)
    energy = powers(centered[indices], [1000+delta, 2000+delta])
    bits = (energy[:, 1] > energy[:, 0]).astype(np.uint8)
    sync = np.unpackbits(np.frombuffer(bytes.fromhex('1acffc1d'), dtype=np.uint8))
    assert np.count_nonzero(bits[:32] != sync) <= 2
    body = np.packbits(bits[32:304]).tobytes()
    actual_crc = int.from_bytes(np.packbits(bits[304:]).tobytes(), 'big')
    return delta, int(np.count_nonzero(bits[48:304] != prbs_payload())), actual_crc == crc16(body), int(aligned)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--frames', type=int, default=100, help='per offset')
    args = parser.parse_args()
    rng = np.random.default_rng(7606)
    results = []
    for delta in (-100, 0, 100):
        max_timing = 0
        for frame_id in range(args.frames):
            bits = np.unpackbits(np.frombuffer(frame_bytes(frame_id), dtype=np.uint8))
            shift = int(rng.integers(0, 500))
            start = 1000+shift
            amplitude = float(rng.uniform(512, 24000))
            bias = float(rng.uniform(-2000, 2000))
            phase = float(rng.uniform(0, 2*np.pi))
            frequencies = np.repeat(1000+bits.astype(float)*1000+delta, SPB)
            phases = phase+np.concatenate(([0], np.cumsum(2*np.pi*frequencies[:-1]/FS)))
            x = np.concatenate((np.full(start, bias), bias+amplitude*np.sin(phases), np.full(1000, bias)))
            estimate, errors, crc_ok, aligned = receive(np.rint(x))
            assert abs(estimate-delta) <= 10 and errors == 0 and crc_ok
            max_timing = max(max_timing, abs(aligned-(start+8000)))
        results.append(dict(offset=delta, frames=args.frames, errors=0, bits=args.frames*256,
                            max_timing_error_samples=max_timing))
        print(f'PASS reference offset={delta}: {args.frames} captures, zero payload errors, valid CRC', flush=True)
    (ROOT/'data/receiver_reference.json').write_text(json.dumps(results, indent=2), encoding='ascii')


if __name__ == '__main__':
    main()
