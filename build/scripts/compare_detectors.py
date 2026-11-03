"""Frozen-model detector comparison on synthetic samples and existing RTL replay.

Known symbol boundaries and exact carrier offset are shared by every detector.
No model training, parameter selection, or hardware measurements are performed.
"""
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import sys

os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/ai'))
from model import predict, SUB_FEATURE_SHIFT, FULL_FEATURE_SHIFT
from reference import SINE, STEPS, choose_gain, protocol_bits

OUT = ROOT / 'data/detector_comparison'
SEEDS = (82001, 83001, 84001)
COUNT = 256
FREQUENCIES = (1000, 1020, 1050, 1100, 1850, 1900, 1950, 2000)
PROFILES = ('aligned_quarter', 'shifted_quarter', 'shifted_half', 'continuous')
METHODS = ('full', 'majority', 'trim_max', 'ai')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decisions(features, full, parameters, shifts):
    sub = features[:, :8].astype(np.int64).reshape(-1, 4, 2)
    baseline = full[:, 1] > full[:, 0]
    votes = (sub[:, :, 1] > sub[:, :, 0]).sum(axis=1)
    majority = np.where(votes == 2, baseline, votes > 2)
    # Fixed rule: remove the window with highest P0+P1; earliest wins a tie.
    drop = np.argmax(sub.sum(axis=2), axis=1)
    retained = sub.sum(axis=1) - sub[np.arange(len(sub)), drop]
    trimmed = retained[:, 1] > retained[:, 0]
    return dict(full=baseline.astype(np.uint8), majority=majority.astype(np.uint8),
                trim_max=trimmed.astype(np.uint8), ai=predict(features, parameters, shifts))


def generate(rng, profile, frequency, ratio, noise):
    n = np.arange(500, dtype=np.int64)
    labels = rng.integers(0, 2, COUNT, dtype=np.uint8)
    delta = int(rng.choice((-50, 0, 50)))
    amplitude = rng.uniform(500, 1800, (COUNT, 1))
    phase = rng.uniform(0, 2 * np.pi, (COUNT, 1))
    x = amplitude * np.sin(2 * np.pi * (1000 + 1000 * labels[:, None].astype(np.int64) + delta) * n / 50000 + phase)
    if profile == 'continuous':
        mask = np.ones((COUNT, 500), dtype=bool)
    else:
        length = 250 if profile == 'shifted_half' else 125
        start = rng.integers(0, 4, (COUNT, 1)) * 125 if profile == 'aligned_quarter' else rng.integers(0, 501 - length, (COUNT, 1))
        fire = rng.integers(0, 2, (COUNT, 1))
        mask = ((n >= start) & (n < start + length)) * fire
    x += mask * ratio * amplitude * np.sin(2 * np.pi * frequency * n / 50000 + rng.uniform(0, 2 * np.pi, (COUNT, 1)))
    x += rng.normal(0, 1, x.shape) * amplitude * noise
    adc = np.rint(x).astype(np.int64)
    adc_clip = int(np.count_nonzero((adc < -32768) | (adc > 32767)))
    adc = np.clip(adc, -32768, 32767)
    clean_power = int((float(np.median(amplitude)) * 4096 * 127 / 16 / 256 / 2) ** 2)
    gain = choose_gain(clean_power)
    scaled = adc * (2 ** gain)
    gain_clip = int(np.count_nonzero((scaled < -32768) | (scaled > 32767)))
    q = np.clip(scaled, -32768, 32767) >> 4
    full, sub = [], []
    for step in STEPS[delta]:
        index = ((n * step) & 0xffffff) >> 16
        c, s = q * SINE[(index + 64) & 255], q * SINE[index]
        full.append((c.sum(axis=1) >> 8) ** 2 + (s.sum(axis=1) >> 8) ** 2)
        sub.append((c.reshape(COUNT, 4, 125).sum(axis=2) >> 8) ** 2 + (s.reshape(COUNT, 4, 125).sum(axis=2) >> 8) ** 2)
    full = np.stack(full, axis=1)
    sub = np.stack(sub, axis=2)
    unbounded = np.concatenate((sub.reshape(COUNT, 8) >> SUB_FEATURE_SHIFT, full >> FULL_FEATURE_SHIFT), axis=1)
    return labels, full, np.clip(unbounded, 0, 32767).astype(np.int16), sub, adc, dict(
        carrier_offset_hz=delta, gain=gain, adc_clipped_samples=adc_clip,
        gain_clipped_samples=gain_clip, saturated_features=int(np.count_nonzero(unbounded > 32767)))


def collect(labels, outputs):
    row = dict(bits=len(labels))
    for method in METHODS:
        wrong = outputs[method] != labels
        row[method + '_errors'] = int(wrong.sum())
    for baseline in METHODS[:-1]:
        ai_wrong = outputs['ai'] != labels
        base_wrong = outputs[baseline] != labels
        row['ai_better_than_' + baseline] = int(np.count_nonzero(base_wrong & ~ai_wrong))
        row['ai_worse_than_' + baseline] = int(np.count_nonzero(~base_wrong & ai_wrong))
    return row


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    model_path = ROOT / 'src/ai/model.npz'
    model = np.load(model_path)
    cells = [dict(profile=p, frequency_hz=f, jammer_ratio=r, noise_sigma_ratio=0.15)
             for p in PROFILES for f in FREQUENCIES for r in (2.5, 4.0, 5.0)]
    cells += [dict(profile='clean_awgn', frequency_hz=1000, jammer_ratio=0.0, noise_sigma_ratio=n) for n in (0.0, 0.15, 0.5, 1.0, 2.0)]
    plan = dict(seeds=SEEDS, symbols_per_seed_cell=COUNT, cells=cells,
                model_sha256=digest(model_path), model_version='00070001',
                assumptions='Synthetic 16-bit ADC samples; known symbol boundaries; exact shared offset; gain from clean signal; no DAC/analog distortion or capture evaluation.',
                rules='Frozen fixed-point AI weights; no test tuning. Majority ties use raw full-window decision. Trim removes earliest highest quantized P0+P1 window; ties in final energy choose bit 0.',
                resource_scope='Complete symbol correlator plus decision core; shared acquisition/history/UART excluded. Quantized subfeatures identical for AI and robust traditional detectors.')
    (OUT / 'test_plan.json').write_text(json.dumps(plan, indent=2) + '\n', encoding='utf-8')
    rows = []
    vector_samples, vector_metadata = [], []
    for seed in SEEDS:
        rng = np.random.default_rng(seed)
        for cell_index, cell in enumerate(cells):
            profile = cell['profile'] if cell['profile'] != 'clean_awgn' else 'continuous'
            labels, full, features, raw_sub, adc, diagnostic = generate(rng, profile, cell['frequency_hz'], cell['jammer_ratio'], cell['noise_sigma_ratio'])
            outputs = decisions(features, full, model['parameters'], model['shifts'])
            raw_votes = (raw_sub[:, :, 1] > raw_sub[:, :, 0]).sum(axis=1)
            raw_majority = np.where(raw_votes == 2, outputs['full'], raw_votes > 2)
            raw_drop = np.argmax(raw_sub.sum(axis=2), axis=1)
            raw_kept = raw_sub.sum(axis=1) - raw_sub[np.arange(COUNT), raw_drop]
            raw_trim = raw_kept[:, 1] > raw_kept[:, 0]
            rows.append(dict(seed=seed, **cell, **diagnostic, **collect(labels, outputs),
                             majority_raw_errors=int(np.count_nonzero(raw_majority != labels)),
                             trim_max_raw_errors=int(np.count_nonzero(raw_trim != labels))))
            if seed == SEEDS[0] and (cell_index % 12 in (0, 1) or cell_index >= 96):
                for sample_index in range(4):
                    vector_samples.extend(adc[sample_index].tolist())
                    expected = sum(int(outputs[method][sample_index]) << mode for mode, method in enumerate(METHODS))
                    feature_word = sum(int(value) << (16 * offset) for offset, value in enumerate(features[sample_index]))
                    steps = STEPS[diagnostic['carrier_offset_hz']]
                    vector_metadata.append(f'{steps[0]:06x} {steps[1]:06x} {diagnostic["gain"] & 15:x} {expected:x} {feature_word:040x}')
        print(f'Finished seed {seed}: {len(cells)} cells', flush=True)
    with (OUT / 'symbol_results.csv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (OUT / 'rtl_samples.mem').write_text(''.join(f'{value & 65535:04x}\n' for value in vector_samples), encoding='ascii')
    (OUT / 'rtl_vectors.txt').write_text('\n'.join(vector_metadata) + '\n', encoding='ascii')
    groups = []
    for profile in (*PROFILES, 'clean_awgn'):
        subset = [row for row in rows if row['profile'] == profile]
        sums = {key: sum(row[key] for row in subset) for key in rows[0]
                if key == 'bits' or key.endswith('_errors') or key.startswith(('ai_better_', 'ai_worse_'))}
        groups.append(dict(profile=profile, **sums))
    replay = np.load(ROOT / 'data/burst_experiment/rtl_capture.npz')
    features = replay['features']
    full = features[:, 8:].astype(np.int64)
    replay_outputs = decisions(features, full, model['parameters'], model['shifts'])
    # Preserve the exact raw full-window detector output saved by the RTL replay.
    replay_outputs['full'] = replay['traditional']
    sub = features[:, :8].reshape(-1, 4, 2)
    votes = (sub[:, :, 1] > sub[:, :, 0]).sum(axis=1)
    replay_outputs['majority'] = np.where(votes == 2, replay['traditional'], votes > 2).astype(np.uint8)
    assert np.array_equal(replay_outputs['ai'], replay['ai']), 'Frozen model differs from saved replay decisions'
    labels = protocol_bits(0)[112:368]
    # The existing replay's payload is the production PRBS; frame ID does not affect it.
    replay_result = collect(labels, {k: v[16:272] for k, v in replay_outputs.items()})
    np.savez_compressed(OUT / 'rtl_replay_decisions.npz', labels=labels,
                        **{k: v[16:272] for k, v in replay_outputs.items()})
    summary = dict(groups=groups, rtl_replay=dict(**replay_result, evidence_scope='Existing ideal-ADC RTL replay; not analog acquisition', source_sha256=digest(ROOT / 'data/burst_experiment/rtl_capture.npz')),
                   synthetic_total_bits=sum(r['bits'] for r in rows), synthetic_total_cells=len(rows), rtl_vector_count=len(vector_metadata),
                   statistics='Per-seed/cell paired counts provided; correlated burst errors preclude assuming independent bits. No measured hardware BER is added by this experiment.')
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
