"""Compare two execution traces (Python simulator vs RTL) line by line: the first difference, with context.

    python tools/trace_compare.py build/test_c.trc build/test_c_rtl.trc
Lines are "pc rd value" (a register write) or "pc W addr value mask" (a store). Reads of FRAME / CYCLES / RANDOM
differ by nature; programs under lock-step test must not depend on them (test_c.c only checks they are >= 0, and
the compare skips register writes whose value came straight from those registers: see --ignore-pc).
"""
import argparse
import sys
from pathlib import Path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--context", type=int, default=5)
    args = ap.parse_args(argv)
    la = Path(args.a).read_text().splitlines()
    lb = Path(args.b).read_text().splitlines()
    n = min(len(la), len(lb))
    for i in range(n):
        if la[i] != lb[i]:
            # the simulator marks a value read from a time / random register with "~": only pc and rd must match
            pa, pb = la[i].split(), lb[i].split()
            if len(pa) == 4 and pa[3] == "~" and len(pb) == 3 and pa[:2] == pb[:2]:
                continue
            if len(pa) == 6 and pa[5] == "~" and len(pb) == 5 and pa[:3] == pb[:3] and pa[4] == pb[4]:
                continue                # a store of a time-dependent value: address and bytes must match
            # a store: only the enabled bytes count (the RTL may replicate a byte / half across the bus)
            if len(pa) == 5 and len(pb) == 5 and pa[1] == "W" and pa[:3] == pb[:3] and pa[4] == pb[4]:
                be = int(pa[4], 16)
                mask = sum(0xFF << (8 * k) for k in range(4) if be >> k & 1)
                if int(pa[3], 16) & mask == int(pb[3], 16) & mask:
                    continue
            print(f"DIFF at line {i + 1}:")
            for j in range(max(0, i - args.context), min(n, i + args.context + 1)):
                mark = ">>" if j == i else "  "
                print(f"{mark} {j + 1:7d}  {la[j]:40s} | {lb[j]}")
            return 1
    if len(la) != len(lb):
        print(f"DIFF: {args.a} has {len(la)} lines, {args.b} has {len(lb)} (the first {n} match)")
        longer = la if len(la) > len(lb) else lb
        for j in range(n, min(n + args.context, len(longer))):
            print(f"   {j + 1:7d}  {longer[j]}")
        return 1
    print(f"OK: {n} trace lines identical")
    return 0


if __name__ == "__main__":
    sys.exit(main())
