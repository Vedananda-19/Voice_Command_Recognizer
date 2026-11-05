# Voice Command Recognizer on an FPGA

Say **"on"** and a light turns on. Say **"off"** and it turns off. Silence, noise and other words are ignored.

Everything runs on a **Nexys 4 DDR** board (Artix-7 **xc7a100tcsg324-1**) using its built-in microphone. A small neural network, trained on a PC, does the recognition in hardware. The design is plain Verilog with no IP cores.

---

## Steps (short version)

1. **Train** on the PC: `python python/train.py C:\data` (Speech Commands v2 dataset).
2. **Copy two numbers** that `train.py` prints into `rtl/top.v`: `SHIFT1` and `MARGIN`.
3. **Simulate** (optional but recommended): run `tb_frontend` and `tb_mlp` from `mem/` and check they pass.
4. **Build** in Vivado: add `rtl/`, the 7 `.mem` tables, and the `.xdc`, then Generate Bitstream.
5. **Program** the board and say "on" / "off". LED0 and the external pin `lamp_out` follow the command.

Details for each step are below.

---

## How it works

```
 mic ─► pdm_rx ─► frame_buffer ─► fft512 ─► features ─► mlp ─► decision ─► LED0 / lamp_out
        16 kHz     512 samples     256       62 × 16     4      on / off
        samples    every 16 ms     bins      fingerprint scores
```

| Stage | Module | What it does |
|---|---|---|
| 1 | `pdm_rx` | turns the mic's 1-bit stream into 16-bit samples, 16,000 per second |
| 2 | `frame_buffer` | keeps the last 512 samples; every 256 new samples, sends a windowed frame |
| 3 | `fft512` | converts the frame from time into frequencies |
| 4 | `features` | squeezes the frequencies into 16 bands (log scale) and keeps the last ~1 s: a 62 × 16 "fingerprint" |
| 5 | `mlp` | the neural network (992 → 32 → 4) gives a score to each class: silence, unknown, on, off |
| 6 | `decision` | acts only when "on" or "off" wins clearly, 4 times in a row, then waits ~1 s |

Everything runs on one 100 MHz clock. Each module passes a one-clock "done" pulse to the next one. The PC only does the training: `python/golden.py` does exactly the same integer maths as the hardware, so what passes in Python passes on the FPGA.

---

## Project layout

| Folder | Contents |
|---|---|
| `rtl/` | the hardware: `pdm_rx`, `frame_buffer`, `butterfly`, `fft512`, `features`, `mlp`, `decision`, `uart_tx`, `top` |
| `tb/` | one testbench per stage, plus `tb_wav` (everything after the mic, fed from a `.wav`) |
| `constraints/` | `nexys4ddr.xdc`, the pin assignments |
| `python/` | `train.py` (training), `golden.py` (bit-exact model of the hardware), `quant.py` (int8 conversion), `try_wav.py` (test a recording), `record.py` (record through the board) |
| `mem/` | made by `train.py`: lookup tables, network weights, and test vectors |

---

## 1. Train (PC)

You need Python with `numpy`, `scipy`, `torch` and `pyserial`, and the **Google Speech Commands v2** dataset (`speech_commands_v0.02.tar.gz`, about 2.3 GB) extracted into a folder of its own.

```bash
pip install -r python/requirements.txt
```

```bash
python python/train.py C:\data
```

The dataset folder must contain only the dataset: one folder per word (`on\`, `off\`, `yes\`, ...), `_background_noise_\`, `validation_list.txt` and `testing_list.txt`.

At the end it prints:
- **accuracy**, for the float network and the integer one the FPGA runs (they should be within ~2%)
- **a MARGIN table**: pick the smallest value with acceptable false triggers
- **`SHIFT1`**

Put both numbers into `rtl/top.v`:

```verilog
mlp #(.SHIFT1(11)) u_mlp (                                   // SHIFT1 from train.py
decision #(.MARGIN(32'sd500), .K(4), .COOLDOWN(62)) u_dec (  // MARGIN from the table
```

---

## 2. Simulate (Icarus Verilog)

Run from `mem/`, so the testbenches find their files:

```bash
cd mem
```

```bash
iverilog -g2012 -y ../rtl -Y .v -s tb_frontend -o sim ../tb/tb_frontend.sv
```

```bash
vvp sim
```

Change the testbench name in both places to run another one:

| Testbench | Checks | Pass |
|---|---|---|
| `tb_pdm_rx` | mic receiver timing | `PASS` |
| `tb_frame_buffer` | framing and window | `PASS` |
| `tb_fft512` | FFT | `PASS` |
| `tb_decision` | streak, margin, cooldown | `PASS` |
| `tb_frontend` | frames → FFT → features, against Python | `mismatches: 0` |
| `tb_mlp` | network scores, against Python | `PASS` (add `"-Ptb_mlp.SHIFT1=<value>"`, keeping the quotes in PowerShell) |

`Unable to open ... .mem` messages in `tb_frame_buffer` and `tb_fft512` are expected: those two load their own test values.

**Test your own recording without the board:**

```bash
python python/try_wav.py my_on.wav
```

It runs the audio through the Python model (instant) and the Verilog simulation (about 2 minutes per second of audio), prints when the lamp would switch, and checks that both agree. It reads `SHIFT1`, `MARGIN`, `K` and `COOLDOWN` from `rtl/top.v`. Add `--no-sim` to skip the Verilog part.

---

## 3. Build (Vivado)

1. New RTL project, part **xc7a100tcsg324-1**.
2. **Add Sources → design sources → Add Directories:** `rtl/`. Untick "Copy sources into project".
3. **Add the 7 memory files.** Folder import skips `.mem` files, so use the Tcl Console (change the path to your repo):

   ```tcl
   add_files -norecurse [glob C:/Voice_Command_Recognizer/mem/{hann512_q15,tw512_re_q15,tw512_im_q15,w1,b1,w2,b2}.mem]
   ```

   ```tcl
   set_property file_type {Memory File} [get_files *.mem]
   ```

4. **Add Sources → constraints:** `constraints/nexys4ddr.xdc`.
5. Check that `top` is the top module, then click **Generate Bitstream**.
6. Before programming, check:
   - Messages: no `could not open $readmem` warnings
   - Utilization: about 11 BRAM and 5 DSP. Close to 0 BRAM means the `.mem` files were not loaded.
   - Timing: WNS ≥ 0

---

## 4. On the board

Program it with **Hardware Manager → Auto Connect → Program Device**, then press `CPU_RESET` once.

| Output | Meaning |
|---|---|
| LED0 | the lamp: on after "on", off after "off" |
| LED1 | BTNC is held (recording) |
| LED3, LED2 | latest guess: `00` silence, `01` unknown, `10` on, `11` off |
| LED4 | the latest guess was confident |
| LED15–LED8 | loudness bar |
| **`lamp_out`** (Pmod JA, pin 1) | same as LED0, for external circuits |

### Connecting something to `lamp_out`

`lamp_out` is pin 1 of the **JA** Pmod header. Pin 1 is marked on the board's silkscreen. Each Pmod header has two rows of 6 pins:

```
 row 1:  pin 1   pin 2   pin 3   pin 4   pin 5 = GND   pin 6 = 3.3 V
 row 2:  pin 7   pin 8   pin 9   pin 10  pin 11 = GND  pin 12 = 3.3 V

 pin 1 = lamp_out
```

- **An LED:** pin 1 → 330 Ω resistor → LED (long leg) → LED (short leg) → GND.
- **A relay, motor or anything bigger:** don't drive it straight from the pin. It's 3.3 V and only a few mA. Use a transistor or a relay module with its own supply, connecting only the signal and GND to the board.

---

## 5. Improve accuracy with your own voice

The board's mic sounds different from the dataset's recordings. Recording yourself through the board helps the most.

```bash
python python/record.py COM5 my_recording.wav
```

Start the script first, then hold **BTNC** while speaking. Cut the recording into 1-s clips (in Audacity, for example), put them into the dataset's `on\`, `off\` or another word's folder, and run `train.py` again. Your clips go into the training set automatically.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Loudness LEDs never move | wrong pins, or reset held. Check the `.xdc`; press `CPU_RESET`. |
| LED2–LED4 never light | the `.mem` files weren't loaded in Vivado (see step 3) |
| Guesses show, but LED0 never switches | `MARGIN` too high or `K` too big; check with `try_wav.py` on a board recording |
| Always "unknown" | the board mic differs from the dataset: record your own clips and retrain |
| Lamp switches by itself | `MARGIN` too low; raise it or `K` |
| `tb_mlp` fails | `SHIFT1` on the command line doesn't match `train.py` |

---

## Credits

Built from the study notes *FPGA Voice Command Recognizer* (notes 00–08). Training data: Google Speech Commands v2 (CC BY 4.0).
