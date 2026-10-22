# Voice Command Recognizer (Nexys 4 DDR)

Say **"on"** and LED0 lights up; say **"off"** and it goes out. Silence and other words are ignored.
Built from the notes in `Aether/Notes/Hardware Notes/FPGA Voice Command Recognizer`.

```
mic → pdm_rx → frame_buffer → fft512 → features → mlp → decision → LED
       16 kHz    512/hop 256    bins     62×16 int8  4 scores  lamp
```

## Folder layout

| Folder | Contents |
|---|---|
| `rtl/` | `pdm_rx`, `frame_buffer`, `butterfly`, `fft512`, `features`, `mlp`, `decision`, `uart_tx`, `top` |
| `tb/` | one testbench per stage (`tb_pdm_rx`, `tb_frame_buffer`, `tb_fft512`, `tb_frontend`, `tb_mlp`, `tb_decision`) |
| `constraints/` | `nexys4ddr.xdc` pin file |
| `python/` | `golden.py` (bit-exact front end), `quant.py`, `train.py`, `record.py` |
| `mem/` | created by `train.py`: ROM tables, weights and test vectors |

## 1. Train (PC)

1. Download and extract Google Speech Commands v2 (`speech_commands_v0.02.tar.gz`).
2. Install packages and run:

```bash
pip install -r python/requirements.txt
```

```bash
python python/train.py path/to/speech_commands_v0.02
```

It writes everything into `mem/` and prints:
- test accuracy (float, integer, and their agreement)
- a MARGIN sweep → pick a value and set `MARGIN` in `rtl/top.v`
- `SHIFT1` → set it in `rtl/top.v` (`mlp #(.SHIFT1(...))`)

## 2. Simulate (Icarus Verilog)

Run from the `mem/` folder so `$readmemh` finds the files:

```bash
cd mem
```

```bash
iverilog -g2012 -y ../rtl -Y .v -s tb_frontend -o sim ../tb/tb_frontend.sv
```

```bash
vvp sim
```

Swap in the other testbenches the same way. Pass conditions:

| Testbench | Needs `train.py` first? | Pass |
|---|---|---|
| `tb_pdm_rx` | no | `PASS` line |
| `tb_frame_buffer` | no | `PASS` line |
| `tb_fft512` | no | `PASS` line |
| `tb_decision` | no | `PASS` line |
| `tb_frontend` | yes | `mismatches: 0` over 992 features |
| `tb_mlp` | yes | `PASS` line; add `-Ptb_mlp.SHIFT1=<value>` to the iverilog command |

## 3. Build (Vivado)

1. New RTL project, part **xc7a100tcsg324-1**.
2. Add `rtl/*.v` as design sources, and the 7 table files from `mem/` (`hann512_q15`, `tw512_re_q15`, `tw512_im_q15`, `w1`, `b1`, `w2`, `b2` `.mem`) as design sources too.
3. Add `constraints/nexys4ddr.xdc`. Top module: `top`.
4. Generate bitstream and program the board.

## 4. On the board

| LED | Meaning |
|---|---|
| LED0 | the lamp (on/off command) |
| LED1 | BTNC held (recording) |
| LED3:2 | latest best class: 0 silence, 1 unknown, 2 on, 3 off |
| LED4 | latest guess passed the margin |
| LED15:8 | loudness bar |

`CPU_RESET` resets the design.

## 5. Record your own voice (optional, improves accuracy)

Start the script first, then hold **BTNC** while speaking:

```bash
python python/record.py COM5 my_recording.wav
```

Cut the recording into 1-s clips (e.g. in Audacity), drop them into the dataset's `on/`, `off/` or another word folder, and rerun `train.py`. Clips not in the dataset's lists go into the training split automatically.
