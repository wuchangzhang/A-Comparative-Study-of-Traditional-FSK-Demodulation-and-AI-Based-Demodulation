# NumPy QAT used by the final v7 burst model.
import numpy as np
from model import SIZES, pack_parameters

def fake_quant(parameters):
    quantized = []
    for value in parameters:
        quantized.append(np.clip(np.rint(value), -127, 127))
    return quantized

def initial_parameters(seed):
    rng = np.random.default_rng(seed)
    n_in = SIZES[0]
    return [rng.normal(0, 5, (16, n_in)), rng.normal(0, 5, (8, 16)), rng.normal(0, 5, (2, 8))], \
           [np.zeros(16), np.zeros(8), np.zeros(2)]

def quant_forward(x, weights, biases, shifts):
    qw = fake_quant(weights)
    qb = [np.clip(np.rint(b), -2147483648, 2147483647) for b in biases]
    z1 = x.astype(np.float64) @ qw[0].T + qb[0]
    a1 = np.clip(np.right_shift(np.maximum(z1, 0).astype(np.int64), shifts[0]), 0, 32767).astype(np.float64)
    z2 = a1 @ qw[1].T + qb[1]
    a2 = np.clip(np.right_shift(np.maximum(z2, 0).astype(np.int64), shifts[1]), 0, 32767).astype(np.float64)
    z3 = a2 @ qw[2].T + qb[2]
    return (z1, a1, z2, a2, z3), (qw, qb)

def choose_scales(x, weights, biases, forced_shifts=None):
    z1 = x.astype(np.float64) @ weights[0].T + biases[0]
    s1 = max(0, int(np.ceil(np.log2(max(1, np.max(np.abs(z1)))/28000))))
    if forced_shifts is not None:
        s1 = int(forced_shifts[0])
    a1 = np.clip(np.right_shift(np.maximum(z1, 0).astype(np.int64), s1), 0, 32767).astype(np.float64)
    z2 = a1 @ weights[1].T + biases[1]
    s2 = max(0, int(np.ceil(np.log2(max(1, np.max(np.abs(z2)))/28000))))
    if forced_shifts is not None:
        s2 = int(forced_shifts[1])
    a2 = np.clip(np.right_shift(np.maximum(z2, 0).astype(np.int64), s2), 0, 32767).astype(np.float64)
    z3 = a2 @ weights[2].T + biases[2]
    logit_scale = 2**max(0, int(np.ceil(np.log2(max(1, np.max(np.abs(z3)))/8))))
    return (s1, s2, 0), int(logit_scale)

def hard_sample_weights(data, boost=10.0):
    """Up-weight frames where the traditional correlator already struggles.

    Clean cells dominate the sample count, so an unweighted loss spends almost all
    of its gradient budget on bits the traditional branch already gets right.
    Weighting each frame by (1 + boost * its traditional error rate) keeps the mean
    weight at 1 while giving the cells that carry the BER most of the gradient.
    """
    groups = data['groups']
    errors = (data['traditional'] != data['y']).astype(np.float64)
    weights = np.ones(data['y'].size, dtype=np.float64)
    for group in np.unique(groups):
        mask = groups == group
        weights[mask] = 1.0+boost*float(errors[mask].mean())
    return weights/weights.mean()

def train_qat(data, seed, epochs, forced_shifts=None, learning_rate=0.08, boost=0.0):
    rng = np.random.default_rng(seed)
    weights, biases = initial_parameters(seed)
    shifts, logit_scale = choose_scales(data['x'], weights, biases, forced_shifts)
    all_parameters = weights+biases
    sample_weights = hard_sample_weights(data, boost) if boost else None
    first = [np.zeros_like(p) for p in all_parameters]
    second = [np.zeros_like(p) for p in all_parameters]
    step = 0
    n = data['y'].size
    for _epoch in range(epochs):
        order = rng.permutation(n)
        for start in range(0, n, 512):
            indices = order[start:start+512]
            x = data['x'][indices].astype(np.float64)
            y = data['y'][indices].astype(np.int64)
            batch = y.size
            (z1, a1, z2, a2, z3), (qw, _qb) = quant_forward(x, weights, biases, shifts)
            logits = z3/logit_scale
            logits -= np.max(logits, axis=1, keepdims=True)
            exp = np.exp(logits)
            probability = exp/np.sum(exp, axis=1, keepdims=True)
            dz3 = probability
            dz3[np.arange(batch), y] -= 1
            if sample_weights is not None:
                dz3 *= sample_weights[indices][:, None]
            dz3 /= batch*logit_scale
            gradients_w = [None]*3
            gradients_b = [None]*3
            gradients_w[2] = dz3.T @ a2
            gradients_b[2] = np.sum(dz3, axis=0)
            da2 = dz3 @ qw[2]
            dz2 = da2*(z2 > 0)/(2**shifts[1])
            gradients_w[1] = dz2.T @ a1
            gradients_b[1] = np.sum(dz2, axis=0)
            da1 = dz2 @ qw[1]
            dz1 = da1*(z1 > 0)/(2**shifts[0])
            gradients_w[0] = dz1.T @ x
            gradients_b[0] = np.sum(dz1, axis=0)
            gradients = gradients_w+gradients_b
            learning_rates = [learning_rate, learning_rate, learning_rate,
                              learning_rate*2**shifts[0], learning_rate*2**shifts[1],
                              learning_rate*logit_scale]
            step += 1
            for index, (parameter, gradient) in enumerate(zip(all_parameters, gradients)):
                gradient = np.clip(gradient, -1e6, 1e6)
                first[index] = 0.9*first[index]+0.1*gradient
                second[index] = 0.999*second[index]+0.001*gradient*gradient
                mhat = first[index]/(1-0.9**step)
                vhat = second[index]/(1-0.999**step)
                parameter -= learning_rates[index]*mhat/(np.sqrt(vhat)+1e-8)
    quantized_w = [np.clip(np.rint(w), -127, 127).astype(np.int64) for w in weights]
    quantized_b = [np.clip(np.rint(b), -2147483648, 2147483647).astype(np.int64) for b in biases]
    parameters = pack_parameters(quantized_w, quantized_b)
    return parameters, shifts, logit_scale
