# record.py — save audio streamed by the board while BTNC is held.
# Usage: python record.py COM5 my_recording.wav   (start this BEFORE pressing the button)
import sys, serial, numpy as np
from scipy.io import wavfile

port_name = sys.argv[1] if len(sys.argv) > 1 else "COM5"
out_name  = sys.argv[2] if len(sys.argv) > 2 else "my_recording.wav"

raw = bytearray()
with serial.Serial(port_name, 921600, timeout=2) as port:
    print("press and hold BTNC, speak, release ...")
    while len(raw) < 2 * 16000 * 30:                        # up to 30 s
        chunk = port.read(4096)
        if not chunk and raw:                               # 2 s without data after recording → done
            break
        raw += chunk

x = np.frombuffer(bytes(raw[: len(raw) // 2 * 2]), dtype="<i2")   # little-endian int16
wavfile.write(out_name, 16000, x)
print(f"saved {len(x) / 16000:.1f} s to {out_name}")
