"""The result the MAC engines must produce: the same LFSRs as src/mac.sv, in Python.

  python examples/12_dsp_multipliers/sim/mac_reference.py [N]     (default N = 1,000,000)
Prints the 48-bit accumulator in hex, as the board prints it.
"""
import sys


def step(v):
    return (v >> 1) ^ 0x80200003 if v & 1 else v >> 1


def s18(v):
    v &= 0x3FFFF
    return v - 0x40000 if v & 0x20000 else v


def mac(n):
    la, lb, acc = 0x12345678, 0x9ABCDEF1, 0
    for _ in range(n):
        acc += s18(la) * s18(lb)
        la, lb = step(la), step(lb)
    return acc & ((1 << 48) - 1)


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
    print(f"N={n} acc={mac(n):012X}")
