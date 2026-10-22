# golden.py — bit-exact model of the FPGA front end
import numpy as np

N, HOP, NFRAMES = 512, 256, 62
CLIP_LEN = (NFRAMES - 1) * HOP + N          # 16,128 samples ≈ 1.0 s

# ---- constant tables (the same numbers go into the .mem files) ----
n = np.arange(N)
HANN  = np.round(32767 * 0.5 * (1 - np.cos(2 * np.pi * n / N))).astype(np.int64)
k256  = np.arange(N // 2)
TW_RE = np.round( 32767 * np.cos(2 * np.pi * k256 / N)).astype(np.int64)
TW_IM = np.round(-32767 * np.sin(2 * np.pi * k256 / N)).astype(np.int64)
BITREV = np.array([int(f"{i:09b}"[::-1], 2) for i in range(N)])

STAGES = []                                  # (top, bot, tw) index arrays per stage
b = np.arange(N // 2)
for s in range(9):
    half = 1 << s
    kk   = b & (half - 1)
    top  = ((b >> s) << (s + 1)) | kk
    STAGES.append((top, top | half, kk << (8 - s)))

BAND_END   = np.array([5, 10, 15, 21, 29, 37, 47, 59, 73, 88, 107, 128, 153, 182, 216, 255])
BAND_START = np.concatenate(([2], BAND_END[:-1] + 1))

def fft_hw(xw):
    """Bit-exact model of fft512: in-place radix-2 DIT, Q15 twiddles, floor shifts."""
    re = np.zeros_like(xw); im = np.zeros_like(xw)
    re[..., BITREV] = xw                     # sample n stored at address bitrev(n)
    for top, bot, tw in STAGES:
        ar, ai = re[..., top], im[..., top]
        br, bi = re[..., bot], im[..., bot]
        wr, wi = TW_RE[tw], TW_IM[tw]
        tr = (br * wr - bi * wi) >> 15       # >> on int64 = Verilog >>> (floor)
        ti = (br * wi + bi * wr) >> 15
        re[..., top], im[..., top] = ar + tr, ai + ti
        re[..., bot], im[..., bot] = ar - tr, ai - ti
    return re, im

def log2q3(v):
    """8*(leading-one position) + next 3 bits; 0 for v == 0."""
    _, e = np.frexp(v.astype(np.float64))    # v = m * 2^e, m in [0.5, 1)  (exact for v < 2^53)
    p  = np.maximum(e - 1, 0).astype(np.int64)
    fr = np.where(p >= 3, v >> np.maximum(p - 3, 0), v << np.maximum(3 - p, 0)) & 7
    return np.where(v > 0, 8 * p + fr, 0)

def features_hw(x16):
    """int16 clip (len >= 512) → (frames, 16) int8 features, exactly as the FPGA."""
    x = x16.astype(np.int64)
    nfr = (len(x) - N) // HOP + 1
    idx = np.arange(nfr)[:, None] * HOP + n[None, :]
    xw  = (x[idx] * HANN) >> 15                              # frame_buffer
    re, im = fft_hw(xw)                                      # fft512
    ar, ai = np.abs(re[:, :256]), np.abs(im[:, :256])
    mag = np.maximum(ar, ai) + (np.minimum(ar, ai) >> 1)     # features stage 2
    sums = np.add.reduceat(mag[:, 2:256], BAND_START - 2, axis=1)
    return (log2q3(sums) - 128).astype(np.int8)

def clip_to_input(x16):
    """1-s clip → 992-vector in the network's input order (oldest frame first)."""
    x16 = np.asarray(x16, dtype=np.int16)[:CLIP_LEN]
    x16 = np.pad(x16, (0, CLIP_LEN - len(x16)))
    return features_hw(x16).reshape(-1)                      # j = 16*frame + band
