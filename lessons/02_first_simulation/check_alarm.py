"""Lesson 2 checker: is the student's door alarm right, and is their testbench good enough to catch mistakes?

    python lessons/02_first_simulation/check_alarm.py my_designs/lessons/02_first_simulation/alarm --design
    python lessons/02_first_simulation/check_alarm.py my_designs/lessons/02_first_simulation/alarm --tests

The folder is the student's alarm project: src/door_alarm.sv (the design) and sim/tb_door_alarm.sv (their testbench).
--design  runs the checker's own testbench (all 8 combinations) on the student's door_alarm.sv.
--tests   runs the STUDENT'S testbench on four designs: their own and the right one (it must say PASS), and two
          designs with a hidden mistake each (it must say FAIL). A testbench that passes a wrong design misses a
          case: that is the point of the lesson's last task.
Each run is a ModelSim simulation (scripts/sim.py --modelsim) in a scratch folder; nothing in the student's folder
changes. Prints OK / FAIL lines a student can read, and exits 0 only if everything is OK.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SIM = ROOT / "scripts" / "sim.py"
CHECKER = HERE / "checker"


def simulate(tb, design, simulator):
    """Copy a testbench (to sim/) and a door_alarm.sv (to src/) into a scratch folder, simulate, return
    (passed, output, compiled)."""
    with tempfile.TemporaryDirectory(prefix="lesson2_") as tmp:
        tmp = Path(tmp)
        (tmp / "sim").mkdir()
        (tmp / "src").mkdir()
        shutil.copy2(tb, tmp / "sim" / tb.name)
        shutil.copy2(design, tmp / "src" / "door_alarm.sv")
        cmd = [sys.executable, str(SIM), str(tmp / "sim" / tb.name)] + (["--modelsim"] if simulator == "modelsim" else [])
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        passed = r.returncode == 0 and "PASS" in out and "FAIL" not in out.replace("FAIL: testbench", "")
        compiled = "Error" not in out and "error" not in out.split("PASS")[0][-2000:] or passed
        return passed, out, compiled


def lines_with(out, *words):
    return [l.strip().lstrip("# ") for l in out.splitlines() if any(w in l for w in words)]


def check_design(folder, simulator):
    design = folder / "src" / "door_alarm.sv"
    if not design.exists():
        print(f"FAIL: {design} not found")
        return False
    passed, out, _ = simulate(CHECKER / "tb_full.sv", design, simulator)
    if passed:
        print("OK: your door_alarm is right for all 8 combinations of armed, door and window")
        return True
    wrong = lines_with(out, "WRONG")
    if wrong:
        print("FAIL: your door_alarm is still wrong here:")
        for l in wrong:
            print("   " + l)
        print("Rule: the alarm sounds when armed is 1 AND (door OR window) is 1.")
    else:
        print("FAIL: ModelSim could not run your door_alarm.sv. The error:")
        for l in lines_with(out, "Error", "error")[:5]:
            print("   " + l)
    return False


def check_tests(folder, simulator):
    tb = folder / "sim" / "tb_door_alarm.sv"
    if not tb.exists():
        print(f"FAIL: {tb} not found")
        return False
    ok = True
    cases = sum(1 for l in tb.read_text(encoding="utf-8").splitlines() if l.strip().startswith("check("))
    print(f"Your testbench has {cases} test cases.")
    runs = [("your own door_alarm.sv", folder / "src" / "door_alarm.sv", True),
            ("the right door alarm", CHECKER / "door_alarm_ok.sv", True),
            ("wrong design 1 (quiet when the door AND the window are open)", CHECKER / "mutant_xor.sv", False),
            ("wrong design 2 (sounds when it is off but both are open)", CHECKER / "mutant_both_open.sv", False)]
    for name, design, should_pass in runs:
        passed, out, compiled = simulate(tb, design, simulator)
        if not compiled and not passed and not lines_with(out, "WRONG"):
            print(f"FAIL: ModelSim could not run your testbench with {name}. The error:")
            for l in lines_with(out, "Error", "error")[:5]:
                print("   " + l)
            return False
        if passed == should_pass:
            print(f"OK: on {name} your testbench says {'PASS' if passed else 'FAIL'}, as it should")
        else:
            ok = False
            if should_pass:
                print(f"FAIL: on {name} your testbench says FAIL, but that design is right:")
                for l in lines_with(out, "WRONG"):
                    print("   " + l)
                print("   Look at the expected value in that check(...) line.")
            else:
                print(f"FAIL: on {name} your testbench says PASS: it has no test case that catches this mistake.")
                print("   Which combination of armed, door and window is not in your list yet?")
    return ok


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder", help="the student's alarm folder")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--design", action="store_true")
    mode.add_argument("--tests", action="store_true")
    ap.add_argument("--icarus", action="store_true", help="use Icarus instead of ModelSim (the repo's own tests)")
    a = ap.parse_args(argv)
    folder = Path(a.folder).resolve()
    simulator = "icarus" if a.icarus else "modelsim"
    ok = check_design(folder, simulator) if a.design else check_tests(folder, simulator)
    print("ALL OK" if ok else "Not yet: fix the FAIL line(s) and run the check again.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
