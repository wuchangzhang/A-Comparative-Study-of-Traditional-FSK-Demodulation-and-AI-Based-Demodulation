"""Verify submission layout, source provenance and hardware evidence."""
import argparse
import csv
import hashlib
import json
import re
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = 'data/release_manifest.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root):
    return {p.relative_to(root).as_posix(): p for p in root.rglob('*') if p.is_file()
            and '__pycache__' not in p.parts and p.suffix != '.pyc'
            and p.relative_to(root).as_posix() != MANIFEST}


def check(root):
    assert {p.name for p in root.iterdir()} == {
        'README.md', 'src', 'sim', 'build', 'board', 'data', 'skill', 'report'}
    for p in root.rglob('*'):
        if '__pycache__' in p.parts or p.suffix == '.pyc':
            continue
        assert p.name in ('README.md', 'SKILL.md') or re.fullmatch(r'[a-z0-9_.-]+', p.name), p
    mapping = json.loads((root/'data/layout_manifest.json').read_text(encoding='utf-8'))['mapping']
    assert len(mapping) == 210
    for old, info in mapping.items():
        assert (root/info['path']).is_file(), old
        if old.startswith(('rtl/', 'constraints/', 'host/', 'ai/', 'sim/')) or old.endswith(('.bit', '.dcp')):
            assert sha(root/info['path']) == info['original_sha256'], old
    receipt = json.loads((root/'build/burst_v7/validation.json').read_text(encoding='utf-8'))
    for name, digest in receipt['sources'].items():
        name = name.replace(chr(92), '/')
        if name.startswith(('rtl/', 'constraints/')) or name in (
                'ai/model.py', 'ai/model.npz', 'sim/ai_golden.txt', 'sim/ai_feature_golden.txt'):
            assert sha(root/mapping[name]['path']) == digest, name
    bits = list(root.rglob('*.bit'))
    assert len(bits) == 1 and sha(bits[0]) == receipt['bitstream_sha256']
    for name, evidence in receipt['tests'].items():
        log = root/'sim/results'/name/'stage2.log'
        assert sha(log) == evidence['sha256'], name
        assert f'PASS {name}' in log.read_text(encoding='utf-8'), name
    assert (root/'report/design_report.pdf').read_bytes().startswith(b'%PDF-')
    assert (root/'skill/README.md').is_file()
    skill = json.loads((root/'skill/validation/checks/results.json').read_text(encoding='utf-8'))
    assert skill['status'] == 'pass' and skill['tests'] == 79
    assert sha(root/'skill/amd-fpga-embedded-dev-workflow/SKILL.md') == skill['structure']['entry_sha256']
    assert all(command['returncode'] == 0 for command in skill['commands'])
    for command in skill['commands']:
        assert sha(root/'skill/validation/checks'/command['log']) == command['log_sha256']
    evidence = json.loads((root/'data/hardware/evidence_manifest.json').read_text(encoding='utf-8'))
    for item in evidence['files']:
        path = root/item['path']
        assert path.stat().st_size == item['bytes'] and sha(path) == item['sha256'], path
    with (root/'data/hardware/dds_measurements.csv').open(encoding='utf-8-sig') as stream:
        measurements = list(csv.DictReader(stream))
    assert len(measurements) == 12
    for row in measurements:
        difference = Decimal(row['measured_frequency_hz']) - Decimal(row['set_frequency_hz'])
        assert abs(difference - Decimal(row['frequency_error_hz'])) < Decimal('0.00001')
        percent = difference / Decimal(row['set_frequency_hz']) * 100
        assert abs(percent - Decimal(row['frequency_error_percent'])) < Decimal('0.00001')
    assert len(list((root/'data/hardware/dds').glob('*.png'))) == 12
    hardware = json.loads((root/'data/hardware_results.json').read_text(encoding='utf-8'))
    for experiment in hardware['experiments']:
        for branch in ('traditional', 'ai'):
            result = experiment[branch]
            assert result['bits'] == result['captured'] * 256
            assert 0 <= result['errors'] <= result['bits']
    resources = json.loads((root/'data/detector_comparison/resource_receipt.json').read_text(encoding='utf-8'))
    for name, digest in resources['source_files'].items():
        assert sha(root/name) == digest, name
    summary = json.loads((root/'data/detector_comparison/summary.json').read_text(encoding='utf-8'))
    assert summary['synthetic_total_cells'] == 303 and summary['synthetic_total_bits'] == 77568
    assert sum(group['bits'] for group in summary['groups']) == 77568


def verify(root):
    check(root)
    manifest = json.loads((root/MANIFEST).read_text(encoding='utf-8'))
    actual = files(root)
    assert set(actual) == set(manifest['files']), 'File set differs'
    for name, digest in manifest['files'].items():
        assert sha(actual[name]) == digest, name
    print(f'PASS submission: {len(actual)} hashed files; exact root layout; names; 210 source mappings; original hardware receipt; 24 simulation logs; one bitstream')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--refresh-manifest', action='store_true')
    args = parser.parse_args()
    root = args.verify.resolve() if args.verify else ROOT
    if args.refresh_manifest:
        check(root)
        (root/MANIFEST).write_text(json.dumps(dict(
            model='00070001',
            project_hardware_status='board_and_instrument_results_included',
            hardware_evidence='data/hardware_results.json',
            files={name: sha(p) for name, p in sorted(files(root).items())}), indent=2)+'\n', encoding='utf-8')
    verify(root)
