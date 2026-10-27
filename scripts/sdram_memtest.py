"""The SDRAM memory test and read-window sweep of examples/15_sdram_stream_fabric (memtest_top on the board).

  python scripts/sdram_memtest.py info                      what is on the board: clock, phase, SDRAM state
  python scripts/sdram_memtest.py run [options]             one test run (write pass, read pass, or both)
  python scripts/sdram_memtest.py sweep [options]           DRAM_CLK phase x rd_delay: the map of what passes
  python scripts/sdram_memtest.py phase [+N | -N | goto P | reset]   move DRAM_CLK by N steps, or show it
  python scripts/sdram_memtest.py clock                     measure the design's clock from the cycle counter

run options: --base WORD --len WORDS --burst N --pattern 0..3 --seed S --rd-delay D --write-only --read-only
sweep options: --range LO:HI (steps from the compiled phase; default one full DRAM_CLK period, centred)
               --rd-delays 2,3,4,5,6  --patterns 0,2,3  --len WORDS (per pass; default 256K words)
               --stay (leave DRAM_CLK at the best phase instead of resetting the PLL)  --out FILE.json

The design's registers (lib/rtl/sdram_memtest.sv for the test, src/memtest_top.sv for PHASE/INFO/CYCLES) are
reached through lib/rtl/jtag_regs.sv, instance 1 (scripts/jtag_regs.py). One cable user at a time: close
nios2-terminal / de10.py log first.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jtag_regs import JtagRegs  # noqa: E402

ID = 0x4D541501
# the test's registers
R_STATUS, R_CTRL, R_RD_DELAY, R_BASE, R_LEN, R_BURST, R_MODE, R_SEED = range(8)
R_ERRORS, R_ERR_ADDR, R_ERR_DATA, R_ERR_BITS, R_WR_CLOCKS, R_RD_CLOCKS, R_WORDS, R_REFRESHES = range(8, 16)
R_BUSY_CLOCKS, R_ERR_LAST, R_WR_WORDS = 16, 17, 18
# the top's
R_PHASE, R_INFO, R_CYCLES, R_CLK_MHZ = 0x20, 0x21, 0x22, 0x23
PATTERNS = {0: "address", 1: "constant", 2: "random", 3: "toggle"}
WORDS = 1 << 25


class Board:
    def __init__(self, instance=1):
        self.r = JtagRegs(instance)
        got = self.r.id()
        if got != ID:
            self.r.close()
            raise SystemExit(f"FAIL: the design on the board answers ID {got:08X}, memtest_top is {ID:08X}: "
                             "program examples/15_sdram_stream_fabric first")
        info = self.r.peek(R_INFO)
        self.step_ps, self.phase_ps = info >> 16, info & 0xFFFF
        self.clk_mhz = self.r.peek(R_CLK_MHZ)
        self.period_ps = round(1e6 / self.clk_mhz)

    def close(self):
        self.r.close()

    # ---- status ----
    def status(self):
        s = self.r.peek(R_STATUS)
        return dict(init_done=s & 1, running=s >> 1 & 1, finished=s >> 2 & 1, pass_=s >> 3 & 1,
                    rd_delay=s >> 8 & 7, version=s >> 16)

    def phase(self):
        p = self.r.peek(R_PHASE)
        pos = p & 0xFFFF
        if pos & 0x8000:
            pos -= 0x10000
        return dict(pos=pos, ps=pos * self.step_ps, busy=p >> 30 & 1, error=p >> 31 & 1, no_ack=p >> 29 & 1)

    def measure_clock(self, seconds=0.5):
        c0, t0 = self.r.peek(R_CYCLES), time.perf_counter()
        time.sleep(seconds)
        c1, t1 = self.r.peek(R_CYCLES), time.perf_counter()
        return ((c1 - c0) & 0xFFFFFFFF) / (t1 - t0) / 1e6

    # ---- the phase ----
    def step(self, n):
        """Move DRAM_CLK by n steps (negative = earlier); returns the new position."""
        while n:
            k = min(abs(n), 255)
            self.r.poke(R_PHASE, k | (0x100 if n > 0 else 0))
            p = self.r.wait(R_PHASE, 1 << 30, 0, timeout=2.0)
            if p >> 31 & 1:
                raise RuntimeError("the PLL did not answer the phase step (PHASE.error); reset it: phase reset")
            n -= k if n > 0 else -k
        return self.phase()["pos"]

    def goto(self, pos):
        return self.step(pos - self.phase()["pos"])

    def pll_reset(self):
        """Back to the compiled phase; the whole design restarts and the SDRAM re-initialises."""
        self.r.poke(R_PHASE, 1 << 16)
        time.sleep(0.05)
        self.r.wait(R_STATUS, 1, timeout=2.0)
        if self.phase()["pos"] != 0:
            raise RuntimeError("the phase position did not return to 0 after the PLL reset")

    # ---- the test ----
    def run(self, base=0, length=WORDS, burst=1024, pattern=3, seed=0x1234, rd_delay=None, write=True, read=True,
            timeout=10.0):
        if rd_delay is not None:
            self.r.poke(R_RD_DELAY, rd_delay)
        mode = (1 if write else 0) | (2 if read else 0) | (pattern & 3) << 4
        self.r.poke(R_BASE, base, length, burst & 0x7FF, mode, seed)
        self.r.poke(R_CTRL, 1)
        self.r.wait(R_STATUS, 1 << 2, timeout=timeout)
        v = self.r.peek(R_ERRORS, 11)
        d = dict(errors=v[0], err_addr=v[1], expected=v[2] >> 16, got=v[2] & 0xFFFF, err_bits=v[3] & 0xFFFF,
                 wr_clocks=v[4], rd_clocks=v[5], words=v[6], refreshes=v[7], busy_clocks=v[8], err_last=v[9],
                 wr_words=v[10], base=base, len=length, burst=burst or 1024, pattern=pattern, seed=seed,
                 rd_delay=self.status()["rd_delay"], write=write, read=read)
        mhz = self.clk_mhz
        d["wr_mbs"] = d["wr_words"] * 2 * mhz / d["wr_clocks"] if d["wr_clocks"] else 0.0
        d["rd_mbs"] = d["words"] * 2 * mhz / d["rd_clocks"] if d["rd_clocks"] else 0.0
        total = d["wr_clocks"] + d["rd_clocks"]
        d["bus_use"] = d["busy_clocks"] / total if total else 0.0
        d["ok"] = d["errors"] == 0 and (not read or d["words"] == length)
        return d


def show_run(d, clk_mhz):
    what = " + ".join(w for w, on in (("write", d["write"]), ("read", d["read"])) if on)
    print(f"  {what}: pattern {d['pattern']} ({PATTERNS[d['pattern']]}), {d['len']:,} words from {d['base']:#x}, "
          f"bursts of {d['burst']}, rd_delay {d['rd_delay']}")
    parts = []
    if d["write"]:
        parts.append(f"write {d['wr_clocks'] / clk_mhz / 1e3:.3f} ms = {d['wr_mbs']:.1f} MB/s")
    if d["read"]:
        parts.append(f"read {d['rd_clocks'] / clk_mhz / 1e3:.3f} ms = {d['rd_mbs']:.1f} MB/s")
    parts.append(f"bus use {100 * d['bus_use']:.1f} %")
    parts.append(f"{d['refreshes']} refreshes")
    print("  " + ", ".join(parts))
    if d["ok"]:
        print("  PASS: 0 errors")
    else:
        print(f"  FAIL: {d['errors']:,} wrong words; first {d['err_addr']:#09x} expected {d['expected']:04X} "
              f"got {d['got']:04X}; last {d['err_last']:#09x}; DQ bits {d['err_bits']:016b}")


def cmd_info(b, a):
    s, p = b.status(), b.phase()
    print(f"memtest_top ID {ID:08X} version {s['version']}: built for {b.clk_mhz} MHz, "
          f"measured {b.measure_clock():.2f} MHz")
    print(f"DRAM_CLK: compiled phase {b.phase_ps} ps, step {b.step_ps} ps nominal "
          f"({b.period_ps // b.step_ps} steps per period); now {p['pos']:+d} steps = {p['ps']:+d} ps"
          + (", busy" if p["busy"] else "") + (", ERROR" if p["error"] else "")
          + (", no phasedone low seen" if p["no_ack"] else ""))
    print(f"SDRAM: {'ready' if s['init_done'] else 'NOT initialised'}, rd_delay {s['rd_delay']}, "
          f"test {'running' if s['running'] else 'finished' if s['finished'] else 'idle'}"
          + (", last run passed" if s["finished"] and s["pass_"] else ""))


def cmd_clock(b, a):
    print(f"{b.measure_clock(1.0):.3f} MHz (built for {b.clk_mhz} MHz)")


def cmd_run(b, a):
    if not b.status()["init_done"]:
        raise SystemExit("FAIL: the SDRAM is not initialised (STATUS.init_done = 0)")
    d = b.run(a.base, a.len, a.burst, a.pattern, a.seed, a.rd_delay, not a.read_only, not a.write_only,
              timeout=max(10.0, a.len / b.clk_mhz / 1e5))
    show_run(d, b.clk_mhz)
    return 0 if d["ok"] else 1


def cmd_phase(b, a):
    if a.what:
        w = a.what[0]
        if w == "reset":
            b.pll_reset()
        elif w == "goto":
            b.goto(int(a.what[1], 0))
        else:
            b.step(int(w, 0))
    p = b.phase()
    print(f"DRAM_CLK at {p['pos']:+d} steps = {p['ps']:+d} ps from the compiled {b.phase_ps} ps"
          + (" (ERROR: the PLL did not answer)" if p["error"] else "")
          + (" (no phasedone low seen)" if p["no_ack"] else ""))


def windows(cells, positions):
    """cells: {pos: failing-pattern count}; the longest run of 0s -> (start, end) positions, or None."""
    best, start = None, None
    for i, pos in enumerate(positions + [None]):
        ok = pos is not None and cells.get(pos, 1) == 0
        if ok and start is None:
            start = pos
        if not ok and start is not None:
            end = positions[i - 1]
            if best is None or end - start > best[1] - best[0]:
                best = (start, end)
            start = None
    return best


def cmd_sweep(b, a):
    if not b.status()["init_done"]:
        raise SystemExit("FAIL: the SDRAM is not initialised (STATUS.init_done = 0)")
    steps = b.period_ps // b.step_ps
    if a.range:
        lo, hi = (int(x, 0) for x in a.range.split(":"))
    else:
        lo, hi = -(steps // 2), steps - steps // 2
    rds = [int(x) for x in a.rd_delays.split(",")]
    pats = [int(x) for x in a.patterns.split(",")]
    positions = list(range(lo, hi + 1))
    print(f"sweep: DRAM_CLK {lo:+d}..{hi:+d} steps of {b.step_ps} ps (period {b.period_ps} ps = {steps} steps), "
          f"rd_delay {rds}, patterns {pats}, {a.len:,} words per pass at {b.clk_mhz} MHz")
    print(f"{'pos':>4} {'ps':>6}  " + " ".join(f"rd{d}" for d in rds) + "   (. all patterns pass, "
          "digit = failing patterns, X = all fail)")
    result = {d: {} for d in rds}          # rd_delay -> pos -> failing pattern count
    detail = []
    b.goto(lo)
    t0 = time.perf_counter()
    for pos in positions:
        b.goto(pos)
        fails = {d: 0 for d in rds}
        for p in pats:
            w = b.run(0, a.len, 1024, p, 0x1234 + pos, rds[0], write=True, read=False)
            for d in rds:
                r = b.run(0, a.len, 1024, p, 0x1234 + pos, d, write=False, read=True)
                if not r["ok"]:
                    fails[d] += 1
                detail.append(dict(pos=pos, ps=pos * b.step_ps, pattern=p, rd_delay=d, errors=r["errors"],
                                   err_bits=r["err_bits"], wr_words=w["wr_words"]))
        for d in rds:
            result[d][pos] = fails[d]
        cells = " ".join(("  ." if fails[d] == 0 else "  X" if fails[d] == len(pats) else f"  {fails[d]}")
                         for d in rds)
        print(f"{pos:>+4d} {pos * b.step_ps:>+6d}  {cells}", flush=True)
    seconds = time.perf_counter() - t0
    ph = b.phase()
    print(f"{len(positions)} phases in {seconds:.0f} s" + (" (the PLL never showed phasedone low: the step is "
          "taken, the handshake is only invisible)" if ph["no_ack"] else ""))

    # ---- the windows ----
    print("\nwindows (the longest run of passing phases, all patterns):")
    best = None
    for d in rds:
        w = windows(result[d], positions)
        if w is None:
            print(f"  rd_delay {d}: none")
            continue
        width = (w[1] - w[0] + 1) * b.step_ps
        centre = (w[0] + w[1]) / 2
        print(f"  rd_delay {d}: {w[0]:+d}..{w[1]:+d} steps = {w[0] * b.step_ps:+d}..{w[1] * b.step_ps:+d} ps, "
              f"width {width} ps, centre {centre:+.1f} steps = {centre * b.step_ps:+.0f} ps")
        if best is None or width > best[2]:
            best = (d, centre, width)
    if best:
        d, centre, width = best
        pos = int(round(centre))
        abs_ps = (b.phase_ps + pos * b.step_ps) % b.period_ps
        print(f"\nbest: rd_delay {d} at {pos:+d} steps ({pos * b.step_ps:+d} ps): margin +-{width / 2:.0f} ps "
              f"-> compile with C1_PHASE \"{abs_ps}\" (ps) and rd_delay {d}")
    else:
        print("\nno phase passed every pattern for any rd_delay: lower the clock (CLK_MHZ 83 or 66) and sweep again")
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(dict(clk_mhz=b.clk_mhz, step_ps=b.step_ps, phase_ps=b.phase_ps, period_ps=b.period_ps,
                           words=a.len, patterns=pats, rd_delays=rds, positions=positions,
                           map={d: [result[d][p] for p in positions] for d in rds}, detail=detail,
                           best=best and dict(rd_delay=best[0], centre=best[1], width_ps=best[2]),
                           seconds=seconds), f, indent=1)
        print(f"written {a.out}")
    if best and a.stay:
        b.goto(int(round(best[1])))
        print(f"DRAM_CLK left at {b.phase()['pos']:+d} steps")
    else:
        b.pll_reset()
        print("PLL reset: DRAM_CLK back at the compiled phase, SDRAM re-initialised")


def num(s):
    return int(s, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--instance", type=int, default=1)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    sub.add_parser("clock")
    p = sub.add_parser("run")
    p.add_argument("--base", type=num, default=0)
    p.add_argument("--len", type=num, default=WORDS)
    p.add_argument("--burst", type=num, default=1024)
    p.add_argument("--pattern", type=int, default=3, choices=range(4))
    p.add_argument("--seed", type=num, default=0x1234)
    p.add_argument("--rd-delay", type=int, default=None, choices=range(8))
    p.add_argument("--write-only", action="store_true")
    p.add_argument("--read-only", action="store_true")
    p = sub.add_parser("phase")
    p.add_argument("what", nargs="*")
    p = sub.add_parser("sweep")
    p.add_argument("--range", default=None)
    p.add_argument("--rd-delays", default="2,3,4,5,6")
    p.add_argument("--patterns", default="0,2,3")
    p.add_argument("--len", type=num, default=1 << 18)
    p.add_argument("--stay", action="store_true")
    p.add_argument("--out", default=None)
    a = ap.parse_args()
    b = Board(a.instance)
    try:
        rc = dict(info=cmd_info, clock=cmd_clock, run=cmd_run, phase=cmd_phase, sweep=cmd_sweep)[a.cmd](b, a)
    finally:
        b.close()
    sys.exit(rc or 0)


if __name__ == "__main__":
    main()
