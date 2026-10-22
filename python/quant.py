# quant.py — float model → int8/int32 tables, the bit-exact integer model, and .mem export
import numpy as np

def pow2_frac_bits(max_abs, limit=127):
    """Largest F such that max_abs * 2^F <= limit."""
    return int(np.floor(np.log2(limit / max_abs)))

def quantise(W1, b1, W2, b2, mu, sd, X_calib):
    """Float model (trained on (x-mu)/sd) → int8/int32 tables + shift, matching mlp.v."""
    # 1) fold normalisation into layer 1
    W1f = W1 / sd[None, :]
    b1f = b1 - (W1 * (mu / sd)[None, :]).sum(axis=1)
    # 2) layer-1 weights and bias (inputs are raw int8 features: F_x = 0)
    Fw1 = pow2_frac_bits(np.abs(W1f).max())
    qW1 = np.clip(np.round(W1f * 2**Fw1), -128, 127).astype(np.int64)
    qb1 = np.round(b1f * 2**Fw1).astype(np.int64)
    # 3) hidden scale from calibration data (99.9th percentile of real activations)
    h_real = np.maximum(X_calib @ W1f.T + b1f, 0)
    Fh = pow2_frac_bits(np.percentile(h_real, 99.9))
    S  = Fw1 - Fh                                   # requant shift → SHIFT1 in Verilog
    assert S >= 1, "shift must be positive; check scales"
    # 4) layer 2 (inputs are int8 hidden values with scale 2^-Fh)
    Fw2 = pow2_frac_bits(np.abs(W2).max())
    qW2 = np.clip(np.round(W2 * 2**Fw2), -128, 127).astype(np.int64)
    qb2 = np.round(b2 * 2**(Fw2 + Fh)).astype(np.int64)
    return dict(qW1=qW1, qb1=qb1, qW2=qW2, qb2=qb2, S=S, Fw1=Fw1, Fh=Fh, Fw2=Fw2)

def int_forward(x, q):
    """Bit-exact model of mlp.v. x: (n, 992) int8 → (n, 4) int32 scores, (n, 32) hidden."""
    x = x.astype(np.int64)
    acc1 = x @ q["qW1"].T + q["qb1"]
    S = q["S"]
    h = np.where(acc1 <= 0, 0, np.minimum((acc1 + (1 << (S - 1))) >> S, 127))
    scores = h @ q["qW2"].T + q["qb2"]
    return scores, h

def write_mem(path, values, bits):
    """One two's-complement hex word per line, for Verilog $readmemh."""
    mask, digits = (1 << bits) - 1, bits // 4
    with open(path, "w") as f:
        for v in np.asarray(values).reshape(-1):
            f.write(f"{int(v) & mask:0{digits}x}\n")
