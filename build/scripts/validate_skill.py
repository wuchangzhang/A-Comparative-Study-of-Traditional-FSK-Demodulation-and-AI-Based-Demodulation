"""Reproduce offline Skill regression and file-evidence checks."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'skill/amd-fpga-embedded-dev-workflow'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--structural-validator', type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    records = []

    def run(name, argv):
        start = datetime.now(timezone.utc).isoformat()
        env = dict(os.environ, PYTHONIOENCODING='utf-8', PYTHONDONTWRITEBYTECODE='1')
        result = subprocess.run(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        path = out / (name + '.log')
        path.write_bytes(result.stdout)
        records.append(dict(name=name, argv=argv, cwd=str(ROOT), started_at=start,
                            finished_at=datetime.now(timezone.utc).isoformat(), returncode=result.returncode,
                            log=path.name, log_sha256=sha(path)))
        assert result.returncode == 0, path
        return result.stdout.decode('utf-8')

    py = [sys.executable, '-B', '-X', 'utf8']
    log = run('regression', py + ['-m', 'unittest', 'discover', '-s', str(CORE/'scripts'), '-p', 'test_*.py', '-v'])
    assert re.search(r'Ran 79 tests', log) and 'OK' in log.splitlines()
    if args.structural_validator:
        run('official_structure', py + [str(args.structural_validator.resolve()), str(CORE)])
    md = sorted(CORE.rglob('*.md'))
    links = []
    for path in md:
        for link in re.findall(r'\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
            if '://' in link or link.startswith('#'):
                continue
            target = (path.parent/link.split('#')[0]).resolve()
            assert target.exists(), (path, link)
            links.append(dict(source=path.relative_to(CORE).as_posix(), target=link))
    structure = dict(markdown_files=len(md), atom_contracts=len(list((CORE/'atoms').glob('*.md'))),
                     valid_local_links=len(links), links=links,
                     entry_sha256=sha(CORE/'SKILL.md'))
    assert structure['markdown_files'] == 21 and structure['atom_contracts'] == 14
    (out/'structure.json').write_text(json.dumps(structure, indent=2), encoding='utf-8')
    run('received_project', py + [str(CORE/'scripts/receive_check.py'), str(ROOT)])
    run('inventory', py + [str(CORE/'scripts/workflow.py'), 'inventory', str(ROOT)])
    evidence = str(CORE/'scripts/evidence.py')
    selections = ['src', 'board/constraints', 'board/burst_v7', 'skill/amd-fpga-embedded-dev-workflow']
    manifest = out/'selected_files.jsonl'
    options = [option for selection in selections for option in ('--select', selection)]
    run('manifest', py + [evidence, 'manifest', str(ROOT), '--out', str(manifest), *options])
    run('verify_directory', py + [evidence, 'verify', str(ROOT), str(manifest)])
    second = out/'selected_files_recheck.jsonl'
    run('manifest_recheck', py + [evidence, 'manifest', str(ROOT), '--out', str(second), *options])
    run('compare', py + [evidence, 'compare', str(manifest), str(second)])
    rows = [json.loads(line) for line in manifest.read_text(encoding='utf-8').splitlines()]
    members = [row['path'] for row in rows if row['kind'] == 'file']
    with tempfile.TemporaryDirectory(prefix='ego1_skill_') as temporary:
        archive = Path(temporary)/'selected.zip'
        with ZipFile(archive, 'w', ZIP_DEFLATED) as z:
            for member in members:
                z.write(ROOT/member, member)
        with ZipFile(archive) as z:
            assert z.testzip() is None
        run('verify_zip', py + [evidence, 'verify-zip', str(archive), str(manifest)])
    summary = dict(status='pass', scope='offline_skill_and_selected_file_integrity',
                   python=sys.version, tests=79, structure=structure,
                   selected_file_count=len(members), selected_bytes=rows[-1]['bytes'],
                   zip_crc='all selected members passed',
                   selected_manifest_sha256=sha(manifest), commands=records)
    (out/'results.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in summary.items() if k not in ('commands', 'structure')}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
