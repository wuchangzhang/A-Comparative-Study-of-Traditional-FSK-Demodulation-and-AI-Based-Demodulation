"""Emit golden feature vectors for tb_ai_features from synthetic symbol windows."""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/ai'))
from reference import (FS, SINE, STEPS, SPB, SUBWINDOW,  # noqa: E402
                       FEATURE_DIM, FULL_FEATURE_SHIFT, SUB_FEATURE_SHIFT)

CASES = [
    dict(delta=-100, gain=0, dc=0, amplitude=2000, bit=0, phase=0.0),
    dict(delta=0, gain=-2, dc=100, amplitude=3000, bit=1, phase=1.1),
    dict(delta=50, gain=2, dc=-50, amplitude=1500, bit=0, phase=0.3),
    dict(delta=100, gain=-1, dc=20, amplitude=2500, bit=1, phase=2.0),
]


def fixed_correlation(samples, delta, dc, gain):
    step0, step1 = STEPS[int(delta)]
    centered = samples.astype(np.int64) - int(dc)
    scaled = (centered << gain) if gain >= 0 else (centered >> -gain)
    scaled = np.clip(scaled, -32768, 32767)
    quantized = scaled >> 4
    index = np.arange(SPB, dtype=np.int64)
    phase0 = (index * step0) & 0xffffff
    phase1 = (index * step1) & 0xffffff
    refs = ((phase0 >> 16), (phase1 >> 16))
    full = []
    features = []
    for freq in range(2):
        phase = refs[freq]
        cosine = SINE[(phase + 64) & 255]
        sine = SINE[phase]
        c_values = quantized * cosine
        s_values = quantized * sine
        full.append((int(np.sum(c_values)) >> 8) ** 2 + (int(np.sum(s_values)) >> 8) ** 2)
        c_prefix = np.concatenate(([0], np.cumsum(c_values)))
        s_prefix = np.concatenate(([0], np.cumsum(s_values)))
        for w in range(4):
            lo, hi = w * SUBWINDOW, (w + 1) * SUBWINDOW
            c = int(c_prefix[hi] - c_prefix[lo]) >> 8
            s = int(s_prefix[hi] - s_prefix[lo]) >> 8
            features.append(c * c + s * s)
    ordered = []
    for w in range(4):
        ordered.append(features[w])
        ordered.append(features[4 + w])
    ordered = np.clip(np.right_shift(ordered, SUB_FEATURE_SHIFT), 0, 32767).astype(np.int64)
    # Indices 8 and 9 are the coherent full-window powers, quantised on their
    # own (coarser) shift so they land on the same int16 scale as the rest.
    ordered = np.concatenate((ordered, np.clip(np.right_shift(np.asarray(full, dtype=np.int64),
                                                              FULL_FEATURE_SHIFT), 0, 32767)))
    if ordered.size != FEATURE_DIM:
        raise AssertionError('feature layout drift')
    return full, ordered


def main():
    lines = [str(len(CASES))]
    for case in CASES:
        rng = np.random.default_rng(int(case['amplitude']) + int(abs(case['dc'])) + 7)
        index = np.arange(SPB)
        freq = 1000 + case['bit'] * 1000 + case['delta']
        phase = case['phase'] + np.cumsum(2 * np.pi * freq / FS * np.ones(SPB)) - 2 * np.pi * freq / FS
        samples = np.rint(case['dc'] + case['amplitude'] * np.sin(phase)).astype(np.int64)
        full, features = fixed_correlation(samples, case['delta'], case['dc'], case['gain'])
        step0, step1 = STEPS[int(case['delta'])]
        values = [case['delta'], case['dc'], case['gain'], step0, step1] + \
                 list(samples) + [full[0], full[1]] + list(features)
        lines.append(' '.join(str(v) for v in values))
    (ROOT / 'sim/ai_feature_golden.txt').write_text('\n'.join(lines) + '\n', encoding='ascii')
    print('PASS export_ai_features: cases written')


if __name__ == '__main__':
    main()
