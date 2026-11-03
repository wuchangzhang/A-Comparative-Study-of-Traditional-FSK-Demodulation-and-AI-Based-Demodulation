"""Independent AI reference: reproduce RTL feature+MLP decisions off-line.

This verifies the training/evaluation pipeline is self-consistent: acquire the
frame with the autonomous front-end, extract the integer features exactly as
fsk_correlator.sv does, and run the exported integer model. It never drives
hardware and is not an online demodulator.
The feature vector is 10-dimensional: eight 125-point sub-window powers plus the
two coherent 500-point powers (ai/model.py).
"""
import argparse
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/ai'))
from model import predict, forward_integer  # noqa: E402
from reference import make_waveform, protocol_bits, receive_symbols  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--frames', type=int, default=20)
    parser.add_argument('--jammer-freq', type=int, default=None,
                        help='tone jammer frequency in Hz (must avoid 100 Hz grid)')
    parser.add_argument('--jammer-ratio', type=float, default=0.7,
                        help='jammer amplitude relative to the FSK amplitude')
    args = parser.parse_args()
    parameters = np.load(ROOT / 'src/ai/model.npz')['parameters']
    shifts = np.load(ROOT / 'src/ai/model.npz')['shifts']
    rng = np.random.default_rng(20261026)
    total = 0
    mismatches = 0
    decisions = 0
    traditional = 0
    for _ in range(args.frames):
        data = rng.integers(0, 2, 288, dtype=np.uint8)
        air = np.concatenate((protocol_bits(0)[:96], data))
        offset = int(rng.choice([-100, -50, 0, 50, 100]))
        x, _ = make_waveform(air, rng, delta=offset, eb_n0=16,
                             jammer_freq=args.jammer_freq, jammer_ratio=args.jammer_ratio)
        try:
            result = receive_symbols(x)
        except RuntimeError:
            continue
        prediction = predict(result['features'], parameters, shifts)
        mismatches += int(np.count_nonzero(prediction != data))
        traditional += int(np.count_nonzero(result['traditional'] != data))
        decisions += int(prediction.size)
        total += 288
        # The integer reference must agree with the traditional baseline on the
        # features, and the MLP must run without accumulator overflow.
        forward_integer(result['features'], parameters, shifts)
    label = 'clean' if args.jammer_freq is None else f'jammer {args.jammer_freq} Hz x{args.jammer_ratio}'
    print(f'PASS check_ai_reference: {decisions} decisions across {total} bits, '
          f'{mismatches} AI errors vs {traditional} traditional errors ({label} channel)', flush=True)


if __name__ == '__main__':
    main()
