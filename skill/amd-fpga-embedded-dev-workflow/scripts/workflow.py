"""Offline workflow helpers. No third-party dependencies or implicit FPGA actions."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
from datetime import datetime, timezone


class InputError(ValueError):
    pass


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True,
                                     separators=(",", ":")).encode()).hexdigest()


def read_json(path):
    with Path(path).open(encoding="utf-8-sig") as stream:
        return json.load(stream)


def write_json(path, value):
    # Exclusive creation keeps previous evidence intact.
    with Path(path).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def inside(path, root):
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise InputError(f"Path escapes workspace: {path}")
    return resolved


def parse_version(log_path, process_returncode, required_release='2026.1'):
    raw = Path(log_path).read_bytes()
    encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    text = raw.decode(encoding)
    releases = set(re.findall(r'\bvivado\s+v(?:\.)?(\d{4}\.\d+)\b', text, re.I))
    builds = {}
    for field, pattern in (('sw', r'\bSW Build\s+(\d+)'),
                           ('ip', r'\bIP Build\s+(\d+)'),
                           ('shared_data', r'\bSharedData Build\s+(\d+)')):
        values = set(re.findall(pattern, text, re.I))
        builds[field] = next(iter(values)) if len(values) == 1 else None
    actual = next(iter(releases)) if len(releases) == 1 else None
    valid = actual == required_release and all(builds.values())
    error_seen = bool(re.search(r'(?im)^\s*(?:ERROR|FATAL)\s*:', text))
    confirmed = valid and not error_seen and process_returncode in (0, 1)
    return {'status': 'identity_confirmed' if confirmed else 'blocked',
            'exit_code': 0 if confirmed else 3, 'required_release': required_release,
            'actual_release': actual, 'builds': builds,
            'process_returncode': process_returncode,
            'returncode_anomaly': process_returncode != 0,
            'raw_log_sha256': digest(log_path), 'log_encoding': encoding, 'error_seen': error_seen,
            'startup_validated': False, 'synthesis_license_validated': False,
            'note': 'Banner identity only; never authorizes S04/S05 or proves startup/license readiness.'}


def inventory(root):
    root = Path(root).resolve(strict=True)
    if not root.is_dir():
        raise InputError("Workspace must be a directory")
    suffixes = {".v", ".sv", ".vhd", ".vhdl", ".xdc", ".xpr", ".tcl",
                ".mem", ".coe", ".xci", ".bd", ".hex", ".py", ".xsa"}
    found = []
    for folder, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in {".git", "__pycache__", ".venv"}
                         and not Path(folder, d).is_symlink())
        for name in sorted(files):
            path = Path(folder, name)
            if path.suffix.lower() in suffixes and not path.is_symlink():
                found.append(path.relative_to(root).as_posix())
    return {"workspace_root": str(root), "candidates": found,
            "complete": False, "note": "Discovery only; top, part and dependencies need review."}


def snapshot(spec_path, output):
    spec = read_json(spec_path)
    root = Path(spec["workspace_root"]).resolve(strict=True)
    config = spec.get("configuration")
    required = ("top", "part", "tool_version", "compile_order", "defines",
                "include_dirs", "parameters", "test_scope")
    if not isinstance(config, dict) or any(key not in config for key in required):
        raise InputError(f"configuration requires: {', '.join(required)}")
    if any(not isinstance(config[key], str) or not config[key].strip()
           for key in ("top", "part", "tool_version")):
        raise InputError("top, part and tool_version must be nonempty strings")
    for key in ("compile_order", "defines", "include_dirs", "test_scope"):
        if not isinstance(config[key], list) or any(not isinstance(v, str) or not v
                                                    for v in config[key]):
            raise InputError(f"{key} must be a list of nonempty strings")
    if not config["test_scope"] or not isinstance(config["parameters"], dict):
        raise InputError("test_scope must be nonempty and parameters must be an object")
    if config["part"].lower().startswith("xc7a35t") and config["tool_version"] != "2026.1":
        raise InputError("EGO1/XC7A35T requires Vivado 2026.1")
    patterns = spec.get("files")
    if not isinstance(patterns, list) or not patterns or any(
            not isinstance(p, str) or not p for p in patterns):
        raise InputError("files must be a nonempty list of relative files/directories")
    paths = set()
    watched_dirs = []
    for name in patterns:
        path = inside(root / name, root)
        if path.is_dir():
            watched_dirs.append(path.relative_to(root).as_posix())
            for item in path.rglob("*"):
                item = inside(item, root)
                if item.is_file():
                    paths.add(item)
        elif path.is_file():
            paths.add(path)
        else:
            raise InputError(f"Missing input: {name}")
    if not paths:
        raise InputError("No input files")
    # Configuration itself is hashed. All compile inputs must be included as files.
    for name in config["compile_order"]:
        if inside(root / name, root) not in paths:
            raise InputError(f"compile_order input not in files: {name}")
    output = Path(output).resolve()
    if any(output.is_relative_to(root / name) for name in watched_dirs):
        raise InputError("Output cannot be inside a tracked directory")
    if any(p == output or p.is_relative_to(output) for p in paths):
        raise InputError("Output overlaps inputs")
    output.mkdir(parents=True, exist_ok=False)
    entries = []
    for source in sorted(paths):
        relative = source.relative_to(root).as_posix()
        before = digest(source)
        destination = output / "inputs" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        if digest(destination) != before or digest(source) != before:
            raise InputError(f"Input changed while snapshotting: {relative}")
        entries.append({"path": relative, "sha256": before})
    payload = {"schema_version": 1, "workspace_root": str(root),
               "configuration": config, "files": entries, "watched_dirs": watched_dirs,
               "dependency_completeness": "agent_review_required"}
    manifest = {"payload": payload, "input_manifest_hash": canonical_hash(payload)}
    write_json(output / "manifest.json", manifest)
    verify(output / "manifest.json")
    return {"manifest": str(output / "manifest.json"),
            "input_manifest_hash": manifest["input_manifest_hash"], "file_count": len(entries),
            "acceptance": "not_evaluated"}


def verify(manifest_path):
    manifest_path = Path(manifest_path).resolve(strict=True)
    manifest = read_json(manifest_path)
    payload = manifest["payload"]
    if canonical_hash(payload) != manifest["input_manifest_hash"]:
        raise InputError("Manifest hash mismatch")
    root = Path(payload["workspace_root"]).resolve(strict=True)
    names = set()
    for item in payload["files"]:
        name = item["path"]
        names.add(name)
        for path in (inside(root / name, root),
                     inside(manifest_path.parent / "inputs" / name, manifest_path.parent)):
            if not path.is_file() or digest(path) != item["sha256"]:
                raise InputError(f"Missing or changed input: {path}")
    for name in payload.get("watched_dirs", []):
        folder = inside(root / name, root)
        current = {inside(p, root).relative_to(root).as_posix()
                   for p in folder.rglob("*") if p.is_file()}
        expected = {p for p in names if Path(p).is_relative_to(Path(name))}
        if current != expected:
            raise InputError(f"Tracked directory membership changed: {name}")
    return {"input_manifest_hash": manifest["input_manifest_hash"], "verified": True}


def run_command(manifest_path, command_path, output):
    binding = verify(manifest_path)
    command = read_json(command_path)
    argv = command.get("argv")
    timeout = command.get("timeout_seconds")
    if not isinstance(argv, list) or not argv or any(not isinstance(a, str) for a in argv):
        raise InputError("argv must be a nonempty list of strings")
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise InputError("timeout_seconds must be finite and positive")
    root = Path(read_json(manifest_path)["payload"]["workspace_root"])
    cwd = inside(root / command.get("cwd", "."), root)
    if not cwd.is_dir():
        raise InputError("Command cwd must exist")
    output = Path(output).resolve()
    tracked = read_json(manifest_path)["payload"]
    if any(output.is_relative_to(root / name) for name in tracked.get("watched_dirs", [])):
        raise InputError("Command output cannot be in tracked inputs")
    output.mkdir(parents=True, exist_ok=False)
    result = {"scope": "command_execution_only", "acceptance": "not_evaluated",
              "command": command, **binding, "started_at": datetime.now(timezone.utc).isoformat(),
              "status": "failed", "exit_code": 6, "process_returncode": None,
              "job_id": None, "error": None}
    with (output / "stdout.log").open("wb") as stdout, (output / "stderr.log").open("wb") as stderr:
        try:
            options = {"start_new_session": True} if os.name != "nt" else {}
            process = subprocess.Popen(argv, cwd=cwd, stdout=stdout, stderr=stderr,
                                       shell=False, **options)
            result["pid"] = process.pid
            try:
                result["process_returncode"] = process.wait(timeout=timeout)
                result["exit_code"] = 0 if process.returncode == 0 else 4
                result["status"] = "succeeded" if process.returncode == 0 else "failed"
            except subprocess.TimeoutExpired:
                # Conservatively report unknown descendant state after best-effort cleanup.
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                   stdout=stderr, stderr=stderr, timeout=10, check=False)
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
                result["error"] = "Timeout; cleanup attempted; descendant state not certified. Do not retry automatically."
        except (OSError, subprocess.SubprocessError) as exc:
            result["error"] = str(exc)
    try:
        verify(manifest_path)
    except (InputError, OSError, KeyError, ValueError) as exc:
        result.update(status="blocked", exit_code=2, error=str(exc))
    result["finished_at"] = datetime.now(timezone.utc).isoformat()
    result["artifacts"] = [{"path": str(output / name), "sha256": digest(output / name)}
                           for name in ("stdout.log", "stderr.log")]
    write_json(output / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="action", required=True)
    scan = subs.add_parser("inventory")
    scan.add_argument("workspace")
    version = subs.add_parser("parse-version")
    version.add_argument("log")
    version.add_argument("--returncode", type=int, required=True)
    version.add_argument("--required-release", default="2026.1")
    snap = subs.add_parser("snapshot")
    snap.add_argument("--spec", required=True)
    snap.add_argument("--out", required=True)
    check = subs.add_parser("verify")
    check.add_argument("manifest")
    run = subs.add_parser("run")
    run.add_argument("--manifest", required=True)
    run.add_argument("--command", required=True)
    run.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        if args.action == "inventory":
            result = inventory(args.workspace)
        elif args.action == "parse-version":
            result = parse_version(args.log, args.returncode, args.required_release)
        elif args.action == "snapshot":
            result = snapshot(args.spec, args.out)
        elif args.action == "verify":
            result = verify(args.manifest)
        else:
            result = run_command(args.manifest, args.command, args.out)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return result.get("exit_code", 0)
    except (InputError, KeyError, TypeError, ValueError, OSError) as exc:
        print(json.dumps({"status": "blocked", "exit_code": 2, "error": str(exc)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
