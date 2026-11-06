# try_wav.py — run any .wav through the golden model and the Verilog pipeline, print what it hears.
# Usage: python try_wav.py my_recording.wav [--no-sim]      (run train.py first, for the mem/ files)
import os, re, sys, subprocess
from math import gcd
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly
import golden as g
from quant import int_forward, write_mem

ROOT  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MEM   = os.path.join(ROOT, "mem")
NAMES = ["silence", "unknown", "on", "off"]
PAD   = 8000                     # 0.5 s of silence each side, so the word slides through several windows

def load_any(path):
    """Any wav (rate, channels, sample format) → 16 kHz mono int16, like the board's samples."""
    sr, x = wavfile.read(path)
    if   x.dtype == np.int16: x = x.astype(np.float64)
    elif x.dtype == np.int32: x = x / 65536.0
    elif x.dtype == np.uint8: x = (x - 128.0) * 256
    else:                     x = x * 32767.0               # float wav in [-1, 1]
    if x.ndim > 1: x = x.mean(axis=1)                       # stereo → mono
    if sr != 16000:
        d = gcd(sr, 16000)
        x = resample_poly(x, 16000 // d, sr // d)
    return np.clip(np.round(x), -32768, 32767).astype(np.int16)

def board_params():
    """SHIFT1, MARGIN, WAIT_TIME exactly as set in rtl/top.v, so the answer matches the board."""
    top = open(os.path.join(ROOT, "rtl", "top.v"), encoding="utf-8").read()
    get = lambda pat: int(re.search(pat, top).group(1))
    return dict(SHIFT1=get(r"SHIFT1\((\d+)\)"), MARGIN=get(r"MARGIN\((?:32'sd)?(\d+)\)"),
                WAIT_TIME=get(r"WAIT_TIME\((\d+)\)"))

def read_mem(name, bits):
    """Inverse of write_mem: hex lines → signed integers."""
    v = np.array([int(l, 16) for l in open(os.path.join(MEM, name)) if l.strip()], dtype=np.int64)
    return np.where(v >= 1 << (bits - 1), v - (1 << bits), v)

def golden_scores(x, S):
    """Scores for every inference the board would run: one per new frame once 62 frames exist."""
    q = dict(qW1=read_mem("w1.mem", 8).reshape(32, 992), qb1=read_mem("b1.mem", 32),
             qW2=read_mem("w2.mem", 8).reshape(4, 32),  qb2=read_mem("b2.mem", 32), S=S)
    feats = g.features_hw(x)                                # one row per 16 ms frame
    X = np.stack([feats[t - 61:t + 1].reshape(-1) for t in range(61, len(feats))])
    return int_forward(X, q)[0]

def decide(scores, MARGIN, WAIT_TIME):
    """Model of decision.v. Returns (best, confident) per inference and the fired commands."""
    state, last, wait_count = "LISTEN", 0, 0
    out, fires = [], []
    for i, s in enumerate(scores):
        idx = int(np.argmax(s))                             # ties → lowest index, like decision.v
        sure = s[idx] - np.sort(s)[-2] > MARGIN
        command = sure and idx >= 2
        out.append((idx, sure))
        if state == "LISTEN":
            if command and idx == last:                     # same command twice in a row
                fires.append((i, NAMES[idx])); state, wait_count = "WAIT", 0
            last = idx if command else 0
        elif wait_count == WAIT_TIME - 1:
            state, last = "LISTEN", 0
        else:
            wait_count += 1
    return out, fires

def verilog_run(x, p):
    """Simulate tb_wav with the same samples; returns its scores and fired commands."""
    write_mem(os.path.join(MEM, "wav_samples.mem"), x, 16)
    params = [f"-Ptb_wav.{k}={v}" for k, v in p.items()] + [f"-Ptb_wav.NSAMP={len(x)}"]
    subprocess.run(["iverilog", "-g2012", "-y", "../rtl", "-Y", ".v", "-s", "tb_wav",
                    "-o", "tb_wav.vvp", *params, "../tb/tb_wav.sv"], cwd=MEM, check=True)
    lines = subprocess.run(["vvp", "-n", "tb_wav.vvp"], cwd=MEM, check=True,
                           capture_output=True, text=True).stdout.splitlines()
    scores = np.array([[int(v) for v in l.split()[2:]] for l in lines if l.startswith("SCORES")])
    fires  = [(int(l.split()[2]), l.split()[1]) for l in lines if l.startswith("FIRE")]
    return scores, fires

path = sys.argv[1]
x = np.pad(load_any(path), PAD)
x = np.pad(x, (0, max(0, g.CLIP_LEN - len(x))))
p = board_params()
t_of = lambda i: ((i + 61) * 256 + 512 - PAD) / 16000      # end of inference i's window, in the original wav

scores = golden_scores(x, p["SHIFT1"])
res, fires = decide(scores, p["MARGIN"], p["WAIT_TIME"])
print(f"{path}: {(len(x) - 2 * PAD) / 16000:.2f} s, {len(scores)} inferences, "
      + ", ".join(f"{k}={v}" for k, v in p.items()))
print("golden model, confident guesses (time = end of the 1-s window):")
for i, (b, conf) in enumerate(res):
    if conf: print(f"  {t_of(i):5.2f} s  {NAMES[b]}")
for i, name in fires:
    print(f"  → lamp {name.upper()} at {t_of(i):.2f} s")
if not fires:
    print("  → no command fired (lamp unchanged)")

if "--no-sim" not in sys.argv:
    print("running the Verilog simulation (about 2 minutes per second of audio) ...")
    hw_scores, hw_fires = verilog_run(x, p)
    same = hw_scores.shape == scores.shape and (hw_scores == scores).all()
    print(f"Verilog: {len(hw_scores)} inferences, scores {'MATCH' if same else 'DIFFER from'} the golden model, "
          f"commands {'MATCH' if hw_fires == fires else 'DIFFER: ' + str(hw_fires)}")
    if not same and hw_scores.shape == scores.shape:
        i = int(np.argmax((hw_scores != scores).any(axis=1)))
        print(f"  first difference at inference {i}: Verilog {hw_scores[i].tolist()}  golden {scores[i].tolist()}")
