"""Deterministic 24-bit NCO tables for the fixed 50 kSPS receive profile."""
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def main():
    sine = [round(127 * math.sin(2 * math.pi * n / 256)) & 255 for n in range(256)]
    (ROOT / 'src/rtl/rx_sine.mem').write_text(''.join(f'{x:02x}\n' for x in sine), encoding='ascii')
    steps = [((round((1000 + d) * 2**24 / 50000) << 24) |
              round((2000 + d) * 2**24 / 50000)) for d in range(-100, 101, 10)]
    (ROOT / 'src/rtl/rx_steps.mem').write_text(''.join(f'{x:012x}\n' for x in steps), encoding='ascii')

if __name__ == '__main__':
    main()
