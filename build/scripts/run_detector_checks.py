"""Run focused XSim equivalence checks outside the release directory."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get('VIVADO_BIN', 'E:/AMDDesignTools/2026.1/Vivado/bin'))
OUT = ROOT / 'sim/detector_comparison'
work = Path(tempfile.mkdtemp(prefix='ego1_detector_xsim_'))
for name in ('rx_sine.mem', 'ai_mlp.mem'):
    shutil.copy2(ROOT / 'src/rtl' / name, work / name)
for name in ('rtl_samples.mem', 'rtl_vectors.txt'):
    shutil.copy2(ROOT / 'data/detector_comparison' / name, work / name)
sources = [ROOT / 'src/rtl/fsk_correlator.sv', ROOT / 'src/rtl/ai_mlp.sv', OUT / 'detector_benchmark.sv', OUT / 'tb_detector_benchmark.sv']
commands = [
    [str(BIN / 'xvlog.bat'), '-sv', *map(str, sources)],
    [str(BIN / 'xelab.bat'), '-debug', 'typical', '--timescale', '1ns/1ps', '-s', 'detector_benchmark', 'work.tb_detector_benchmark'],
    [str(BIN / 'xsim.bat'), 'detector_benchmark', '-runall'],
]
for index, command in enumerate(commands):
    result = subprocess.run(command, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = result.stdout.decode('utf-8', errors='replace')
    (OUT / f'check_stage{index}.log').write_text(text, encoding='utf-8')
    if result.returncode or 'Fatal:' in text:
        raise RuntimeError(text)
    if index == 2:
        assert 'PASS tb_detector_benchmark:' in text, text
        print(next(line for line in text.splitlines() if 'PASS tb_detector_benchmark:' in line))
print('Simulation workspace:', work)
