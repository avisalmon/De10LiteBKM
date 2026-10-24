#!/usr/bin/env python
"""Check that this computer (and the real thing) are ready, and say exactly what to fix. Read-only: changes nothing.

    python scripts/doctor.py           # the computer: Python, env, tools
    python scripts/doctor.py --real    # + the real thing this BKM is about

Each line is OK, WARN or FAIL, and every FAIL says what to do. Exit code 0 = no FAIL.
The chat runs this at the start, after setup, and whenever something does not work. Anything diagnosed by hand
more than once belongs in here (improve-this-guide skill).
"""

import argparse
import importlib.metadata
import os
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Every package the BKM needs, by its pip name. Keep in step with requirements.txt.
PACKAGES = ["pillow"]
# Quartus Prime Lite 17.1 and the ModelSim that installs with it (same places scripts/de10.py and sim.py look)
QUARTUS = Path(os.environ.get("DE10_QUARTUS", r"C:\intelFPGA_lite\17.1\quartus"))
MODELSIM = Path(os.environ.get("MODELSIM_BIN", r"C:\intelFPGA_lite\17.1\modelsim_ase\win32aloem"))
INSTALL_FIX = "install Quartus Prime Lite 17.1 with ModelSim and MAX 10 support (lesson 0, slide 9)"

results = []


def report(level, what, fix=""):
    results.append(level)
    line = f"{level:4}  {what}"
    if fix:
        line += f"\n      -> {fix}"
    print(line, flush=True)


def check_computer():
    system = platform.system()
    if system == "Windows":
        report("OK", f"Windows {platform.release()} ({platform.machine()})")
    else:
        report("WARN", f"{system}: this BKM is tested on Windows; the chat will adapt the steps")

    if sys.version_info >= (3, 10):
        report("OK", f"Python {platform.python_version()}")
    else:
        report("FAIL", f"Python {platform.python_version()} is too old", "install Python 3.12 (setup-my-computer)")

    env = ROOT / "env"
    if Path(sys.prefix).resolve() == env.resolve():
        report("OK", "running inside the project's env")
    elif env.exists():
        report("WARN", "env exists but this run is outside it", r"run with .\env\Scripts\python.exe")
    else:
        report("FAIL", "no env folder yet", "python -m venv env, then env's pip install -r requirements.txt")

    for package in PACKAGES:
        try:
            report("OK", f"{package} {importlib.metadata.version(package)}")
        except importlib.metadata.PackageNotFoundError:
            report("FAIL", f"{package} is not installed in this Python", "pip install -r requirements.txt (inside env)")

    quartus_sh = QUARTUS / "bin64" / "quartus_sh.exe"
    if quartus_sh.exists():
        done = subprocess.run([str(quartus_sh), "--version"], capture_output=True, text=True, errors="replace")
        version = next((l.strip() for l in done.stdout.splitlines() if l.startswith("Version")), "version unknown")
        if "17.1" in version and "Lite" in version:
            report("OK", f"Quartus Prime {version.replace('Version ', '')}")
        else:
            report("WARN", f"Quartus found but not 17.1 Lite: {version}", "the lessons are tested on 17.1 Lite")
    else:
        report("FAIL", f"Quartus not found in {QUARTUS}", INSTALL_FIX)

    if (QUARTUS / "common" / "devinfo" / "55nm" / "zb50_non_vr_analog").is_dir():
        report("OK", "MAX 10 device support (the DE10-Lite's chip)")
    elif quartus_sh.exists():
        report("FAIL", "Quartus has no MAX 10 device support",
               "run the max10-17.1.0.590.qdz install (put it next to QuartusLiteSetup and re-run setup)")

    if (MODELSIM / "vsim.exe").exists():
        report("OK", "ModelSim-Intel Starter (the simulator)")
    else:
        report("FAIL", f"ModelSim not found in {MODELSIM}", INSTALL_FIX)


def check_real_thing():
    """The board on the USB-Blaster cable, seen through Quartus' JTAG server."""
    jtagconfig = QUARTUS / "bin64" / "jtagconfig.exe"
    if not jtagconfig.exists():
        report("FAIL", "cannot look for the board: Quartus is missing", INSTALL_FIX)
        return
    out = subprocess.run([str(jtagconfig)], capture_output=True, text=True, errors="replace").stdout
    if "USB-Blaster" not in out:
        report("FAIL", "no USB-Blaster cable found",
               "plug the board's USB cable in (the port next to the power jack); if it is in, install the driver: "
               "Device Manager > USB-Blaster > Update driver > Browse > " + str(QUARTUS / "drivers"))
    elif "10M50" not in out:
        report("FAIL", "the cable is there but no MAX 10 chip answers",
               "check that the board is powered (its power LED is on); unplug and plug the USB cable")
    else:
        report("OK", "DE10-Lite found on the USB-Blaster (10M50)")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--real", action="store_true", help="also check the real thing")
    args = parser.parse_args(argv)
    print("Doctor\n------")
    check_computer()
    if args.real:
        check_real_thing()
    failed = results.count("FAIL")
    print(f"\n{failed} FAIL, {results.count('WARN')} WARN" if failed else "\nAll good.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
