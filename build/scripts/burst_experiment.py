"""Payload-only burst experiment; independent seeds, fixed-point inference.

This first-stage experiment assumes acquired symbol boundaries. It does not
measure acquisition or the analog channel. No production weights are changed.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/ai'))
from model import SUB_FEATURE_SHIFT, FULL_FEATURE_SHIFT, check_ranges, predict, export_mem
from reference import SINE, STEPS, choose_gain, make_waveform, protocol_bits, receive_symbols
from qat import train_qat


def fingerprint(candidate):
    return hashlib.sha256(candidate['parameters'].tobytes()+candidate['shifts'].tobytes()).hexdigest()


def selected_model(out):
    candidate = out/'candidate.npz'
    return np.load(candidate if candidate.exists() else ROOT/'src/ai/model.npz')


def symbols(seed, count, frequencies=(1000, 1050, 1950, 2000)):
    rng = np.random.default_rng(seed)
    xs, ys, trad, majority, cells = [], [], [], [], []
    n = np.arange(500)
    for frequency in frequencies:
        for ratio in (0.0, 3.0, 4.0, 5.0):
            y = rng.integers(0, 2, count, dtype=np.uint8)
            delta = int(rng.choice((-50, 0, 50)))
            phase = rng.uniform(0, 2*np.pi, (count, 1))
            amplitude = rng.uniform(500, 1800, (count, 1))
            x = amplitude*np.sin(2*np.pi*(1000+1000*y[:, None].astype(np.int64)+delta)*n/50000+phase)
            slot = rng.integers(0, 4, (count, 1))
            fire = rng.integers(0, 2, (count, 1))
            mask = (n//125 == slot)*fire
            jam_phase = rng.uniform(0, 2*np.pi, (count, 1))
            x += mask*ratio*amplitude*np.sin(2*np.pi*frequency*n/50000+jam_phase)
            x += rng.normal(0, 1, x.shape)*amplitude*0.15
            # Gain comes from a clean preamble; use the same RTL power scale.
            clean_power = int((float(np.median(amplitude))*4096*127/16/256/2)**2)
            gain = choose_gain(clean_power)
            q = np.clip(np.rint(x).astype(np.int64)*(2**gain), -32768, 32767) >> 4
            full, sub = [], []
            for step in STEPS[delta]:
                indices = ((n*step) & 0xffffff) >> 16
                c = q*SINE[(indices+64) & 255]
                s = q*SINE[indices]
                full.append((c.sum(axis=1) >> 8)**2+(s.sum(axis=1) >> 8)**2)
                sub.append((c.reshape(count, 4, 125).sum(axis=2) >> 8)**2+
                           (s.reshape(count, 4, 125).sum(axis=2) >> 8)**2)
            full = np.stack(full, axis=1)
            sub = np.stack(sub, axis=2)
            f = np.concatenate((sub.reshape(count, 8) >> SUB_FEATURE_SHIFT,
                                full >> FULL_FEATURE_SHIFT), axis=1)
            xs.append(np.clip(f, 0, 32767).astype(np.int16))
            ys.append(y)
            decision = full[:, 1] > full[:, 0]
            trad.append(decision)
            votes = (sub[:, :, 1] > sub[:, :, 0]).sum(axis=1)
            majority.append(np.where(votes == 2, decision, votes > 2))
            cells.extend([f'{frequency}Hz_x{ratio}']*count)
    return dict(x=np.concatenate(xs), y=np.concatenate(ys),
                traditional=np.concatenate(trad), majority=np.concatenate(majority),
                cells=np.asarray(cells))


def metrics(data, parameters, shifts):
    ai = predict(data['x'], parameters, shifts)
    result = []
    for cell in np.unique(data['cells']):
        m = data['cells'] == cell
        result.append(dict(cell=cell, bits=int(m.sum()), **{
            name: int(np.count_nonzero(values[m] != data['y'][m]))
            for name, values in [('traditional', data['traditional']),
                                 ('majority', data['majority']), ('ai', ai)]}))
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--epochs', type=int, default=50)
    p.add_argument('--count', type=int, default=2400)
    p.add_argument('--seeds', type=int, default=3)
    p.add_argument('--frames-only', action='store_true')
    p.add_argument('--export', action='store_true')
    p.add_argument('--heldout', action='store_true')
    args = p.parse_args()
    out = ROOT/'data'/'burst_experiment'
    out.mkdir(parents=True, exist_ok=True)
    if args.heldout:
        candidate = selected_model(out)
        test = symbols(77001, args.count, frequencies=(1020, 1100, 1850, 1980))
        rows = metrics(test, candidate['parameters'], candidate['shifts'])
        (out/'heldout.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
        print('Held-out frequencies: '+str({k: sum(r[k] for r in rows)
              for k in ('bits', 'traditional', 'majority', 'ai')}))
        return
    if args.export:
        candidate = selected_model(out)
        evidence = json.loads((out/'frames_metadata.json').read_text(encoding='utf-8'))
        if evidence['candidate_sha256'] != fingerprint(candidate):
            raise RuntimeError('Re-run --frames-only after training: candidate differs from evidence')
        rows = json.loads((out/'frames.json').read_text(encoding='utf-8'))
        if any(r['captured'] != r['attempted'] or r['ai'] > r['traditional'] for r in rows):
            raise RuntimeError('frame evaluation gate failed')
        if sum(r['traditional'] for r in rows) <= sum(r['ai'] for r in rows):
            raise RuntimeError('no measured benefit')
        np.savez(ROOT/'src/ai/model.npz', parameters=candidate['parameters'], shifts=candidate['shifts'],
                 model_version=0x00070001)
        export_mem(candidate['parameters'], ROOT/'src/rtl/ai_mlp.mem')
        print('Exported final burst model 00070001')
        return
    if args.frames_only:
        candidate = selected_model(out)
        rng = np.random.default_rng(76001)
        rows = []
        for frequency in (1000, 1050, 1950, 2000):
            for ratio in (0.0, 3.0, 4.0, 5.0):
                counts = dict(frequency=frequency, ratio=ratio, attempted=6, captured=0,
                              bits=0, traditional=0, majority=0, ai=0,
                              traditional_crc_failures=0, ai_crc_failures=0)
                for frame in range(6):
                    bits = protocol_bits(frame)
                    # Random body bits prevent the fixed PRBS from becoming a label shortcut.
                    body = rng.integers(0, 2, 272, dtype=np.uint8)
                    from protocol import crc16
                    crc = np.unpackbits(np.frombuffer(crc16(np.packbits(body).tobytes()).to_bytes(2, 'big'), dtype=np.uint8))
                    bits[96:] = np.concatenate((body, crc))
                    wave, _ = make_waveform(bits, rng, delta=int(rng.choice((-50, 0, 50))),
                        amplitude=1000, jammer_freq=frequency, jammer_ratio=ratio, burst_payload=True)
                    # ADC input and the correlator's gain stage both have finite range.
                    wave = np.clip(wave, -32768, 32767)
                    try:
                        result = receive_symbols(wave)
                    except RuntimeError:
                        continue
                    counts['captured'] += 1
                    counts['bits'] += 256
                    ai = predict(result['features'], candidate['parameters'], candidate['shifts'])
                    sub = result['sub_powers'].reshape(288, 4, 2)
                    votes = (sub[:, :, 1] > sub[:, :, 0]).sum(axis=1)
                    majority = np.where(votes == 2, result['traditional'], votes > 2)
                    for name, decisions in [('traditional', result['traditional']), ('ai', ai), ('majority', majority)]:
                        counts[name] += int(np.count_nonzero(decisions[16:272] != bits[112:368]))
                        if name != 'majority':
                            computed = crc16(np.packbits(decisions[:272]).tobytes())
                            received = int.from_bytes(np.packbits(decisions[272:]).tobytes(), 'big')
                            counts[name+'_crc_failures'] += int(computed != received)
                rows.append(counts)
                print(counts, flush=True)
        (out/'frames.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
        (out/'frames_metadata.json').write_text(json.dumps(dict(seed=76001,
            candidate_sha256=fingerprint(candidate), preamble_protected=True,
            attempted=sum(r['attempted'] for r in rows), captured=sum(r['captured'] for r in rows)),
            indent=2), encoding='utf-8')
        return
    train, validation = symbols(71001, args.count), symbols(72001, args.count//2)
    best = None
    for seed in range(args.seeds):
        parameters, shifts, _ = train_qat(train, seed, args.epochs, forced_shifts=(4, 5, 0))
        error = int(np.count_nonzero(predict(validation['x'], parameters, shifts) != validation['y']))
        print(f'seed {seed}: validation errors {error}', flush=True)
        if best is None or error < best[0]:
            best = error, seed, parameters, shifts
    _, seed, parameters, shifts = best
    np.savez(out/'candidate.npz', parameters=parameters, shifts=shifts)
    results = []
    for test_seed in (73001, 74001, 75001):
        test = symbols(test_seed, args.count)
        rows = metrics(test, parameters, shifts)
        results.append(dict(seed=test_seed, rows=rows, ranges=check_ranges(test['x'], parameters, shifts)))
        print(f'test {test_seed}: '+str({k: sum(r[k] for r in rows)
              for k in ('bits', 'traditional', 'majority', 'ai')}), flush=True)
    (out/'evaluation.json').write_text(json.dumps(dict(selected_seed=seed, assumptions=
        'Known symbol boundaries; clean acquisition; no ADC/DAC model; payload only',
        results=results), indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
