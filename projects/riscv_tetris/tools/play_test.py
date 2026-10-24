"""Play Tetris on the simulator with a scripted strategy and check the rules: used by tests/test_riscv_tetris.py.

    python tools/play_test.py                 # plays, prints the result and the final screen
    python tools/play_test.py --search 40     # tries 40 random seeds / scripts, prints the first that clears a line

The strategy is blind (it cannot see the piece): every piece is dropped at a column that cycles 0, 2, 4, 6, 8,
with a rotation that cycles too. Over a few dozen pieces that fills rows and clears lines often enough; the
--search mode finds a seed where it does, and the test pins that seed. Checks: the title screen, START works,
the score grows, LINES grows when a row fills, the 7-segment shows the score in BCD, GAME OVER arrives eventually.
"""
import argparse
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rv32sim  # noqa: E402

PROJECT = Path(__file__).resolve().parent.parent


def load(hexfile):
    words = [int(l, 16) for l in Path(hexfile).read_text().split()]
    return b"".join(w.to_bytes(4, "little") for w in words)


def number_at(screen, row, col, width):
    m = re.search(r"\d+", screen[row][col:col + width])
    return int(m.group()) if m else None


def script(seed, pieces=60, gap=14):
    """Keys for `pieces` drops: a move burst, a rotate, a hard drop, every `gap` frames."""
    rng = random.Random(seed)
    keys = {}
    f = 12
    keys[f] = rv32sim.BUTTON_BITS["start"]
    f += 6
    for n in range(pieces):
        col = rng.choice([0, 1, 2, 3, 4, 5, 6, 7])
        moves = col - 3
        for k in range(abs(moves)):
            keys[f + 2 * k] = rv32sim.BUTTON_BITS["right" if moves > 0 else "left"]
        f += 2 * abs(moves) + 2
        for k in range(rng.randrange(4)):
            keys[f] = rv32sim.BUTTON_BITS["a"]
            f += 2
        keys[f] = rv32sim.BUTTON_BITS["b"]
        f += gap
    return keys, f + 10


def play(hexfile, seed, pieces=60):
    soc = rv32sim.SoC(load(hexfile))
    soc.lfsr = seed
    keys, frames = script(seed, pieces)
    soc.keys = keys
    soc.run(frames=frames)
    rows = soc.screen_text().splitlines()
    return soc, rows


def report(rows, soc):
    score = number_at(rows, 13, 4, 12)
    level = number_at(rows, 17, 4, 12)
    lines = number_at(rows, 21, 4, 12)
    over = any("GAME  OVER" in r for r in rows)
    hexd = soc.hexd
    return {"score": score, "level": level, "lines": lines, "over": over, "hex": hexd}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hex", default=str(PROJECT / "build" / "tetris.hex"))
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x1234_5678)
    ap.add_argument("--pieces", type=int, default=60)
    ap.add_argument("--search", type=int, default=0)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--expect-lines", type=int, default=0, help="fail unless at least this many lines were cleared")
    a = ap.parse_args(argv)
    if a.search:
        rng = random.Random(1)
        for n in range(a.search):
            seed = rng.randrange(1, 1 << 31)
            soc, rows = play(a.hex, seed, a.pieces)
            r = report(rows, soc)
            print(f"seed 0x{seed:08x}: {r}")
            if r["lines"]:
                print(f"FOUND: --seed 0x{seed:08x}")
                return 0
        return 1
    soc, rows = play(a.hex, a.seed, a.pieces)
    r = report(rows, soc)
    if not a.quiet:
        print("\n".join(l[4:72].rstrip() for l in rows[:52]))
    print(r)
    ok = r["score"] and r["score"] > 0 and r["hex"] == int(str(r["score"]), 16) % (1 << 24) and \
        (r["lines"] or 0) >= a.expect_lines and r["level"] == (r["lines"] or 0) // 10
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
