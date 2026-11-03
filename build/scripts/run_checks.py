import os
import shutil
import subprocess
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get('VIVADO_BIN', r'E:\AMDDesignTools\2026.1\Vivado\bin'))
tests = sys.argv[1:] or ['tb_frame', 'tb_parameters', 'tb_knob', 'tb_uart_system', 'tb_statistics', 'tb_samples', 'tb_telemetry', 'tb_dac', 'tb_arithmetic', 'tb_history', 'tb_noise', 'tb_jammer', 'tb_test_control', 'tb_frame_gate', 'tb_phase_reset', 'tb_ad7606_spi', 'tb_ai_mlp', 'tb_ai_features', 'tb_fsk_receiver', 'tb_fsk_lowamp', 'tb_capture_jammer', 'tb_dc_tail', 'tb_burst_tx', 'tb_burst_receiver']
sources = [ROOT/'src/rtl'/'control_pkg.sv'] + sorted(p for p in (ROOT/'src/rtl').glob('*') if p.suffix in ('.sv', '.v') and p.name != 'control_pkg.sv')
for test in tests:
    folder = ROOT/'sim'/'results'/test
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT/'src/rtl'/'gaussian_q8.mem', folder/'gaussian_q8.mem')
    shutil.copyfile(ROOT/'src/rtl'/'fcw_100ksps.mem', folder/'fcw_100ksps.mem')
    for name in ('rx_sine.mem', 'rx_steps.mem', 'ai_mlp.mem'):
        src = ROOT/'src/rtl'/name
        if src.exists():
            shutil.copyfile(src, folder/name)
    for name in ('ai_golden.txt', 'ai_feature_golden.txt'):
        src = ROOT/'sim'/name
        if src.exists():
            shutil.copyfile(src, folder/name)
    shutil.copyfile(ROOT/'sim'/'frames.mem', folder/'frames.mem')
    primitive_sources = [str(BIN.parent/'data'/'verilog'/'src'/'glbl.v')] if test == 'tb_phase_reset' else []
    primitive_tops = ['work.glbl'] if test == 'tb_phase_reset' else []
    commands = [
        [str(BIN/'xvlog.bat'), '-sv'] + [str(p) for p in sources] + [str(ROOT/'sim'/(test+'.sv'))] + primitive_sources,
        [str(BIN/'xelab.bat'), '-debug', 'typical', '--timescale', '1ns/1ps', '-s', test, 'work.'+test, '-L', 'unisims_ver'] + primitive_tops,
        [str(BIN/'xsim.bat'), test, '-runall', '-wdb', test+'.wdb'],
    ]
    output = ''
    for index, command in enumerate(commands):
        result = subprocess.run(command, cwd=str(folder), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = result.stdout.decode('utf-8', errors='replace')
        (folder/('stage%d.log' % index)).write_text(text, encoding='utf-8')
        output += text
        if result.returncode:
            print(text); raise SystemExit('%s stage %d failed' % (test, index))
    if 'PASS '+test not in output or 'Fatal:' in output:
        print(output); raise SystemExit(test+' did not pass')
    for name in ('uart_tx.hex', 'rtl_statistics.csv', 'burst_adc.txt'):
        generated = folder/name
        if generated.exists():
            target = ROOT/'data'/'simulation'/test/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(generated, target)
    print(next(line for line in output.splitlines() if 'PASS '+test in line))
(ROOT/'sim'/'results'/'passed.txt').write_text('\n'.join(tests), encoding='ascii')
