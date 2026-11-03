"""Collect the burst experiment's evidence and artifact hashes."""
import hashlib
import json
import os
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
BUILD=Path(os.environ.get('DDS_BUILD_DIR', ROOT/'build/rebuild_v7')).resolve()
EXPERIMENT=ROOT/'data/burst_experiment'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hierarchy(path):
    rows={}
    for line in path.read_text().splitlines():
        values=[v.strip() for v in line.split('|')]
        if len(values)==12 and values[1] in ('ego1_control_top','u_receiver','u_ai','u_mac'):
            rows[values[1]]=dict(zip(('lut','logic_lut','lutram','srl','ff','ramb36','ramb18','dsp'),
                                     map(int,values[3:11])))
    return rows


def main():
    if BUILD in ((ROOT/'build/burst_v7').resolve(), (ROOT/'board/burst_v7').resolve()):
        raise RuntimeError('Set DDS_BUILD_DIR to the rebuild directory; preserve the delivered build receipt')
    frames=json.loads((EXPERIMENT/'frames.json').read_text())
    timing=(BUILD/'timing_summary.rpt').read_text()
    m=re.search(r'\n\s*sys_clk_100m\s+([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)',timing)
    if not m:
        raise RuntimeError('Missing routed timing')
    slacks=dict(zip(('wns_ns','tns_ns','whs_ns','ths_ns'),map(float,m.groups())))
    bit=BUILD/'ego1_control_v3_jammer.bit'
    if not bit.exists() or slacks['wns_ns']<0 or slacks['whs_ns']<0:
        raise RuntimeError('No timing-clean bitstream')
    drc=(BUILD/'drc.rpt').read_text()
    errors=[line for line in drc.splitlines() if re.search(r'\|\s*(Error|Critical Warning)\s*\|',line)]
    if errors:
        raise RuntimeError('Unresolved DRC errors/critical warnings')
    tests={}
    expected=['tb_frame','tb_parameters','tb_knob','tb_uart_system','tb_statistics',
              'tb_samples','tb_telemetry','tb_dac','tb_arithmetic','tb_history','tb_noise',
              'tb_jammer','tb_test_control','tb_frame_gate','tb_phase_reset','tb_ad7606_spi',
              'tb_ai_mlp','tb_ai_features','tb_fsk_receiver','tb_fsk_lowamp',
              'tb_capture_jammer','tb_dc_tail','tb_burst_tx','tb_burst_receiver']
    for name in expected:
        path=ROOT/'sim/results'/name/'stage2.log'
        log=path.read_text(encoding='utf-8',errors='replace')
        if f'PASS {name}' not in log or 'Fatal:' in log:
            raise RuntimeError(f'Missing passing simulation: {name}')
        tests[name]=dict(sha256=digest(path),result=next(s for s in log.splitlines() if f'PASS {name}' in s))
    current=hierarchy(BUILD/'hierarchical_utilization.rpt')
    source_files=[]
    for folder in ('src/rtl','board/constraints','src/host','build/scripts','sim'):
        source_files.extend(p for p in (ROOT/folder).iterdir() if p.is_file())
    source_files.extend((ROOT/'src/ai/model.py',ROOT/'src/ai/reference.py',ROOT/'src/ai/model.npz'))
    source_files.append(ROOT/'report/burst_payload_v7.md')
    result=dict(model='00070001',evidence_scope='digital_build_and_simulation',
        scope='Payload burst; clean preamble/sync; existing full-window traditional baseline',
        frame_test={k:sum(r[k] for r in frames) for k in ('attempted','captured','bits','traditional','ai','majority',
                   'traditional_crc_failures','ai_crc_failures')},
        limitation='Quarter-window majority also succeeds; continuous-channel AI regression is documented',
        timing=slacks,drc_errors=0,drc_critical_warnings=0,
        resources=current,
        bitstream=str(bit),bitstream_sha256=digest(bit),
        tests=tests,sources={str(p.relative_to(ROOT)):digest(p) for p in sorted(source_files)})
    (BUILD/'validation.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('frame_test','timing','resources',
                                          'bitstream_sha256')},indent=2))


if __name__=='__main__':
    main()
