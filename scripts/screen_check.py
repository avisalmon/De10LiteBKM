"""Compare a screen capture from the board with an expected picture: an automatic test for graphics.

  python scripts/screen_check.py <capture.png> <expected.png> [--tolerance N] [--diff out.png]

Both pictures are compared at the capture's size (320x240 from debug_link STEP 2); the expected one is scaled with
nearest-neighbour if needed and both are cut to 12-bit colour (RGB444) first. A pixel differs when any colour
channel differs by more than --tolerance (in 4-bit steps, default 0). Prints the number of differing pixels and
writes a diff picture (differences in red over a dimmed capture). Exit code 0 = match.
"""
import argparse
import sys

from PIL import Image


def rgb444(im):
    return im.convert("RGB").point(lambda v: v >> 4)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("expected")
    ap.add_argument("--tolerance", type=int, default=0)
    ap.add_argument("--diff", default=None)
    a = ap.parse_args()
    cap = Image.open(a.capture).convert("RGB")
    exp = Image.open(a.expected).convert("RGB")
    w, h = 320, 240
    cap = cap.resize((w, h), Image.NEAREST) if cap.size != (w, h) else cap
    exp = exp.resize((w, h), Image.NEAREST) if exp.size != (w, h) else exp
    c4, e4 = rgb444(cap), rgb444(exp)
    cp, ep = list(c4.getdata()), list(e4.getdata())
    bad = [i for i, (p, q) in enumerate(zip(cp, ep)) if max(abs(x - y) for x, y in zip(p, q)) > a.tolerance]
    if a.diff:
        d = cap.point(lambda v: v // 3)
        px = d.load()
        for i in bad:
            px[i % w, i // w] = (255, 0, 0)
        d.resize((w * 2, h * 2), Image.NEAREST).save(a.diff)
    print(f"{len(bad)} of {w * h} pixels differ" + (f" (first at x={bad[0] % w}, y={bad[0] // w})" if bad else ""))
    print("OK: the screen matches" if not bad else "FAIL: the screen does not match")
    sys.exit(0 if not bad else 1)
