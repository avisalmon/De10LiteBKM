"""Load a program into the running FPGA over JTAG, without rebuilding: hold the CPU, rewrite the RAM, reset.

    python tools/load.py build/tetris.mif          (from the project folder, board programmed with the SoC)
Steps: 'H' over the USB link (the CPU stops, LEDR9 blinks), the In-System Memory Content Editor writes the .mif into
the RAM instance PROG (scripts/mem_edit.tcl), 'R' resets the CPU, which starts the new program at address 0.
About 10 s in all; a Quartus rebuild would take 4 minutes.
"""
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
ROOT = PROJECT.parent.parent
PY = sys.executable
DE10 = str(ROOT / "scripts" / "de10.py")


def send(letter):
    return subprocess.run([PY, DE10, "send", letter, "0.3"], capture_output=True, text=True).returncode


def main(argv=None):
    mif = Path(argv[0] if argv else (sys.argv[1] if len(sys.argv) > 1 else "build/tetris.mif")).resolve()
    if mif.suffix != ".mif":
        print("give the .mif (tools/asm.py writes one next to the .hex)")
        return 2
    sys.path.insert(0, str(ROOT / "scripts"))
    import de10  # noqa: E402  (tool() finds quartus_stp)
    print("hold the CPU ...")
    send("H")
    print(f"write {mif.name} into PROG ...")
    r = subprocess.run([de10.tool("quartus_stp"), "-t", str(ROOT / "scripts" / "mem_edit.tcl"), "write", "PROG", str(mif)],
                       cwd=PROJECT, capture_output=True, text=True)
    ok = "OK:" in r.stdout
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()[-300:])
    print("reset and run ...")
    send("R")
    print("OK: running" if ok else "FAIL: the memory write did not report OK (is the board programmed with the SoC?)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
