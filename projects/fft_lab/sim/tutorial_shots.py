"""The tutorial's pictures (tutorial.html), read back from the real board and checked against the model.

  python projects/fft_lab/sim/tutorial_shots.py      (after build and program, with quartus_pgm still running; ~3 min)

For each picture it sets the case over USB, captures the screen between two report lines (again if the settings changed
during the capture: someone turned the wheel or pressed a button), compares the picture with the model
(sim/lab_model.py compare: every pixel; the IP's panel only for the cases recorded in ModelSim) and copies it to
media/tutorial_<name>.png. At the end it puts back the shape, frequency, window, scale and hold that were set before
(the sound stays off). The tutorial also uses the overview's pictures (media/screen_*.png, made by board_check.py).
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from board_check import DE10, MODEL, PROJ, TRIES, fields, report, run  # noqa: E402
from record_ip import CASES as RECORDED  # noqa: E402

MEDIA = os.path.join(PROJ, "media")
OUT = os.path.join(PROJ, "logs", "tutorial")
SHOTS = [("between_lin", "S0N84W0L1"), ("hann_on_bin", "S0N80W1L0"), ("square_lin", "S1N80W0L1"),
         ("triangle", "S2N80W0L0"), ("saw", "S3N80W0L0"), ("spikes_p32", "S4N64W0L0"), ("spikes_p8", "S4N256W0L0"),
         ("spikes_jitter", "S4N80W0L0"), ("nyquist", "S0N1000W0L0"), ("square_3k", "S1N240W0L0")]


def setting(line, key):
    return int(next(f for f in line.split() if f.startswith(key + "=")).split("=", 1)[1])


def shoot(name, case):
    """One picture: (ok, what happened)."""
    rec = case in RECORDED
    _, want = run(MODEL, "report", case)
    want = want.strip()
    png = os.path.join(OUT, case + ".png")
    for attempt in range(1, TRIES + 1):
        run(DE10, "send", "H0M0" + case, "1")
        before = report()
        run(DE10, "screen", png)
        after = report()
        steady = before != "" and fields(before, True)[:8] == fields(after, True)[:8]
        line_ok = before != "" and fields(before, rec) == fields(want, rec)
        if steady and line_ok:
            break
    _, cmp_out = run(MODEL, "compare", case, png[:-4] + ".txt", os.path.join(OUT, case + "_diff.png"))
    verdict = cmp_out.strip().splitlines()[-1] if cmp_out.strip() else "no compare output"
    ok = steady and line_ok and verdict.startswith("OK")
    if ok:
        shutil.copyfile(png, os.path.join(MEDIA, f"tutorial_{name}.png"))
    return ok, f"{name:14s} {case:12s} tries={attempt} line={'OK' if line_ok else 'DIFF'} | {verdict}\n   {before}"


def main():
    first = report()
    if not first:
        sys.exit("FAIL: no FFTLAB line from the board: is fft_lab programmed, and is quartus_pgm still running?")
    os.makedirs(OUT, exist_ok=True)
    results = []
    for name, case in SHOTS:
        ok, text = shoot(name, case)
        results.append(ok)
        print(text, flush=True)
    back = "S{}N{}W{}L{}H{}".format(*(setting(first, k) for k in ("SHAPE", "N", "WIN", "LIN", "HOLD")))
    run(DE10, "send", back, "1")
    print(f"settings put back: {back}")
    print(f"{'PASS' if all(results) else 'FAIL'}: {sum(results)}/{len(results)} pictures equal the model "
          f"and are in media/tutorial_*.png")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
