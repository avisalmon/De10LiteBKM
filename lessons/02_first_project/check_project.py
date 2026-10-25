#!/usr/bin/env python
"""Lesson 2: check the student's Quartus project before it is compiled. Read-only: changes nothing.

    python lessons/02_first_project/check_project.py <project folder>            the first task: sw0 -> led0
    python lessons/02_first_project/check_project.py <project folder> --change   also sw9 -> led9

Reads the project's .qsf (where Quartus keeps the settings) and checks the device, the top-level entity, and each
pin with its I/O standard. Every FAIL says what to fix and where in Quartus. Exit code 0 = ready to compile.
"""

import re
import sys
from pathlib import Path

DEVICE = "10M50DAF484C7G"
PINS = {"sw0": "PIN_C10", "led0": "PIN_A8"}
CHANGE = {"sw9": "PIN_F15", "led9": "PIN_B11"}
IO_STANDARD = "3.3-V LVTTL"


def setting(qsf, name):
    m = re.search(rf"^\s*set_global_assignment\s+-name\s+{name}\s+\"?([^\"\n]+?)\"?\s*$", qsf, re.M)
    return m.group(1).strip() if m else None


def assignments(qsf, name):
    """{node: value} for lines like: set_location_assignment PIN_C10 -to sw0 / set_instance_assignment ... -to sw0"""
    found = {}
    if name == "LOCATION":
        for value, node in re.findall(r"^\s*set_location_assignment\s+(\S+)\s+-to\s+\"?([^\s\"]+)\"?", qsf, re.M):
            found[node] = value
    else:
        for value, node in re.findall(rf"^\s*set_instance_assignment\s+-name\s+{name}\s+\"([^\"]+)\"\s+-to\s+\"?([^\s\"]+)\"?", qsf, re.M):
            found[node] = value
    return found


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    folder = Path(argv[0])
    qsfs = sorted(folder.glob("*.qsf"))
    if not qsfs:
        print(f"FAIL  no .qsf in {folder}\n      -> finish the New Project Wizard (File > New Project Wizard) and save it in this folder")
        return 1
    qsf = qsfs[0].read_text(encoding="utf-8", errors="replace")
    fails = 0

    def report(ok, what, fix=""):
        nonlocal fails
        print(f"{'OK  ' if ok else 'FAIL'}  {what}" + ("" if ok or not fix else f"\n      -> {fix}"))
        fails += not ok

    device = setting(qsf, "DEVICE")
    report(device == DEVICE, f"device {device or '(none)'}",
           f"Assignments > Device: family MAX 10, then pick {DEVICE} in the list")
    top = setting(qsf, "TOP_LEVEL_ENTITY")
    report(top == "first_led", f"top-level entity {top or '(none)'}",
           "the project's top-level entity must be first_led: Assignments > Settings > General")
    files = re.findall(r"^\s*set_global_assignment\s+-name\s+(?:SYSTEMVERILOG|VERILOG)_FILE\s+\"?([^\"\n]+?)\"?\s*$", qsf, re.M)
    report(any(Path(f).name == "first_led.sv" for f in files), "first_led.sv is in the project",
           "Project > Add/Remove Files in Project, add first_led.sv")

    wanted = dict(PINS, **(CHANGE if "--change" in argv else {}))
    where = assignments(qsf, "LOCATION")
    standard = assignments(qsf, "IO_STANDARD")
    for node, pin in wanted.items():
        got = where.get(node)
        report(got == pin, f"{node} on {got or '(no pin)'}",
               f"Pin Planner (Assignments > Pin Planner): Location of {node} = {pin.replace('PIN_', '')}")
        report(standard.get(node) == IO_STANDARD, f"{node} I/O standard {standard.get(node, '(default)')}",
               f"Pin Planner: I/O Standard of {node} = {IO_STANDARD}")

    print("\nReady to compile." if not fails else f"\n{fails} thing(s) to fix before compiling.")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
