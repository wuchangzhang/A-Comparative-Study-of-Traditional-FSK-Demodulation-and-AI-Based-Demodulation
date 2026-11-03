"""Run host checks and retain each command's output in the project build folder."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
checks = [
    ('gui_busy_check', ['build/scripts/check_gui_busy.py']),
    ('burst_host', ['build/scripts/check_burst_host.py']),
    ('host_decode', ['build/scripts/check_uart_capture.py']),
    ('gui_verify', ['build/scripts/check_gui.py']),
    ('serial_verify', ['build/scripts/check_serial_host.py']),
]
for name, args in checks:
    result = subprocess.run([sys.executable] + args, cwd=str(ROOT),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=60)
    output = result.stdout.decode('utf-8', errors='replace')
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'sim' / 'host_results' / (name + '.log')).write_text(output, encoding='utf-8')
    print(output, end='')
    if result.returncode:
        raise SystemExit(result.returncode)
