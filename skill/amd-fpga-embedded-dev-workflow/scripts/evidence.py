"""Streaming file manifests and archive verification; no EDA execution or signoff."""
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile

import workflow
import receive_check


def packed(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':')).encode() + b'\n'


def relative_name(name):
    pure = PurePosixPath(name.replace('\\', '/'))
    if pure.is_absolute() or '..' in pure.parts or any(':' in p for p in pure.parts):
        raise workflow.InputError('Unsafe relative path: ' + name)
    return pure.as_posix()


def files(root, selections, exclusions, manifest):
    seen = set()
    for name in selections:
        selected = root / relative_name(name)
        if not selected.exists():
            raise workflow.InputError('Missing selection: ' + name)
        pending = [selected]
        while pending:
            path = pending.pop()
            if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
                raise workflow.InputError('Links are not supported: ' + str(path))
            path = workflow.inside(path, root)
            rel = path.relative_to(root).as_posix()
            if path == manifest or any(fnmatch.fnmatchcase(rel, p) for p in exclusions):
                continue
            if path.is_dir():
                pending.extend(reversed(sorted(path.iterdir())))
            elif path.is_file() and rel not in seen:
                seen.add(rel)
                yield path, rel


def make_manifest(root, output, selections, exclusions=()):
    root = Path(root).resolve(strict=True)
    output = Path(output).resolve()
    if not root.is_dir():
        raise workflow.InputError('Root must be a directory')
    selections = sorted(set(relative_name(n) for n in selections))
    exclusions = sorted(set(exclusions))
    if not selections:
        raise workflow.InputError('At least one explicit file/directory selection is required')
    self_selected = output.is_relative_to(root) and any(output.is_relative_to(root / n) for n in selections)
    header = {'kind': 'header', 'schema_version': 1, 'scope': 'selected_files_only',
              'selections': selections, 'exclusions': exclusions,
              'self_excluded': output.relative_to(root).as_posix() if self_selected else None,
              'not_dependency_or_design_acceptance': True}
    count = size = 0
    binding = hashlib.sha256()
    with output.open('xb') as stream:
        data = packed(header)
        stream.write(data)
        binding.update(data)
        for path, name in files(root, selections, exclusions, output):
            before = path.stat()
            digest = workflow.digest(path)
            after = path.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise workflow.InputError('File changed during hashing: ' + name)
            row = {'kind': 'file', 'path': name, 'bytes': after.st_size, 'sha256': digest}
            data = packed(row)
            stream.write(data)
            binding.update(data)
            count += 1
            size += after.st_size
        if not count:
            raise workflow.InputError('Empty selection; partial manifest is not valid')
        stream.write(packed({'kind': 'footer', 'file_count': count, 'bytes': size,
                             'records_sha256': binding.hexdigest()}))
    return {'files': count, 'bytes': size, 'manifest_sha256': workflow.digest(output),
            'acceptance': 'not_evaluated'}


def rows(manifest):
    binding = hashlib.sha256()
    seen = set()
    count = size = 0
    with Path(manifest).open('rb') as stream:
        first = stream.readline()
        header = json.loads(first)
        if header.get('kind') != 'header' or header.get('schema_version') != 1:
            raise workflow.InputError('Unsupported manifest header')
        binding.update(first)
        yield header
        for line in stream:
            row = json.loads(line)
            if row.get('kind') == 'footer':
                if (row['file_count'], row['bytes'], row['records_sha256']) != (count, size, binding.hexdigest()):
                    raise workflow.InputError('Manifest footer mismatch')
                if stream.read(1):
                    raise workflow.InputError('Unexpected data after footer')
                return
            if row.get('kind') != 'file' or not isinstance(row.get('path'), str):
                raise workflow.InputError('Invalid file record')
            name = relative_name(row['path'])
            if name != row['path'] or name in seen:
                raise workflow.InputError('Duplicate/noncanonical manifest path')
            seen.add(name)
            count += 1
            size += row['bytes']
            binding.update(line)
            yield row
    raise workflow.InputError('Missing footer; interrupted manifests cannot pass')


def verify(root, manifest):
    root = Path(root).resolve(strict=True)
    count = 0
    for row in rows(manifest):
        if row['kind'] == 'header':
            continue
        path = workflow.inside(root / row['path'], root)
        if not path.is_file() or path.stat().st_size != row['bytes'] or workflow.digest(path) != row['sha256']:
            raise workflow.InputError('File mismatch: ' + row['path'])
        count += 1
    return {'verified_files': count, 'scope': 'listed_files_only', 'design_acceptance': 'not_evaluated'}


def compare(before, after, allowed=()):
    def load(path):
        iterator = rows(path)
        header = next(iterator)
        entries = {r['path']: (r['bytes'], r['sha256']) for r in iterator}
        return header, entries
    old_header, old = load(before)
    new_header, new = load(after)
    policy_keys = ('selections', 'exclusions', 'self_excluded')
    if any(old_header[k] != new_header[k] for k in policy_keys):
        raise workflow.InputError('Selection policies differ; input/output manifests are not comparable')
    added = sorted(new.keys() - old.keys())
    removed = sorted(old.keys() - new.keys())
    changed = sorted(p for p in old.keys() & new.keys() if old[p] != new[p])
    allowed = {relative_name(p) for p in allowed}
    unexpected = sorted(set(changed) - allowed)
    return {'status': 'pass' if not (added or removed or unexpected) else 'blocked',
            'exit_code': 0 if not (added or removed or unexpected) else 2,
            'added': added, 'removed': removed, 'changed': changed,
            'unexpected_changes': unexpected, 'allowed_change_paths': sorted(allowed),
            'scope': 'selected_files_only; not a simulation or implementation admission'}


def verify_zip(archive_path, manifest, prefix=''):
    # Validate names/links without extraction; archive content is always untrusted.
    receive_check.names_from(Path(archive_path), 1000000)
    prefix = relative_name(prefix) if prefix else ''
    prefix = prefix.rstrip('/') + '/' if prefix and prefix != '.' else ''
    count = 0
    with zipfile.ZipFile(archive_path) as archive:
        for row in rows(manifest):
            if row['kind'] == 'header':
                continue
            name = prefix + row['path']
            try:
                entry = archive.getinfo(name)
            except KeyError as exc:
                raise workflow.InputError('Archive missing: ' + name) from exc
            if entry.file_size != row['bytes']:
                raise workflow.InputError('Archive size mismatch: ' + name)
            digest = hashlib.sha256()
            with archive.open(entry) as stream:
                for block in iter(lambda: stream.read(1048576), b''):
                    digest.update(block)
            if digest.hexdigest() != row['sha256']:
                raise workflow.InputError('Archive hash mismatch: ' + name)
            count += 1
    return {'verified_archive_files': count, 'scope': 'listed_members_only',
            'all_members_crc_checked': False, 'design_acceptance': 'not_evaluated'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    create = commands.add_parser('manifest')
    create.add_argument('root')
    create.add_argument('--out', required=True)
    create.add_argument('--select', action='append', required=True)
    create.add_argument('--exclude', action='append', default=[])
    check = commands.add_parser('verify')
    check.add_argument('root')
    check.add_argument('manifest')
    diff = commands.add_parser('compare')
    diff.add_argument('before')
    diff.add_argument('after')
    diff.add_argument('--allow-change', action='append', default=[])
    archive = commands.add_parser('verify-zip')
    archive.add_argument('archive')
    archive.add_argument('manifest')
    archive.add_argument('--prefix', default='')
    args = parser.parse_args()
    try:
        if args.action == 'manifest':
            result = make_manifest(args.root, args.out, args.select, args.exclude)
        elif args.action == 'verify':
            result = verify(args.root, args.manifest)
        elif args.action == 'compare':
            result = compare(args.before, args.after, args.allow_change)
        else:
            result = verify_zip(args.archive, args.manifest, args.prefix)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return result.get('exit_code', 0)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as exc:
        print(json.dumps({'status': 'blocked', 'exit_code': 2, 'error': str(exc)}, ensure_ascii=False))
        return 2


if __name__ == '__main__':
    sys.exit(main())
