"""Read-only directory/ZIP receipt check; never extracts files or launches tools."""
import argparse
from collections import defaultdict
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile


class ReceiptError(ValueError):
    pass


def names_from(path, limit):
    if path.is_file():
        if path.suffix.lower() != '.zip':
            raise ReceiptError('Provide an extracted directory or ZIP; other archive formats need explicit extraction')
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > limit:
                raise ReceiptError('Entry limit exceeded; choose a smaller explicit input root')
            names = []
            seen = set()
            for entry in entries:
                name = entry.filename.replace('\\', '/')
                pure = PurePosixPath(name)
                if pure.is_absolute() or '..' in pure.parts or any(':' in part for part in pure.parts):
                    raise ReceiptError('Unsafe archive member: ' + name)
                if stat.S_ISLNK(entry.external_attr >> 16):
                    raise ReceiptError('Archive links are not supported: ' + name)
                if not entry.is_dir():
                    if name.casefold() in seen:
                        raise ReceiptError('Duplicate archive member: ' + name)
                    seen.add(name.casefold())
                    names.append(pure.as_posix())
            return names, 'zip'
    if not path.is_dir():
        raise ReceiptError('Input path does not exist or is not a directory/ZIP')
    names = []
    count = 0
    # Explicit stack avoids following directory symlinks/junctions.
    pending = [path]
    while pending:
        folder = pending.pop()
        for item in sorted(folder.iterdir()):
            count += 1
            if count > limit:
                raise ReceiptError('Entry limit exceeded; choose a smaller explicit input root')
            if item.is_symlink() or (hasattr(item, 'is_junction') and item.is_junction()):
                continue
            if item.is_dir():
                if item.name not in {'.git', '__pycache__', '.venv'}:
                    pending.append(item)
            elif item.is_file():
                names.append(item.relative_to(path).as_posix())
    return names, 'directory'


def project_name(name):
    # Skill fixtures and copied historical results are not project inputs.
    parts = [part.casefold() for part in PurePosixPath(name).parts]
    excluded = {'skill', 'skills', 'skill_snapshot', 'historical_results_from_submission',
                'evidence', 'validation', 'sim_results', 'results'}
    return not any(part in excluded or part.startswith('preflight_evidence')
                   or part == 'amd-fpga-embedded-dev-workflow' for part in parts)


def inspect(path, limit=20000):
    path = Path(path).resolve()
    result = {'input_path': str(path), 'status': 'blocked', 'exit_code': 2,
              'complete': False, 'scope': 'receipt_only_not_dependency_or_hash_acceptance',
              'tool_probe_allowed': False, 'hardware_programmed': False,
              'missing_items': [], 'questions': [], 'candidates': {}}
    try:
        names, kind = names_from(path, limit)
    except (OSError, ReceiptError, zipfile.BadZipFile) as exc:
        result.update(reason='input_unreadable', error=str(exc))
        result['questions'] = ['Provide the correct readable archive or extracted run path.']
        return result
    result.update(input_kind=kind, file_count=len(names))
    if not names:
        result.update(reason='empty_input', missing_items=['complete baseline run archive'])
        result['questions'] = ['This input is empty. Provide the original run ZIP plus its handoff supplement, or the complete extracted run directory.']
        return result
    guides = [n for n in names if PurePosixPath(n).name.casefold() == 'reproduction.md'
              and project_name(n)]
    # A top-level entry is authoritative; resume/history guides do not override it.
    if 'reproduction.md' in names:
        guides = ['reproduction.md']
    elif 'README.md' in names:
        guides = ['README.md']
    else:
        if not guides:
            guides = [n for n in names if PurePosixPath(n).name == 'README.md' and project_name(n)]
        guides = [n for n in guides if not any(
            PurePosixPath(n).is_relative_to(PurePosixPath(other).parent)
            and other != n for other in guides)]
    result['guide_candidates'] = guides
    if len(guides) != 1:
        result.update(reason='missing_guide' if not guides else 'ambiguous_roots')
        result['missing_items'] = ['one selected project root with reproduction.md or README.md']
        result['questions'] = ['Provide/select the complete extracted run root; nested ZIPs are not extracted by this checker.']
        return result
    root = PurePosixPath(guides[0]).parent
    selected = [str(PurePosixPath(n).relative_to(root)) for n in names
                if PurePosixPath(n).is_relative_to(root)]
    candidates = defaultdict(list)
    for name in selected:
        pure = PurePosixPath(name)
        if ('manifest' in pure.name.casefold() or 'sha256' in pure.name.casefold()) and not any(
                p.casefold() in {'skill', 'skills', 'skill_snapshot', 'validation', 'amd-fpga-embedded-dev-workflow'}
                or p.casefold().startswith('preflight_evidence') for p in pure.parts):
            candidates['manifests'].append(name)
        if not project_name(name):
            continue
        suffix = pure.suffix.casefold()
        parts = [p.casefold() for p in pure.parts]
        if suffix in {'.v', '.sv', '.vhd', '.vhdl'}:
            is_test = pure.stem.casefold().startswith(('tb_', 'test_')) or any(p in {'sim', 'test', 'tests', 'testbench'} for p in parts)
            candidates['testbenches' if is_test else 'rtl'].append(name)
        if suffix == '.xdc':
            candidates['xdc'].append(name)
        if suffix in {'.tcl', '.py', '.ps1', '.cmd', '.bat'}:
            candidates['scripts'].append(name)
    required = ('rtl', 'testbenches', 'xdc', 'scripts', 'manifests')
    result.update(selected_root=str(root), candidates=dict(candidates),
                  missing_items=[role for role in required if not candidates[role]])
    if result['missing_items']:
        result.update(reason='incomplete_run')
        result['questions'] = ['Provide the complete baseline run; skill-only, output-only and handoff-only packages cannot supply missing project inputs.']
        return result
    result.update(status='ready_for_review', exit_code=0, reason='candidate_inputs_present',
                  next_step='Inspect the selected root, canonical status, dependency closure and hashes before any tool probe. ZIP still requires safe extraction to a new directory.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--max-entries', type=int, default=20000)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.max_entries <= 0:
        parser.error('--max-entries must be positive')
    result = inspect(args.input, args.max_entries)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        with args.out.open('x', encoding='utf-8') as stream:
            stream.write(text + '\n')
    print(text)
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
