"""Offline receiver/front-end reference and bit-exact AI feature extraction.

No function in this file is used for online PC decisions on hardware. The same
integer feature arithmetic is implemented by fsk_correlator.sv.
"""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'host'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from protocol import crc16  # noqa: E402

FS = 50000
SPB = 500
SUBWINDOW = 125
SYNC = np.unpackbits(np.frombuffer(bytes.fromhex('1acffc1d'), dtype=np.uint8))
SINE = np.array([round(127 * np.sin(2 * np.pi * n / 256)) for n in range(256)], dtype=np.int64)
STEPS = {d: (round((1000+d)*2**24/FS), round((2000+d)*2**24/FS)) for d in range(-100, 101, 10)}
# Frequency offsets the SEARCH state probes, in Hz. Must match the RTL's
# SEARCH_OFFSETS: 10 Hz granularity is the finest the GUI exposes.
SEARCH_OFFSETS = (-100, -50, 0, 50, 100)
# A 500-point window is classified 1-like once more than half of it covers
# 1-bits, i.e. ~250 samples before the true transition; recentre on it.
BOUNDARY_BIAS = 100
# AI feature layout, shared bit-for-bit with rtl/fsk_correlator.sv and defined
# once in ai/model.py:
#   [0..7]  four 125-point sub-window powers per branch, >> SUB_FEATURE_SHIFT
#   [8..9]  the two coherent 500-point powers,           >> FULL_FEATURE_SHIFT
# The sub-window shift was 10 in the first jammer-aware model; at that shift
# 15% of the features clipped to 32767 (build/probe_dim.py), which erased the
# amplitude the MLP needs to separate a strong carrier from a strong jammer.
# 14 leaves headroom for the 4x gain steps (0.55% saturated at 12, 0% at 14)
# while keeping ~11 bits of resolution on a median of 717.
# The coherent powers are ~16x a sub-window power, so >>18 puts them on the same
# int16 scale (median 662) with no clipping at all.
from model import FEATURE_DIM, FULL_FEATURE_SHIFT, SUB_FEATURE_SHIFT  # noqa: E402


def prbs_payload():
    state = 1
    result = []
    for _ in range(256):
        result.append(state >> 14)
        state = ((state << 1) & 0x7fff) | (((state >> 14) ^ (state >> 13)) & 1)
    return np.asarray(result, dtype=np.uint8)


def protocol_bits(frame_id):
    payload = prbs_payload()
    body_bits = np.concatenate((np.unpackbits(np.asarray([frame_id >> 8, frame_id & 255], dtype=np.uint8)), payload))
    body = np.packbits(body_bits).tobytes()
    crc = np.unpackbits(np.asarray(list(crc16(body).to_bytes(2, 'big')), dtype=np.uint8))
    preamble = np.concatenate((np.zeros(16, dtype=np.uint8), np.ones(16, dtype=np.uint8),
                               np.asarray([i % 2 == 0 for i in range(32)], dtype=np.uint8)))
    return np.concatenate((preamble, SYNC, body_bits, crc)).astype(np.uint8)


def powers(x, frequencies):
    n = np.arange(x.shape[-1])
    ref = np.exp(-2j*np.pi*np.asarray(frequencies)[:, None]*n/FS)
    corr = x @ ref.T
    return corr.real**2 + corr.imag**2


def quantized_power(x, delta, dc, gain):
    """Full-window dual-frequency power in the exact RTL correlation scale.

    Matches fsk_correlator.sv: centered (signed 16-bit, dc removed), scaled by
    2^gain with saturation, then x=scaled>>4 (12-bit), multiply by 8-bit sine
    ROM (continuous NCO phase), accumulate, >>8, square and sum.
    """
    step0, step1 = STEPS[int(delta)]
    samples = np.asarray(x, dtype=np.int64)
    centered = samples-int(dc)
    scaled = (centered << gain) if gain >= 0 else (centered >> -gain)
    scaled = np.clip(scaled, -32768, 32767)
    quantized = scaled >> 4
    index = np.arange(samples.size, dtype=np.int64)
    phase0 = (index*step0) & 0xffffff
    phase1 = (index*step1) & 0xffffff
    result = []
    for phase in (phase0, phase1):
        idx = (phase >> 16) & 255
        cosine = SINE[(idx+64) & 255]
        sine = SINE[idx]
        c_sum = int(np.sum(quantized*cosine))
        s_sum = int(np.sum(quantized*sine))
        result.append((c_sum >> 8)**2 + (s_sum >> 8)**2)
    return np.asarray(result, dtype=np.int64)


def choose_gain(power_value):
    power_value = int(power_value)
    if power_value < 1_000_000_000:
        return 3
    if power_value < 4_000_000_000:
        return 2
    if power_value < 16_000_000_000:
        return 1
    if power_value <= 64_000_000_000:
        return 0
    if power_value <= 256_000_000_000:
        return -1
    if power_value <= 1_024_000_000_000:
        return -2
    return -3


def acquire(x):
    """Autonomous acquisition; TX boundaries and labels are never inputs."""
    x = np.asarray(x, dtype=np.int64)
    centered = x - np.mean(x[:500])
    # Frequency-agile SEARCH: mirrored from SEARCH_LEN/SEARCH_OFFSETS in the
    # RTL. A single fixed 1000/2000 Hz reference is what made jamming fatal -
    # with the carrier at 1000+delta, a jammer 50 Hz away lands in the same bin
    # and the two are inseparable, while a 500-point window nulls a carrier an
    # exact 100 Hz away entirely. Correlating at every candidate offset and
    # keeping the branch maximum restores full carrier power at any delta while
    # keeping the 100 Hz resolution that rejects an off-band jammer.
    windows = np.lib.stride_tricks.sliding_window_view(centered, 500)[::100]
    n_long = np.arange(500)
    probes = [1000+o for o in SEARCH_OFFSETS]+[2000+o for o in SEARCH_OFFSETS]
    ref_long = np.exp(-2j*np.pi*np.asarray(probes)[:, None]*n_long/FS)
    corr_long = windows @ ref_long.T
    p_long = corr_long.real**2 + corr_long.imag**2
    half = len(SEARCH_OFFSETS)
    p = np.stack((p_long[:, :half].max(axis=1), p_long[:, half:].max(axis=1)), axis=1)
    # Legacy 100-pt view of the same cursor, used only as a tonality reference:
    # a coherent tone's power grows with length^2 (25x here) while noise grows
    # with length (5x) and a baseband transient slower still, so requiring a
    # quarter of the matched-scale ratio rejects noise and DC transients.
    short = windows[:, :100]
    n_short = np.arange(100)
    ref_short = np.exp(-2j*np.pi*np.asarray([1000, 2000])[:, None]*n_short/FS)
    corr_short = short @ ref_short.T
    p_short = corr_short.real**2 + corr_short.imag**2
    tone_like = (p[:, 0]+p[:, 1]) >= 6.25*(p_short[:, 0]+p_short[:, 1])
    zeros = 0
    boundary = None
    quiet = 0
    # The RTL compares samples that were already >>4, i.e. 256x smaller in
    # power, against 102400; the model works on raw samples, hence 256x floor.
    for i, v in enumerate(p):
        if (v[0]+v[1] <= 102400*256) or not tone_like[i]:   # silence, noise, fade
            quiet += 1
            if quiet > 20:
                zeros = 0
                quiet = 0
            continue
        quiet = 0
        if v[0] > v[1]:
            zeros = min(zeros+1, 255)
        else:
            if zeros >= 50 and i*100+BOUNDARY_BIAS >= 6000:
                boundary = i*100 + BOUNDARY_BIAS
                break
            # Leaky run: a lone 1-like window (noise flicker or mixed boundary
            # window) costs four counts instead of wiping the chain.
            zeros = max(0, zeros-4)
    if boundary is None:
        raise RuntimeError('no preamble candidate')
    # The timing search window must fit inside the captured buffer.
    if boundary+8000+350+31*SPB+SPB > x.size:
        raise RuntimeError('timing window out of buffer')
    stable0 = centered[boundary-6000:boundary-1904]
    stable1 = centered[boundary+2000:boundary+6096]
    offsets = np.arange(-100, 101, 10)
    scores = powers(stable0, 1000+offsets) + powers(stable1, 2000+offsets)
    best = int(np.argmax(scores))
    delta = int(offsets[best])
    dc = int((np.sum(x[boundary-6000:boundary-1904]) + np.sum(x[boundary+2000:boundary+6096])) >> 13)
    centered = x-dc
    expected = np.array([1 if i % 2 == 0 else -1 for i in range(32)])

    def timing_score(shifts):
        indices = boundary+8000+np.asarray(shifts)[:, None, None]+np.arange(32)[None, :, None]*SPB+np.arange(SPB)
        energy = powers(centered[indices], [1000+delta, 2000+delta])
        return ((energy[:, :, 1]-energy[:, :, 0])*expected).sum(axis=1)

    # Measured over the jammer matrix: 90% of transitions land within +/-350
    # samples of the estimate. A wider sweep buys a few percent more but keeps
    # the receiver in the timing state long enough to starve the loss evaluator,
    # which is what reports missing frames to the GUI.
    shifts = np.arange(-350, 351, 25)
    coarse_scores = timing_score(shifts)
    best_shift = int(shifts[np.argmax(coarse_scores)])
    shifts = np.arange(best_shift-24, best_shift+25)
    fine_scores = timing_score(shifts)
    aligned = int(boundary+shifts[np.argmax(fine_scores)])
    # Candidate energy/timing gate, mirroring the RTL TIMING_SCORE gate.
    if scores[best] < 1_000_000 or max(np.max(coarse_scores), np.max(fine_scores)) <= 0:
        raise RuntimeError('candidate energy/timing gate')
    # Ensure the payload window (80+288 symbols) is fully inside the buffer.
    if aligned+80*SPB+288*SPB > x.size:
        raise RuntimeError('payload window out of buffer')
    # Gain from the quantized stable-segment correlation, matching RTL scale.
    quant0 = quantized_power(centered[boundary-6000:boundary-1904], delta, 0, 0)
    quant1 = quantized_power(centered[boundary+2000:boundary+6096], delta, 0, 0)
    gain = choose_gain((quant0.sum()+quant1.sum()) >> 1)
    return delta, dc, gain, aligned


def fixed_correlation(x, start, delta, dc, gain):
    """One 500-point replay with continuous NCO and four 125-point windows."""
    step0, step1 = STEPS[int(delta)]
    samples = np.asarray(x[start:start+SPB], dtype=np.int64)
    if samples.size != SPB:
        raise RuntimeError('short symbol window')
    centered = samples-int(dc)
    scaled = (centered << gain) if gain >= 0 else (centered >> -gain)
    scaled = np.clip(scaled, -32768, 32767)
    quantized = scaled >> 4
    index = np.arange(SPB, dtype=np.int64)
    phase0 = (index*step0) & 0xffffff
    phase1 = (index*step1) & 0xffffff
    refs = ((phase0 >> 16), (phase1 >> 16))
    powers_out = []
    full = []
    for frequency in range(2):
        phase = refs[frequency]
        cosine = SINE[(phase+64) & 255]
        sine = SINE[phase]
        c_values = quantized*cosine
        s_values = quantized*sine
        c_sum = int(np.sum(c_values))
        s_sum = int(np.sum(s_values))
        full.append((c_sum >> 8)**2 + (s_sum >> 8)**2)
        c_prefix = np.concatenate(([0], np.cumsum(c_values)))
        s_prefix = np.concatenate(([0], np.cumsum(s_values)))
        for window in range(4):
            lo, hi = window*SUBWINDOW, (window+1)*SUBWINDOW
            c = int(c_prefix[hi]-c_prefix[lo]) >> 8
            s = int(s_prefix[hi]-s_prefix[lo]) >> 8
            powers_out.append(c*c+s*s)
    # Reorder from per-frequency lists to [P0w0,P1w0,...,P0w3,P1w3].
    features = []
    for window in range(4):
        features.extend((powers_out[window], powers_out[4+window]))
    raw = np.asarray(features, dtype=np.int64)
    features = np.clip(np.right_shift(raw, SUB_FEATURE_SHIFT), 0, 32767).astype(np.int16)
    return np.asarray(full, dtype=np.int64), features, raw


def receive_symbols(x, count=288, force_delta=None, force_gain=None, full_window_features=False):
    delta, dc, gain, aligned = acquire(np.asarray(x, dtype=np.int64))
    if force_delta is not None:
        delta = int(force_delta)
    if force_gain is not None:
        gain = int(force_gain)
    sync_energy = []
    sync_bits = []
    for bit in range(32):
        full, _f, _r = fixed_correlation(x, aligned+48*SPB+bit*SPB, delta, dc, gain)
        sync_bits.append(int(full[1] > full[0]))
    if np.count_nonzero(np.asarray(sync_bits) != SYNC) > 2:
        raise RuntimeError('sync rejected')
    features = np.zeros((count, FEATURE_DIM), dtype=np.int16)
    traditional = np.zeros(count, dtype=np.uint8)
    full_powers = np.zeros((count, 2), dtype=np.int64)
    sub_powers = np.zeros((count, 8), dtype=np.int64)
    for bit in range(count):
        full, feature, raw = fixed_correlation(x, aligned+80*SPB+bit*SPB, delta, dc, gain)
        if full_window_features:
            # Ablation: only the coherent 500-point powers, no sub-window detail.
            full_feature = np.clip(full >> FULL_FEATURE_SHIFT, 0, 32767).astype(np.int16)
            feature = np.tile(full_feature, FEATURE_DIM//2)
        else:
            feature = np.concatenate(
                (feature, np.clip(np.right_shift(full, FULL_FEATURE_SHIFT), 0, 32767))).astype(np.int16)
        features[bit] = feature
        full_powers[bit] = full
        sub_powers[bit] = raw
        traditional[bit] = full[1] > full[0]
    return dict(features=features, traditional=traditional, full_powers=full_powers,
                sub_powers=sub_powers, delta=delta, dc=dc, gain=gain, aligned=aligned)


def make_waveform(bits, rng, delta=None, eb_n0=None, amplitude=None, shift=None,
                  jammer_freq=None, jammer_ratio=0.0, jammer_phase=None,
                  burst_payload=False):
    """Build one captured frame with optional AWGN and an optional tone jammer.

    The jammer models tone_jammer.sv: a continuous-phase sine added on top of the
    FSK signal for the whole frame burst, with a random phase relative to the
    symbol boundaries. jammer_ratio is amplitude relative to the FSK amplitude,
    matching how the GUI sets jammer amplitude against FSK amplitude.
    """
    bits = np.asarray(bits, dtype=np.uint8)
    if bits.size != 384:
        raise ValueError('384 air bits required')
    delta = int(rng.choice([-100, -50, 0, 50, 100])) if delta is None else int(delta)
    shift = int(rng.integers(0, 500)) if shift is None else int(shift)
    amplitude = float(rng.uniform(512, 24000)) if amplitude is None else float(amplitude)
    bias = float(rng.uniform(-2000, 2000))
    phase = float(rng.uniform(0, 2*np.pi))
    start = 1000+shift
    frequencies = np.repeat(1000+bits.astype(float)*1000+delta, SPB)
    phases = phase+np.concatenate(([0], np.cumsum(2*np.pi*frequencies[:-1]/FS)))
    clean = amplitude*np.sin(phases)
    if jammer_freq is not None and jammer_ratio:
        jam_phase = float(rng.uniform(0, 2*np.pi)) if jammer_phase is None else float(jammer_phase)
        indices = np.arange(start, start+clean.size, dtype=np.float64)
        gate = np.ones(clean.size, dtype=bool)
        if burst_payload:
            # 50% of body symbols, one random quarter-window; independent of data.
            gate[:] = False
            for bit in range(96, 384):
                slot = int(rng.integers(0, 4))
                if rng.integers(0, 2):
                    lo = bit*SPB+slot*SUBWINDOW
                    gate[lo:lo+SUBWINDOW] = True
        clean = clean+gate*jammer_ratio*amplitude*np.sin(2*np.pi*float(jammer_freq)*indices/FS+jam_phase)
    if eb_n0 is None:
        noise = np.zeros(clean.size)
    else:
        # Real passband signal: Eb=A^2*Tb/2. Two-sided real AWGN PSD=N0/2,
        # sampled at FS gives variance N0*FS/2, hence sigma=A/2*sqrt(SPB/r).
        ratio = 10**(float(eb_n0)/10)
        sigma = amplitude/2*np.sqrt(SPB/ratio)
        noise = rng.normal(0, sigma, clean.size)
    waveform = np.concatenate((np.full(start, bias), bias+clean+noise, np.full(1000, bias)))
    return np.rint(waveform).astype(np.int64), dict(delta=delta, shift=shift, amplitude=amplitude,
                                                   bias=bias, eb_n0=eb_n0,
                                                   jammer_freq=jammer_freq,
                                                   burst_payload=bool(burst_payload),
                                                   jammer_ratio=float(jammer_ratio))
