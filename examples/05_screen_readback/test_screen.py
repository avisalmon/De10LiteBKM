"""Board test for example 05: move the box, read the screen back, compare every pixel with the simulation.

  python examples/05_screen_readback/test_screen.py        (the board must run screen_readback.sof)

For each step: send commands over USB, capture the screen (scripts/de10.py screen), render the same position in
simulation (sim/tb_frame.sv), and compare (scripts/screen_check.py). Captures and diffs go to logs/.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import de10  # noqa: E402

PY = sys.executable
STEPS = [("H", 64, 192), ("RRDD", 128, 256), ("UUUUUULL", 64, 64)]


def simulate(bx, by):
    rc = subprocess.call([PY, "-I", os.path.join(ROOT, "scripts", "sim.py"),
                          os.path.join(HERE, "sim", "tb_frame.sv"), "-D", f"BX={bx}", "-D", f"BY={by}"],
                         stdout=subprocess.DEVNULL)
    ppm = os.path.join(HERE, "sim", "expected.ppm")
    png = os.path.join(HERE, "logs", f"expected_{bx}_{by}.png")
    from PIL import Image
    Image.open(ppm).convert("RGB").save(png)		# Pillow already scales the PPM (max 15) to 0..255
    return rc, png


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
    failures = 0
    for cmds, bx, by in STEPS:
        de10.uart_session(cmds, 1.5, echo=False)
        cap = os.path.join(HERE, "logs", f"capture_{bx}_{by}.png")
        de10.screen(cap)
        rc, exp = simulate(bx, by)
        r = subprocess.call([PY, "-I", os.path.join(ROOT, "scripts", "screen_check.py"), cap, exp,
                             "--diff", os.path.join(HERE, "logs", f"diff_{bx}_{by}.png")])
        print(f"step '{cmds}' -> box ({bx}, {by}): {'match' if r == 0 else 'MISMATCH'}")
        failures += (r != 0)
    print("OK: every capture matches the simulation" if failures == 0 else f"FAIL: {failures} steps differ")
    sys.exit(1 if failures else 0)
