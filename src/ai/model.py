"""Bit-exact int8/int16/int32 reference for the 10-16-8-2 FSK MLP."""
from pathlib import Path

import numpy as np

MODEL_VERSION = 0x00070001  # Burst-payload specialist; baseline weights in baseline_v6.
FEATURE_DIM = 10
SUB_FEATURE_SHIFT = 14  # 125-point sub-window power >> 14 -> int16 feature
FULL_FEATURE_SHIFT = 18  # 500-point coherent power >> 18 -> int16 feature
# Layout: four sub-window powers per branch (branch 0 then branch 1 per window)
# followed by the two coherent full-window powers. See fsk_correlator.sv.
SIZES = (FEATURE_DIM, 16, 8, 2)
WEIGHT_COUNTS = (160, 128, 16)
BIAS_COUNTS = (16, 8, 2)
PARAMETER_COUNT = 330
WEIGHT_SLICES = ((0, 160), (176, 304), (312, 328))
BIAS_SLICES = ((160, 176), (304, 312), (328, 330))


def saturate_int16(x):
    return np.clip(x, -32768, 32767).astype(np.int64)


def quantize_activation(acc, shift):
    """ReLU, arithmetic right shift and signed-int16 saturation."""
    shifted = np.right_shift(np.asarray(acc, dtype=np.int64), int(shift))
    return saturate_int16(np.maximum(shifted, 0))


def unpack_parameters(parameters):
    parameters = np.asarray(parameters, dtype=np.int64)
    if parameters.size != PARAMETER_COUNT:
        raise ValueError(f'expected {PARAMETER_COUNT} parameters')
    weights = []
    biases = []
    for layer in range(3):
        lo, hi = WEIGHT_SLICES[layer]
        weights.append(parameters[lo:hi].reshape(SIZES[layer + 1], SIZES[layer]))
        lo, hi = BIAS_SLICES[layer]
        biases.append(parameters[lo:hi])
    return weights, biases


def pack_parameters(weights, biases):
    parameters = np.zeros(PARAMETER_COUNT, dtype=np.int64)
    for layer in range(3):
        lo, hi = WEIGHT_SLICES[layer]
        parameters[lo:hi] = np.asarray(weights[layer], dtype=np.int64).reshape(-1)
        lo, hi = BIAS_SLICES[layer]
        parameters[lo:hi] = np.asarray(biases[layer], dtype=np.int64)
    for lo, hi in WEIGHT_SLICES:
        if np.any(np.abs(parameters[lo:hi]) > 127):
            raise ValueError('weight outside int8')
    return parameters


def forward_integer(features, parameters, shifts):
    """Return each integer layer. Inputs and activations are signed int16."""
    weights, biases = unpack_parameters(parameters)
    activation = np.asarray(features, dtype=np.int64)
    if activation.ndim == 1:
        activation = activation[None, :]
    accumulators = []
    activations = []
    for layer in range(3):
        acc = activation @ weights[layer].T + biases[layer]
        accumulators.append(acc)
        if layer < 2:
            activation = quantize_activation(acc, shifts[layer])
            activations.append(activation)
    return accumulators, activations


def predict(features, parameters, shifts):
    accumulators, _ = forward_integer(features, parameters, shifts)
    # Equality is fixed to bit zero, exactly like the traditional branch.
    return (accumulators[-1][:, 1] > accumulators[-1][:, 0]).astype(np.uint8)


def check_ranges(features, parameters, shifts):
    accumulators, activations = forward_integer(features, parameters, shifts)
    if any(np.max(np.abs(a)) > 2147483647 for a in accumulators):
        raise AssertionError('int32 accumulator overflow')
    return {
        'accumulator_max_abs': [int(np.max(np.abs(a))) for a in accumulators],
        'activation_max': [int(np.max(a)) for a in activations],
        'activation_saturated': [int(np.count_nonzero(a >= 32767)) for a in activations],
    }


def export_mem(parameters, path):
    parameters = np.asarray(parameters, dtype=np.int64)
    if parameters.size != PARAMETER_COUNT:
        raise ValueError(f'expected {PARAMETER_COUNT} parameters')
    words = [int(x) & 0xffffffff for x in parameters]
    Path(path).write_text(''.join(f'{word:08x}\n' for word in words), encoding='ascii')
