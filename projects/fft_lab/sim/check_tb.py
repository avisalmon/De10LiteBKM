"""Run the FFT lab's system testbench (sim/tb_fft_lab.sv) and check what it produced against the model.

The testbench checks the controls, LEDs, digits, buzzer and timing itself, and logs every published frame (PUB),
screen picture (SHOT) and report line (REPORT). This script replays that log through the model (sim/lab_model.py)
with one wave generator, as the hardware ran it (the noise generator runs on from frame to frame), and with the
IP's state (MODE = what the stand-in IP was told to do, RESTART = the IP was restarted):
  PUB     the frame's settings, and whether the IP answered right (ok) or was given up on (dead), as the model says
  SHOT    every pixel of the 320 x 240 picture equals the model's picture (sim/work/<name>_diff.png if not)
  REPORT  the 126 characters equal the model's report line
  python projects/fft_lab/sim/check_tb.py              (runs the testbench first: about 4 minutes)
  python projects/fft_lab/sim/check_tb.py --no-run     (only checks the last run's log and pictures)
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
import lab_model as m  # noqa: E402

TB = os.path.join(HERE, "tb_fft_lab.sv")
LOG = os.path.join(HERE, "tb_fft_lab.log")
WORK = os.path.join(HERE, "work")


def run_testbench():
    r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "sim.py"), TB], cwd=ROOT,
                       capture_output=True, text=True, timeout=1800)
    out = r.stdout + r.stderr
    fails = [l for l in out.splitlines() if "FAIL" in l]
    if r.returncode != 0 or "PASS" not in out or fails:
        print(out[-4000:])
        sys.exit("FAIL: the testbench did not pass")
    checks = sum(1 for l in out.splitlines() if l.startswith("ok:"))
    print(f"OK: the testbench passed ({checks} checks)")


def check_log():
    cases = m.load_ip_vectors()
    if not cases:
        sys.exit("FAIL: no sim/ip_vectors.hex (run sim/record_ip.py)")
    gen = m.Gen()
    mode, dead, st = 0, False, None
    errors, pubs, shots, reports = [], 0, 0, 0
    for n, line in enumerate(open(LOG, encoding="ascii"), 1):
        line = line.rstrip("\n")
        word, _, rest = line.partition(" ")
        if word == "PUB":
            case, ok, dd = rest.split()
            fault = "dead" if dead or mode == 1 else "zero" if mode == 2 else None
            st = m.frame_state(case, gen, cases, ip_fault=fault)
            if st["ip"] is None:                     # no recording: the stand-in does not answer, the watchdog acts
                st["ip"] = m.ip_failed(st["xw"], "dead")
            dead = st["ip"]["dead"]
            want = (0 if st["ip"]["bad"] else 1, 1 if dead else 0)
            if (int(ok), int(dd)) != want:
                errors.append(f"line {n}: {case}: IP ok/dead {ok}/{dd}, the model says {want[0]}/{want[1]}")
            pubs += 1
        elif word == "SHOT":
            name, hold, sound = rest.split()
            if st is None:
                errors.append(f"line {n}: a picture before any frame")
                continue
            want = dict(st, hold=int(hold), sound=int(sound))
            os.makedirs(WORK, exist_ok=True)
            diff = os.path.join(WORK, name.replace(".ppm", "_diff.png"))
            bad = m.compare(want, m.read_ppm(os.path.join(HERE, name)))
            if bad:
                m.compare(want, m.read_ppm(os.path.join(HERE, name)), diff)
                errors.append(f"line {n}: {name} ({m.case_name(st)}): {len(bad)} of {m.W * m.H} pixels differ, "
                              f"first {bad[:3]}, see {os.path.relpath(diff, ROOT)}")
            else:
                print(f"OK: {name:20s} {m.case_name(st):13s} hold {hold} sound {sound}: "
                      f"all {m.W * m.H} pixels equal the model")
            shots += 1
        elif word == "REPORT":
            hold, _, text = rest.partition(" ")
            want = m.report_line(dict(st, hold=int(hold)))
            if text != want:
                errors.append(f"line {n}: report\n  got  {text}\n  want {want}")
            reports += 1
        elif word == "MODE":
            mode = int(rest)
        elif word == "RESTART":
            dead = False
        elif line:
            errors.append(f"line {n}: unknown: {line}")
    return errors, pubs, shots, reports


def main(argv):
    if "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0
    if "--no-run" not in argv:
        run_testbench()
    if not os.path.exists(LOG):
        sys.exit(f"FAIL: no {os.path.relpath(LOG, ROOT)} (run without --no-run)")
    errors, pubs, shots, reports = check_log()
    for e in errors:
        print("FAIL: " + e)
    if errors or not pubs or not shots or not reports:
        print(f"FAIL: {len(errors)} differences ({pubs} frames, {shots} pictures, {reports} report lines)")
        return 1
    print(f"OK: {pubs} frames, {shots} pictures and {reports} report lines equal the model")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
