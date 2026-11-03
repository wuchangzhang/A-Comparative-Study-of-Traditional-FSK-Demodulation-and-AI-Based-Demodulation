"""Collect routed module costs, immutable inputs, and comparison figures."""
import csv
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'data/detector_comparison'
BUILD = ROOT / 'build/detector_comparison'
METHODS = ('full', 'majority', 'trim_max', 'ai')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def utilization(text, label):
    match = re.search(r'^\|\s*' + re.escape(label) + r'\s*\|\s*(\d+)\s*\|', text, re.M)
    assert match, label
    return int(match[1])


def main():
    check = (ROOT / 'sim/detector_comparison/check_stage2.log').read_text(encoding='utf-8')
    latencies = re.search(r'cycles full=(\d+) majority=(\d+) trim=(\d+) ai=(\d+)', check)
    assert latencies and 'PASS tb_detector_benchmark:' in check
    rows = []
    for method, cycles in zip(METHODS, map(int, latencies.groups())):
        folder = BUILD / method
        text = (folder / 'routed_utilization.rpt').read_text(encoding='utf-8')
        timing = (folder / 'timing_summary.rpt').read_text(encoding='utf-8')
        match = re.search(r'^sys_clk_100m\s+([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)', timing, re.M)
        assert match, method
        drc = (folder / 'drc.rpt').read_text(encoding='utf-8')
        errors = len(re.findall(r'\|\s*(?:Error|Critical Warning)\s*\|', drc))
        row = dict(method=method,
                   lut=utilization(text, 'Slice LUTs'), ff=utilization(text, 'Slice Registers'),
                   dsp=utilization(text, 'DSPs'), ramb36=utilization(text, 'RAMB36/FIFO*'), ramb18=utilization(text, 'RAMB18'),
                   wns_ns=float(match[1]), tns_ns=float(match[2]), whs_ns=float(match[3]), ths_ns=float(match[4]),
                   drc_error_or_critical_rule_rows=errors, processing_cycles=cycles, processing_us=cycles / 100)
        row['timing_met'] = row['wns_ns'] >= 0 and row['tns_ns'] >= 0 and row['whs_ns'] >= 0 and row['ths_ns'] >= 0
        # OOC comparison is evidence for cost/latency trade-offs.  Preserve a
        # failing timing result instead of treating it as a passing build; the
        # full-board timing signoff remains a separate artifact.
        assert errors == 0, row
        rows.append(row)
    with (DATA / 'resource_results.csv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    summary = json.loads((DATA / 'summary.json').read_text(encoding='utf-8'))
    diagnostics = list(csv.DictReader((DATA / 'symbol_results.csv').open(encoding='utf-8')))
    receipt = dict(tool='Vivado 2026.1 build 6511674', part='xc7a35tcsg324-1', clock_mhz=100,
                   scope='Out-of-context symbol correlator plus detector; no ADC, history RAM, acquisition, UART or board IO. Routed timing covers constrained internal register paths; input/output delays are unspecified.',
                   drc_scope='Out-of-context DRC; warnings are retained. This is not full-board DRC signoff.',
                   source_files={str(p.relative_to(ROOT)).replace('\\', '/'): sha(p) for p in (
                       ROOT / 'src/rtl/fsk_correlator.sv', ROOT / 'src/rtl/ai_mlp.sv', ROOT / 'src/rtl/rx_sine.mem', ROOT / 'src/rtl/ai_mlp.mem',
                       ROOT / 'src/ai/model.npz', ROOT / 'src/ai/model.py', ROOT / 'src/ai/reference.py',
                       ROOT / 'sim/detector_comparison/detector_benchmark.sv', ROOT / 'sim/detector_comparison/tb_detector_benchmark.sv',
                       ROOT / 'build/scripts/compare_detectors.py', ROOT / 'build/scripts/compare_detector_resources.tcl')},
                   resources=rows,
                   numeric_diagnostics={key: sum(int(r[key]) for r in diagnostics) for key in ('adc_clipped_samples', 'gain_clipped_samples', 'saturated_features')},
                   fixed_baselines='Majority and trim use identical 16-bit features to AI; raw-power sensitivity counts are also supplied in symbol_results.csv and summary.json.',
                   reproduction='Run compare_detectors.py, run_detector_checks.py, Vivado compare_detector_resources.tcl, then summarize_detector_comparison.py; no training required.')
    (DATA / 'resource_receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import numpy as np
    plt.rcParams.update({'font.size': 11, 'axes.spines.top': False, 'axes.spines.right': False})
    fig, axes = plt.subplots(1, 2, figsize=(6.8, 3.1), layout='constrained')
    colors = ('#747b84', '#168b83', '#c38a18', '#bf456b')
    selected = summary['groups'][:3]
    x = np.arange(3)
    labels = ('Full window', 'Majority vote', 'Trim max-energy', 'Fixed-point AI')
    for index, (method, label, color) in enumerate(zip(METHODS, labels, colors)):
        axes[0].bar(x + (index - 1.5) * 0.19, [g[method + '_errors'] / g['bits'] * 100 for g in selected], width=0.18, label=label, color=color)
    axes[0].set_xticks(x, ['Aligned\nquarter', 'Shifted\nquarter', 'Shifted\nhalf'])
    axes[0].set_ylabel('Symbol errors (%)')
    axes[0].set_title('Same synthetic inputs\n18,432 bits per profile')
    axes[0].legend(frameon=False, fontsize=9)
    for row, label, color in zip(rows, labels, colors):
        axes[1].scatter(row['lut'], selected[1][row['method'] + '_errors'] / selected[1]['bits'] * 100, s=75, color=color)
        axes[1].annotate(f'{row["dsp"]} DSP', (row['lut'], selected[1][row['method'] + '_errors'] / selected[1]['bits'] * 100), xytext=(0, 10), textcoords='offset points', ha='center', fontsize=10)
    axes[1].set_xlabel('Routed LUTs (OOC)')
    axes[1].set_ylabel('Shifted-quarter errors (%)')
    axes[1].set_title('Reliability versus\nmodule cost')
    axes[1].margins(x=0.25, y=0.35)
    fig.savefig(DATA / 'reliability_cost.png', dpi=180)
    plt.close(fig)
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
