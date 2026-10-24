"""Build a program for the SoC: C (and .s) sources -> build/<name>.hex / .mif / .s / .sym

    python tools/build.py sw/tetris.c                     # -> build/tetris.*
    python tools/build.py sw/test_c.c -o build/test_c
    python tools/build.py sw/test_isa.s                   # assembly only: no crt0
C sources are compiled by tools/cc.py (all of them as one unit), sw/crt0.s goes first so _start is at 0, then
tools/asm.py assembles everything. Then: tools/rv32sim.py build/<name>.hex to run it on the PC,
python scripts/de10.py ... / tools/load.py to run it on the board.
"""
import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
PY = sys.executable


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("sources", nargs="+")
    ap.add_argument("-o", "--out")
    ap.add_argument("-D", action="append", default=[], dest="define")
    ap.add_argument("--assets", action="store_true",
                    help="also copy the .hex / .mif into assets/ (the image the FPGA build and the .qar carry)")
    a = ap.parse_args(argv)
    out = Path(a.out) if a.out else PROJECT / "build" / Path(a.sources[0]).stem
    out.parent.mkdir(parents=True, exist_ok=True)
    c_files = [s for s in a.sources if s.endswith(".c")]
    s_files = [s for s in a.sources if s.endswith(".s")]
    if c_files:
        cmd = [PY, str(HERE / "cc.py"), *c_files, "-o", str(out) + "_c.s", "-I", str(PROJECT / "sw")]
        for d in a.define:
            cmd += ["-D", d]
        if subprocess.run(cmd).returncode:
            return 1
        parts = [PROJECT / "sw" / "crt0.s", Path(str(out) + "_c.s"), *map(Path, s_files)]
    else:
        parts = [Path(s) for s in s_files]
    combined = "\n".join(f"# ---- {p.name}\n" + p.read_text(encoding="utf-8") for p in parts)
    Path(str(out) + ".s").write_text(combined, encoding="utf-8", newline="\n")
    rc = subprocess.run([PY, str(HERE / "asm.py"), str(out) + ".s", "-o", str(out)]).returncode
    if rc == 0 and a.assets:
        import shutil
        for ext in (".hex", ".mif"):
            shutil.copy2(str(out) + ext, PROJECT / "assets" / (out.stem + ext))
        print(f"copied to assets/{out.stem}.hex and .mif")
    return rc


if __name__ == "__main__":
    sys.exit(main())
