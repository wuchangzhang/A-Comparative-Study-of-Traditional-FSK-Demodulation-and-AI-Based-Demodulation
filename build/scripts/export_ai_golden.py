"""Emit golden AI feature vectors and expected MLP decisions for tb_ai_mlp."""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/ai'))
from model import FEATURE_DIM, forward_integer, predict  # noqa: E402

TOTAL = 64
WORDS_PER_ROW = 37  # 10 features + 16 act1 + 8 act2 + 2 logits + 1 decision


def main():
    parameters = np.load(ROOT / 'src/ai/model.npz')['parameters']
    shifts = np.load(ROOT / 'src/ai/model.npz')['shifts']
    features = np.loadtxt(ROOT / 'sim/ai_golden_inputs.txt', dtype=np.int16)
    if features.shape != (TOTAL, FEATURE_DIM):
        raise ValueError('Golden inputs must contain 64 rows of 10 features')
    acc, acts = forward_integer(features, parameters, shifts)
    decisions = predict(features, parameters, shifts)
    rows = []
    for i in range(TOTAL):
        values = list(features[i].astype(np.int64))
        values += list(acts[0][i])
        values += list(acts[1][i])
        values += list(acc[-1][i])
        values.append(int(decisions[i]))
        rows.append(values)
    # Emit as space-separated signed decimal per row (easy for SV to parse), plus
    # a header line with the row count.
    lines = [f'{TOTAL}']
    for row in rows:
        lines.append(' '.join(str(v) for v in row))
    (ROOT / 'sim/ai_golden.txt').write_text('\n'.join(lines) + '\n', encoding='ascii')
    print(f'PASS export_ai_golden: {TOTAL} rows written to sim/ai_golden.txt')


if __name__ == '__main__':
    main()
