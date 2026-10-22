# train.py — dataset → golden features → train MLP → quantise → .mem files + test vectors
# Usage: python train.py <path to extracted speech_commands_v0.02>
import os, sys
import numpy as np, torch, torch.nn as nn
from scipy.io import wavfile
import golden as g
from quant import quantise, int_forward, write_mem

DATA  = sys.argv[1] if len(sys.argv) > 1 else "speech_commands_v0.02"
OUT   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mem")
WORDS = ["on", "off"]                                  # labels 2 and 3
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(0)
torch.manual_seed(0)

def load(path):
    sr, x = wavfile.read(path)
    assert sr == 16000
    return x.astype(np.int16)

def augment(x, noises):
    x = x.astype(np.float64)
    x = np.roll(x, rng.integers(-1600, 1601))            # ±100 ms shift
    nz = noises[rng.integers(len(noises))]
    start = rng.integers(len(nz) - len(x))
    x += rng.uniform(0, 0.3) * nz[start:start + len(x)]  # background noise
    x *= 10 ** (rng.uniform(-10, 10) / 20)               # ±10 dB gain
    return np.clip(np.round(x), -32768, 32767).astype(np.int16)

def silence_clip(noises):
    """1 s of background noise at 0.1–1× volume; 1 in 10 is near-silent."""
    nz = noises[rng.integers(len(noises))]
    start = rng.integers(len(nz) - 16000)
    gain = rng.uniform(0.1, 1.0) if rng.random() > 0.1 else rng.uniform(0, 0.01)
    return np.clip(np.round(nz[start:start + 16000] * gain), -32768, 32767).astype(np.int16)

# ---- speaker-separated split from the dataset's own lists ----
def read_list(name):
    with open(os.path.join(DATA, name)) as f:
        return set(line.strip() for line in f)

val_list, test_list = read_list("validation_list.txt"), read_list("testing_list.txt")
words   = {"train": [], "val": [], "test": []}           # (relative path, label)
unknown = {"train": [], "val": [], "test": []}
for word in sorted(os.listdir(DATA)):
    if word.startswith("_") or not os.path.isdir(os.path.join(DATA, word)):
        continue
    for fn in sorted(os.listdir(os.path.join(DATA, word))):
        rel   = f"{word}/{fn}"
        split = "val" if rel in val_list else "test" if rel in test_list else "train"
        if word in WORDS: words[split].append((rel, 2 + WORDS.index(word)))
        else:             unknown[split].append((rel, 1))

noise_dir = os.path.join(DATA, "_background_noise_")
noises = [load(os.path.join(noise_dir, f)).astype(np.float64)
          for f in sorted(os.listdir(noise_dir)) if f.endswith(".wav")]

def build(split, copies):
    """Balanced set: on + off, as many unknown and silence as one word class."""
    n   = len(words[split]) // 2
    unk = [unknown[split][i] for i in rng.choice(len(unknown[split]), n, replace=False)]
    clips  = [(load(os.path.join(DATA, rel)), lab) for rel, lab in words[split] + unk]
    clips += [(silence_clip(noises), 0) for _ in range(n)]
    X, y = [], []
    for i, (x, lab) in enumerate(clips):
        X.append(g.clip_to_input(x)); y.append(lab)
        for _ in range(copies):
            X.append(g.clip_to_input(augment(x, noises))); y.append(lab)
        if i % 2000 == 0: print(f"  {split}: {i}/{len(clips)} clips")
    return np.array(X), np.array(y)

print("computing golden features ...")
Xtr, ytr = build("train", copies=2)                      # original + 2 augmented copies
Xva, yva = build("val",   copies=0)
Xte, yte = build("test",  copies=0)
print(f"train {len(Xtr)}  val {len(Xva)}  test {len(Xte)}")

# ---- train the float MLP ----
mu, sd = Xtr.mean(0), Xtr.std(0) + 1e-3                # per-input normalisation
f = lambda X: torch.tensor((X - mu) / sd, dtype=torch.float32)
Xtr_f, Xva_f, Xte_f = f(Xtr), f(Xva), f(Xte)
ytr_t, yva_t = torch.tensor(ytr), torch.tensor(yva)

model = nn.Sequential(nn.Linear(992, 32), nn.ReLU(), nn.Linear(32, 4))
opt   = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-4)
lossf = nn.CrossEntropyLoss()

for epoch in range(30):
    perm = torch.randperm(len(Xtr_f))
    for i in range(0, len(perm), 128):                  # mini-batches of 128
        idx  = perm[i:i + 128]
        loss = lossf(model(Xtr_f[idx]), ytr_t[idx])
        opt.zero_grad(); loss.backward(); opt.step()
    with torch.no_grad():
        acc = (model(Xva_f).argmax(1) == yva_t).float().mean().item()
    print(f"epoch {epoch:2d}  loss {loss.item():.3f}  val acc {acc:.3f}")

W1 = model[0].weight.detach().numpy().astype(np.float64); b1 = model[0].bias.detach().numpy().astype(np.float64)
W2 = model[2].weight.detach().numpy().astype(np.float64); b2 = model[2].bias.detach().numpy().astype(np.float64)

# ---- quantise and check the integer model against the float one ----
q = quantise(W1, b1, W2, b2, mu, sd, Xtr.astype(np.float64))
with torch.no_grad():
    float_pred = model(Xte_f).argmax(1).numpy()
int_pred = int_forward(Xte, q)[0].argmax(1)
print(f"test acc  float {np.mean(float_pred == yte):.3f}   integer {np.mean(int_pred == yte):.3f}"
      f"   agreement {np.mean(float_pred == int_pred):.3f}")

# ---- export .mem files ----
m = lambda name: os.path.join(OUT, name)
write_mem(m("hann512_q15.mem"),  g.HANN,  16)
write_mem(m("tw512_re_q15.mem"), g.TW_RE, 16)
write_mem(m("tw512_im_q15.mem"), g.TW_IM, 16)
write_mem(m("w1.mem"), q["qW1"], 8);   write_mem(m("b1.mem"), q["qb1"], 32)
write_mem(m("w2.mem"), q["qW2"], 8);   write_mem(m("b2.mem"), q["qb2"], 32)

# test vectors from one full-length "on" clip of the test set
rel  = next(r for r, lab in words["test"] if lab == 2 and len(load(os.path.join(DATA, r))) == 16000)
x    = load(os.path.join(DATA, rel))
clip = np.pad(x, (0, g.CLIP_LEN - len(x)))              # 16,000 + 128 = 16,128
feat = g.features_hw(clip).reshape(-1)
scores, h = int_forward(feat.reshape(1, -1), q)
write_mem(m("tv_samples.mem"),  clip,   16)
write_mem(m("tv_features.mem"), feat,   8)
write_mem(m("tv_hidden.mem"),   h,      8)
write_mem(m("tv_scores.mem"),   scores, 32)
print(f"test vectors from {rel}: scores {scores[0].tolist()}")

# ---- decision threshold sweep on the validation set ----
scores, _ = int_forward(Xva, q)
top2   = np.sort(scores, axis=1)[:, -2:]
margin = top2[:, 1] - top2[:, 0]
pred   = scores.argmax(1)
cmd_ok  = (pred == yva) & (yva >= 2)                  # correct on/off
cmd_bad = (pred >= 2) & (yva <= 1)                    # silence/unknown mistaken for on/off
print("MARGIN sweep (pick the smallest with acceptable false triggers):")
for T in [0, 500, 1000, 2000, 4000, 8000]:
    print(f"  {T:5d}  kept correct: {(margin[cmd_ok] > T).mean():.3f}"
          f"   false triggers: {(margin[cmd_bad] > T).mean():.3f}")

print("SHIFT1 =", q["S"], " → put it in rtl/top.v: mlp #(.SHIFT1(...))")
