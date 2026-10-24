"""Test data and accuracy check for example 11 (256-point FFT: Altera FFT IP vs our own radix-2 FFT).

  python examples/11_fft/sim/fft_data.py make                 -> assets/input.hex, assets/twiddle.hex
  python examples/11_fft/sim/fft_data.py check <dump.txt>     -> accuracy of every FFT result in the dump

Input: three tones (bins 10, 37, 85) and a little noise, real, 16-bit signed, one "RRRRIIII" hex word per line.
A dump holds blocks "<NAME> SCALE=<s>" + 256 lines "RRRRIIII" (natural order) + ...; the FFT value is
word * 2^s (DIY: s = 8, it halves every stage; IP: s = its block exponent). Accuracy = signal-to-error ratio
against numpy's double-precision FFT of the same 16-bit input.
"""
import os
import sys

import numpy as np

N = 256
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "assets")


def signal():
    n = np.arange(N)
    rng = np.random.default_rng(7)
    x = (0.40 * np.cos(2 * np.pi * 10 * n / N) + 0.25 * np.sin(2 * np.pi * 37 * n / N + 0.3)
         + 0.15 * np.cos(2 * np.pi * 85 * n / N) + 0.01 * rng.standard_normal(N))
    return np.round(x * 32767 * 0.95).astype(int)


def h16(v):
    return f"{int(v) & 0xFFFF:04X}"


def make():
    os.makedirs(ASSETS, exist_ok=True)
    x = signal()
    with open(os.path.join(ASSETS, "input.hex"), "w", newline="\n") as f:
        f.write("".join(f"{h16(v)}0000\n" for v in x))
    k = np.arange(N // 2)
    c = np.minimum(np.round(np.cos(2 * np.pi * k / N) * 32767), 32767)
    s = np.minimum(np.round(np.sin(2 * np.pi * k / N) * 32767), 32767)
    with open(os.path.join(ASSETS, "twiddle.hex"), "w", newline="\n") as f:
        f.write("".join(f"{h16(a)}{h16(b)}\n" for a, b in zip(c, s)))
    print(f"OK: assets/input.hex ({N} samples, peak {abs(x).max()}), assets/twiddle.hex ({N // 2} twiddles, Q15)")


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def check(path):
    ref = np.fft.fft(signal().astype(float))
    lines = [l.strip() for l in open(path, encoding="ascii", errors="replace").read().replace("\r", "").split("\n") if l.strip()]
    results = {}
    i = 0
    while i < len(lines):
        if " SCALE=" in lines[i]:
            name, scale = lines[i].split(" SCALE=")
            words = [l for l in lines[i + 1:i + 1 + N] if len(l) == 8]
            if len(words) == N:
                y = np.array([s16(int(w[:4], 16)) + 1j * s16(int(w[4:], 16)) for w in words]) * 2.0 ** int(scale)
                err = y - ref
                snr = 10 * np.log10(np.sum(abs(ref) ** 2) / np.sum(abs(err) ** 2))
                peak = np.argsort(abs(y[:N // 2]))[-3:]
                results[name.strip()] = snr
                print(f"{name.strip():6s} scale 2^{scale}: SNR vs numpy {snr:5.1f} dB, max error {abs(err).max():8.1f} "
                      f"(peak bin magnitude {abs(ref).max():.0f}), strongest bins {sorted(peak.tolist())}")
            i += N
        i += 1
    if not results:
        sys.exit("FAIL: no complete FFT block in the dump")
    return results


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "make":
        make()
    elif len(sys.argv) > 2 and sys.argv[1] == "check":
        check(sys.argv[2])
    else:
        print(__doc__)
