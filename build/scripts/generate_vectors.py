"""Deterministic build assets: Gaussian inverse-CDF ROM and independent frames."""
import sys
from pathlib import Path
from statistics import NormalDist
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/host'))
from reference import frame_bytes

values = [round(NormalDist().inv_cdf((i + .5) / 256) * 256) for i in range(256)]
for directory in (ROOT / 'src/rtl', ROOT / 'build'):
    directory.mkdir(exist_ok=True)
    (directory / 'gaussian_q8.mem').write_text(''.join('%04x\n' % (v & 0xffff) for v in values), encoding='ascii')
(ROOT / 'sim' / 'frames.mem').write_text(''.join('%02x\n' % b for n in range(3) for b in frame_bytes(n)), encoding='ascii')
fcws = [(hz * (1 << 32) + 50_000) // 100_000 for hz in range(2101)]
(ROOT / 'src/rtl' / 'fcw_100ksps.mem').write_text(''.join('%08x\n' % value for value in fcws), encoding='ascii')
print('Gaussian LUT: mean=%.6f, standard deviation=%.6f DAC codes at scale=256' %
      (sum(values)/256/256, (sum(v*v for v in values)/256)**.5/256))
