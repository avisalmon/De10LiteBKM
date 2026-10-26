"""Board proof for the FFT lab: the real board's screen and report line against the model, case by case.

  python projects/fft_lab/sim/board_check.py        (after build and program, with quartus_pgm still running; ~4 min)

Per case it sets the case over USB (scripts/de10.py send), reads the report line ('R'), captures the screen
('F', scripts/de10.py screen), reads 'R' again, and compares both with the model (sim/lab_model.py report / compare).
If the settings changed during the capture (someone turned the wheel or pressed a button), the case is tried again.
The cases recorded from the real IP in ModelSim (record_ip.CASES, sim/ip_vectors.hex) compare every pixel and every
field; the other cases leave the IP panel and the IP_ fields out. Noise is random: only its clocks and IP_OK are checked.
Writes logs/board/<case>.png (and .txt, the raw dump), <case>_diff.png and board_check.txt.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PROJ))
sys.path.insert(0, HERE)
from record_ip import CASES as RECORDED  # noqa: E402

PY = sys.executable
DE10 = os.path.join(ROOT, "scripts", "de10.py")
MODEL = os.path.join(HERE, "lab_model.py")
OUT = os.path.join(PROJ, "logs", "board")
OTHERS = ["S1N517W1L0", "S4N7W0L1", "S2N333W1L1", "S3N1W0L0"]
TRIES = 4


def run(*args, timeout=180):
    r = subprocess.run([PY, *args], capture_output=True, text=True, cwd=ROOT, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


def report():
    _, out = run(DE10, "send", "R", "2")
    return next((l.strip() for l in out.splitlines() if l.startswith("FFTLAB")), "")


def fields(line, ip):
    return [f for f in line.split() if ip or not f.startswith("IP_")]


def main():
    os.makedirs(OUT, exist_ok=True)
    if not report():
        sys.exit("FAIL: no FFTLAB line from the board: is fft_lab programmed, and is quartus_pgm still running "
                 "(the evaluation IP stops when it is not)?")
    log, rows, t0 = [], [], time.time()

    def say(s):
        print(s, flush=True)
        log.append(s)

    for case in RECORDED + OTHERS:
        rec = case in RECORDED
        _, want = run(MODEL, "report", case)
        want = want.strip()
        png = os.path.join(OUT, case + ".png")
        for attempt in range(1, TRIES + 1):
            run(DE10, "send", "H0M0" + case, "1")
            time.sleep(0.3)
            before = report()
            run(DE10, "screen", png)
            after = report()
            steady = before != "" and fields(before, True)[:8] == fields(after, True)[:8]
            line_ok = before != "" and fields(before, rec) == fields(want, rec)
            if steady and line_ok:
                break
            say(f"{case:12s} try {attempt}: {'settings changed during the capture' if not steady else 'report differs'}"
                f"\n   board: {before}\n   after: {after}\n   model: {want}")
        _, cmp_out = run(MODEL, "compare", case, png[:-4] + ".txt", os.path.join(OUT, case + "_diff.png"))
        verdict = cmp_out.strip().splitlines()[-1] if cmp_out.strip() else "no compare output"
        ok = steady and line_ok and verdict.startswith("OK")
        rows.append(ok)
        say(f"{case:12s} {'rec' if rec else 'new'} tries={attempt} line={'OK' if line_ok else 'DIFF'} | {verdict}")
        say(f"   {before}")

    run(DE10, "send", "H0M0S5N80W1L0", "1")
    time.sleep(0.3)
    noise = report()
    noise_ok = "OUR_CLK=06145" in noise and "IP_CLK=01637" in noise and "IP_OK=1" in noise
    say(f"S5N80W1L0    noise line={'OK' if noise_ok else 'DIFF'} (random: only the clocks and IP_OK are checked)"
        f"\n   {noise}")
    run(DE10, "screen", os.path.join(OUT, "S5N80W1L0.png"))
    run(DE10, "send", "D", "1")

    ok = all(rows) and noise_ok
    say(f"{'PASS' if ok else 'FAIL'}: {sum(rows)}/{len(rows)} cases with the report line and every pixel as the model "
        f"({len(RECORDED)} with the IP recorded in ModelSim), noise {'OK' if noise_ok else 'DIFF'}, "
        f"{time.time() - t0:.0f} s, {time.strftime('%Y-%m-%d %H:%M')}")
    with open(os.path.join(OUT, "board_check.txt"), "w", encoding="ascii") as f:
        f.write("\n".join(log) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
