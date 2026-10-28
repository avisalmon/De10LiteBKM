"""Drive the SDRAM stream fabric of examples/15_sdram_stream_fabric (fabric_top on the board).

  python scripts/fabric_ctl.py info                         what is on the board: units, clock, phase, every block
  python scripts/fabric_ctl.py clock                        measure the design's clock from its cycle counter
  python scripts/fabric_ctl.py phase [+N | -N | goto P | reset]   move DRAM_CLK by N steps, or show it
  python scripts/fabric_ctl.py delay [D]                    show or set the controller's read delay (RD_DELAY)
  python scripts/fabric_ctl.py reset                        abort everything and soft-reset the fabric
  python scripts/fabric_ctl.py stats [--clear]              the counters (bus use, refreshes, bursts, per block)
  python scripts/fabric_ctl.py load FILE [--addr WORD] [--no-check]      a file into the SDRAM (the loader)
  python scripts/fabric_ctl.py bench [--units 1,2,3,6] [--bursts 64,256,1024] [--rows 1024] [--k 1024]
                                                            units streaming at once: the memory's throughput
  python scripts/fabric_ctl.py job --random ROWSxK [--t T] [--shift S] [--units U] [--burst B] [--wburst W]
                                   [--seed S] [--extreme] [--repeat N] [--no-check] [--out FILE.json]
                                                            a random matrix: load it, run y = W.x, compare bit for bit
  python scripts/fabric_ctl.py job --model NAME|model.q8.bin [--matrix NAME] [--load] [--t T] [--units U] ...
                                                            a model's matrices (tools/export_q8.py), one or all

A job: the matrix (int8 groups of 32 with an int16 scale, spec section 6) sits in the SDRAM; the host splits its rows
over the units, points channel u at unit u's slice and lane u at a result area, writes the T activation vectors into
every unit (XADDR / XDATA, broadcast), clears the counters and starts; the units stream their slices at up to one
word per clock each, the results (int32, two words each) go back to the SDRAM through the lanes, the host reads
them with the loader and compares them with tools/ref_matvec.py: the same bits, or a list of the differences.
Registers: lib/rtl/jtag_regs.sv instance 1 (the loader of example 14 is instance 0, on the same cable); the map is
in src/fabric_top.sv and spec.html section 5. One cable user at a time: close nios2-terminal / de10.py log first.
Library use: with Board() as b: r = b.job(JobSpec(...)); see run_job().
"""
import argparse
import json
import os
import sys
import time
import zlib

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOLS = os.path.join(ROOT, "examples", "15_sdram_stream_fabric", "tools")
MODELS = os.path.join(ROOT, "examples", "15_sdram_stream_fabric", "logs", "models")
sys.path.insert(0, HERE)
sys.path.insert(0, TOOLS)
from jtag_regs import JtagRegs  # noqa: E402
import ref_matvec as rm  # noqa: E402

ID = 0x5F150001
# the top and the fabric
R_ID, R_CTRL, R_STATUS, R_RD_DELAY, R_BUSY, R_TOTAL, R_REFRESHES, R_BURSTS = range(8)
R_PHASE, R_INFO, R_CYCLES, R_CLK_MHZ, R_LOADED = 8, 9, 10, 11, 12
CTRL_SOFT, CTRL_START, CTRL_ABORT, CTRL_CLEAR = 1, 2, 4, 8
ST_INIT, ST_LOCKED, ST_CH_RUN, ST_UNIT_BUSY, ST_LOADER, ST_FAULT, ST_IDLE = 1, 2, 4, 8, 16, 32, 64
# channel c: +0 BASE +1 LEN +2 BURST +3 CTRL (w: en, loop, start, abort, clear; r: loop, en) +4 STAT +5 FETCHED
# +6 WAITED; lane u: +0 WB_BASE (the pointer) +1 WB_CTRL (WBURST, bit 16 flush, 17 clear) +2 WB_STAT;
# unit u: +0 ROWS +1 K +2 T +3 SHIFT +4 CTRL +5 STAT +6 CYCLES_BUSY +7 CYCLES_STARVED +8 XADDR +9 XDATA
# +10 ROWS_DONE +11 CYCLES_STALLED +12 WORDS; a write at UN_BCAST + i lands in every unit's register i
CH_BASE, CH_STRIDE = 0x010, 8
LN_BASE, LN_STRIDE = 0x080, 4
UN_BASE, UN_STRIDE, UN_BCAST = 0x100, 16, 0x1F0
# where things live in the SDRAM (16-bit words): a model at 0, synthetic matrices in the scratch area, the lanes'
# result areas at the top, 512 K words (1 MB) each
MODEL_WORD = 0
SCRATCH_WORD = 0x1800000
WB_WORD, WB_STRIDE = 0x1C00000, 0x80000
WORDS = 1 << 25


def CH(c):
    return CH_BASE + CH_STRIDE * c


def LN(u):
    return LN_BASE + LN_STRIDE * u


def UN(u):
    return UN_BASE + UN_STRIDE * u


class FabricError(RuntimeError):
    pass


# ---------------------------------------------------------------------------------------------------------------
# a job, planned on the PC
# ---------------------------------------------------------------------------------------------------------------
class JobSpec:
    """One y = W . x job: the matrix's place and shape, the vectors, and how the units share it."""

    def __init__(self, matrix_word, rows, k, t=1, shift=None, units=None, burst=1024, wburst=64, x=None,
                 wb_word=WB_WORD, wb_stride=WB_STRIDE, name=""):
        if rows < 1 or rows >= 1 << 20:
            raise ValueError(f"ROWS {rows}: 1..1,048,575")
        if k < 1 or rm.pad_k(k) > 1024:
            raise ValueError(f"K {k}: 1..1024 (a unit holds 1024 int8 of x per vector)")
        if t < 1 or t > 15:
            raise ValueError(f"T {t}: 1..T_MAX")
        self.matrix_word, self.rows, self.k, self.t = matrix_word, rows, k, t
        self.k_pad, self.row_words = rm.pad_k(k), rm.row_words(k)
        self.words = self.rows * self.row_words
        self.shift = rm.default_shift(k) if shift is None else shift
        if not 0 <= self.shift <= 47:
            raise ValueError(f"SHIFT {self.shift}: 0..47")
        self.units, self.burst, self.wburst = units, burst, wburst
        self.x = None if x is None else np.asarray(x, dtype=np.int8).reshape(t, self.k_pad)
        self.wb_word, self.wb_stride, self.name = wb_word, wb_stride, name
        if matrix_word + self.words > WORDS:
            raise ValueError(f"the matrix ({self.words:,} words at {matrix_word:#x}) does not fit in the SDRAM")

    def slices(self, n_units):
        """(first_row, rows) per unit, the big slices first; at most n_units, never an empty slice."""
        n = min(n_units, self.units or n_units, self.rows)
        return rm.split_rows(self.rows, n)

    def wb_words(self, u):
        return self.wb_word + u * self.wb_stride

    def plan(self, n_units, with_x=True):
        """The register writes (addr, value) that set this job up on a design with n_units; no start."""
        slices = self.slices(n_units)
        ops = []
        for u in range(n_units):
            if u < len(slices):
                first, cnt = slices[u]
                if cnt * self.t * 2 > self.wb_stride:
                    raise ValueError(f"unit {u}: {cnt} rows x {self.t} results do not fit a lane area of "
                                     f"{self.wb_stride:#x} words")
                ops += [(CH(u), self.matrix_word + first * self.row_words), (CH(u) + 1, cnt * self.row_words),
                        (CH(u) + 2, self.burst), (CH(u) + 3, 1)]
                ops += [(LN(u), self.wb_words(u)), (LN(u) + 1, self.wburst | 1 << 17)]
                ops += [(UN(u), cnt), (UN(u) + 1, self.k_pad), (UN(u) + 2, self.t), (UN(u) + 3, self.shift)]
            else:
                ops += [(CH(u) + 3, 0), (UN(u), 0)]
        if with_x and self.x is not None:
            xw = rm.x_words(self.x)
            for tt in range(self.t):
                ops.append((UN_BCAST + 8, tt << 12))
                ops += [(UN_BCAST + 9, int(w)) for w in xw[tt]]
        ops.append((R_CTRL, CTRL_CLEAR))
        return ops

    def describe(self, n_units):
        sl = self.slices(n_units)
        return (f"{self.name + ': ' if self.name else ''}{self.rows:,} x {self.k} int8 ({self.words:,} words = "
                f"{self.words * 2 / 2**20:.2f} MB) at word {self.matrix_word:#x}; T {self.t}, SHIFT {self.shift}; "
                f"{len(sl)} unit{'s' if len(sl) != 1 else ''} ({', '.join(str(c) for _, c in sl)} rows), "
                f"BURST {self.burst}, WBURST {self.wburst}")


# ---------------------------------------------------------------------------------------------------------------
# the board
# ---------------------------------------------------------------------------------------------------------------
class Board:
    def __init__(self, instance=1):
        self.r = JtagRegs(instance)
        got = self.r.id()
        if got != ID:
            self.r.close()
            raise SystemExit(f"FAIL: the design on the board answers ID {got:08X}, fabric_top is {ID:08X}: "
                             "program examples/15_sdram_stream_fabric first")
        s = self.r.peek(R_STATUS)
        self.n, self.t_max, self.max_burst = s >> 8 & 0xFF, s >> 16 & 0xFF, 1 << (s >> 24 & 0xFF)
        info = self.r.peek(R_INFO)
        self.step_ps, self.phase_ps = info >> 16, info & 0xFFFF
        self.clk_mhz = self.r.peek(R_CLK_MHZ)
        self._ld = None

    def close(self):
        self.r.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ---- status ----
    def status(self):
        s = self.r.peek(R_STATUS)
        return dict(init_done=s & 1, pll_locked=s >> 1 & 1, ch_running=s >> 2 & 1, unit_busy=s >> 3 & 1,
                    loader=s >> 4 & 1, fault=s >> 5 & 1, idle=s >> 6 & 1, raw=s)

    def counters(self):
        v = self.r.peek(R_RD_DELAY, 5)
        return dict(rd_delay=v[0] & 7, busy=v[1], total=v[2], refreshes=v[3], bursts=v[4])

    def channel(self, c):
        v = self.r.peek(CH(c), 7)
        return dict(base=v[0], len=v[1], burst=v[2], en=v[3] & 1, loop=v[3] >> 1 & 1, wlevel=v[4] & 0x7FF,
                    running=v[4] >> 16 & 1, done=v[4] >> 17 & 1, ovf=v[4] >> 18 & 1, fetched=v[5], waited=v[6])

    def lane(self, u):
        v = self.r.peek(LN(u), 3)
        return dict(ptr=v[0], wburst=v[1] & 0x7FF, words=v[2] >> 8, underrun=v[2] >> 7 & 1, lvl=v[2] & 0x7F)

    def unit(self, u):
        v = self.r.peek(UN(u), 13)
        return dict(rows=v[0], k=v[1], t=v[2], shift=v[3], busy=v[5] & 1, done=v[5] >> 1 & 1,
                    lane_stalled=v[5] >> 2 & 1, aborted=v[5] >> 3 & 1, cyc_busy=v[6], cyc_starved=v[7],
                    xaddr=v[8], rows_done=v[10], cyc_stalled=v[11], words=v[12])

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

    # ---- the DRAM_CLK phase ----
    def step(self, n):
        """Move DRAM_CLK by n steps (negative = earlier); returns the new position."""
        while n:
            k = min(abs(n), 255)
            self.r.poke(R_PHASE, k | (0x100 if n > 0 else 0))
            p = self.r.wait(R_PHASE, 1 << 30, 0, timeout=2.0)
            if p >> 31 & 1:
                raise FabricError("the PLL did not answer the phase step (PHASE.error); reset it: phase reset")
            n -= k if n > 0 else -k
        return self.phase()["pos"]

    def goto(self, pos):
        return self.step(pos - self.phase()["pos"])

    def pll_reset(self):
        """Back to the compiled phase; the whole design restarts and the SDRAM re-initialises (its content stays)."""
        self.r.poke(R_PHASE, 1 << 16)
        time.sleep(0.05)
        self.r.wait(R_STATUS, ST_INIT, timeout=2.0)
        if self.phase()["pos"] != 0:
            raise FabricError("the phase position did not return to 0 after the PLL reset")

    # ---- the fabric ----
    def quiesce(self, timeout=2.0):
        """Abort every channel and unit, wait for idle, soft-reset (FIFOs and lanes emptied; settings and x stay)."""
        self.r.poke(R_CTRL, CTRL_ABORT)
        self.r.wait(R_STATUS, ST_IDLE, timeout=timeout)
        self.r.poke(R_CTRL, CTRL_SOFT)
        time.sleep(0.002)
        self.r.wait(R_STATUS, ST_IDLE, timeout=timeout)

    def wait_idle(self, timeout):
        """Until STATUS says idle; a fabric fault is an error. Returns the seconds it took."""
        t0 = time.perf_counter()
        while True:
            s = self.r.peek(R_STATUS)
            if s & ST_FAULT:
                raise FabricError("the fabric reports a fault (its grant queue broke): reset the PLL and tell "
                                  "the maintainer what ran")
            if s & ST_IDLE:
                return time.perf_counter() - t0
            if time.perf_counter() - t0 > timeout:
                raise FabricError(f"the job did not finish within {timeout:.1f} s (STATUS {s:08X}); "
                                  "fabric_ctl.py info shows what is stuck, reset puts it back")
            time.sleep(0.001)

    # ---- the SDRAM through the loader (virtual JTAG instance 0, the same cable) ----
    def loader(self):
        if self._ld is None:
            from sdram_load import Direct, loader_ok
            self._ld = Direct(0, quiet=True, jtag=self.r.jtag)
            loader_ok(self._ld.status())
            self.r.forget()
        return self._ld

    def sdram_write(self, word, data, check=True):
        """bytes -> SDRAM at word, CRC-checked (prints a line or two); True when every check passed."""
        from sdram_load import load
        ok = load(self.loader(), data, word, check)
        self.r.forget()
        return ok

    def sdram_read(self, word, nwords):
        """SDRAM from word -> (uint16 array, seconds)."""
        ld = self.loader()
        ld.raddr(word)
        data, t = ld.read(2 * nwords)
        st = ld.status()
        self.r.forget()
        if st["underrun"] or st["sent"] != nwords:
            raise FabricError(f"the loader sent {st['sent']:,} of {nwords:,} words"
                              f"{' (read underrun)' if st['underrun'] else ''}")
        return np.frombuffer(data, dtype="<u2").astype(np.uint16), t

    def sdram_crc(self, word, nwords):
        """The board's CRC32 over nwords from word -> (crc, seconds)."""
        st, t = self.loader().check(word, nwords)
        self.r.forget()
        if st["checked"] != nwords:
            raise FabricError(f"the board checked {st['checked']:,} of {nwords:,} words")
        return st["ccrc"], t

    # ---- a job ----
    def run_job(self, spec, with_x=True, timeout=None):
        """Set the job up, start it, wait, gather the counters. Returns a dict; r['problems'] lists what was wrong."""
        slices = spec.slices(self.n)
        ops = spec.plan(self.n, with_x)
        self.quiesce()
        t0 = time.perf_counter()
        self.r.batch(ops)
        t_setup = time.perf_counter() - t0
        expected_s = spec.words / (self.clk_mhz * 1e6) * 2 + 0.05
        t0 = time.perf_counter()
        self.r.poke(R_CTRL, CTRL_START)
        wall = self.wait_idle(timeout or max(5.0, 20 * expected_s))
        # The global counters run from the CLEAR at the end of the batch until this read (every JTAG round trip
        # is ~2 ms): read them first so TOTAL_CLOCKS and REFRESHES cover the job and one poll, not the read-back.
        ctr = self.counters()
        units = [self.unit(u) for u in range(len(slices))]
        lanes = [self.lane(u) for u in range(len(slices))]
        chans = [self.channel(u) for u in range(len(slices))]
        problems = []
        for u, (first, cnt) in enumerate(slices):
            un, ln, ch = units[u], lanes[u], chans[u]
            if not un["done"] or un["busy"]:
                problems.append(f"unit {u}: not done (busy {un['busy']}, done {un['done']})")
            if un["aborted"]:
                problems.append(f"unit {u}: aborted")
            if un["rows_done"] != cnt:
                problems.append(f"unit {u}: {un['rows_done']} rows done of {cnt}")
            if un["words"] != cnt * spec.row_words:
                problems.append(f"unit {u}: popped {un['words']:,} words, the slice has {cnt * spec.row_words:,}")
            if ch["fetched"] != cnt * spec.row_words or not ch["done"] or ch["running"]:
                problems.append(f"channel {u}: fetched {ch['fetched']:,} of {cnt * spec.row_words:,}, "
                                f"running {ch['running']}, done {ch['done']}")
            if ch["ovf"]:
                problems.append(f"channel {u}: FIFO overflow")
            if ln["words"] != cnt * spec.t * 2:
                problems.append(f"lane {u}: wrote {ln['words']:,} words, expected {cnt * spec.t * 2:,}")
            if ln["underrun"]:
                problems.append(f"lane {u}: underrun (the controller took a word the lane did not have)")
            if ln["ptr"] != spec.wb_words(u) + cnt * spec.t * 2:
                problems.append(f"lane {u}: pointer {ln['ptr']:#x}, expected "
                                f"{spec.wb_words(u) + cnt * spec.t * 2:#x}")
        clocks = max(un["cyc_busy"] for un in units)
        busy_sum = sum(un["cyc_busy"] for un in units) or 1
        words = sum(un["words"] for un in units)
        mhz = self.clk_mhz
        return dict(spec=spec, slices=slices, units=units, lanes=lanes, channels=chans, counters=ctr,
                    problems=problems, wall=wall, setup=t_setup, clocks=clocks, words=words,
                    seconds=clocks / (mhz * 1e6) if clocks else 0.0,
                    mbs=words * 2 * mhz / clocks if clocks else 0.0,
                    bus=ctr["busy"] / clocks if clocks else 0.0,
                    starved=sum(un["cyc_starved"] for un in units) / busy_sum,
                    stalled=sum(un["cyc_stalled"] for un in units) / busy_sum,
                    waited=sum(ch["waited"] for ch in chans))

    def read_results(self, spec, slices):
        """The lanes' int32 results back from the SDRAM, in the matrix's row order: int32 [rows, T]."""
        parts, t_sum = [], 0.0
        for u, (first, cnt) in enumerate(slices):
            words, t = self.sdram_read(spec.wb_words(u), cnt * spec.t * 2)
            t_sum += t
            parts.append(rm.parse_results(words, cnt, spec.t))
        return np.concatenate(parts, axis=0), t_sum


# ---------------------------------------------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------------------------------------------
def pct(x):
    return f"{100 * x:.1f} %"


def show_run(r, clk_mhz):
    busy = r["counters"]["busy"]
    # the bus works a little before the first unit starts (filling the FIFOs) and after the last one is done (the
    # lanes' write-back tail), so on a job of a few thousand clocks it is "busy" for more clocks than the units
    bus = (f"bus busy {busy:,} clocks, more than the units' span (the FIFO fill and write-back tail: a short job)"
           if r["bus"] > 1 else f"bus busy {pct(r['bus'])}")
    print(f"  run: {r['seconds'] * 1e3:.3f} ms on the board ({r['clocks']:,} clocks at {clk_mhz} MHz) = "
          f"{r['mbs']:.1f} MB/s over {r['words']:,} words; {bus}, units starved "
          f"{pct(r['starved'])}, stalled {pct(r['stalled'])}; {r['counters']['bursts']:,} bursts; "
          f"{r['counters']['refreshes']:,} refreshes in the counters' {r['counters']['total'] / (clk_mhz * 1e3):.1f} ms "
          f"(one per 7.5 us); setup {r['setup'] * 1e3:.0f} ms, wall {r['wall'] * 1e3:.1f} ms")
    for p in r["problems"]:
        print(f"  PROBLEM: {p}")


def compare(y_hw, y_ref, limit=8):
    """Print the verdict; True when every value matches."""
    bad = np.argwhere(y_hw != y_ref)
    if bad.size == 0:
        print(f"  results: {y_hw.size:,} int32 bit-exact with the reference (tools/ref_matvec.py)")
        return True
    print(f"  FAIL: {len(bad):,} of {y_hw.size:,} results differ from the reference; the first:")
    for row, t in bad[:limit]:
        print(f"    row {row} t {t}: board {int(y_hw[row, t]):>12,} ({int(y_hw[row, t]) & 0xFFFFFFFF:08X})  "
              f"reference {int(y_ref[row, t]):>12,} ({int(y_ref[row, t]) & 0xFFFFFFFF:08X})")
    rows_bad = np.unique(bad[:, 0])
    print(f"    rows with differences: {len(rows_bad):,} (first {rows_bad[:10].tolist()})")
    return False


def record(out, entry):
    if not out:
        return
    data = []
    if os.path.exists(out):
        with open(out, encoding="utf-8") as f:
            data = json.load(f)
    data.append(entry)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)


def summary(r, spec, exact):
    return dict(name=spec.name, rows=spec.rows, k=spec.k, t=spec.t, shift=spec.shift, units=len(r["slices"]),
                burst=spec.burst, wburst=spec.wburst, words=r["words"], clocks=r["clocks"], ms=r["seconds"] * 1e3,
                mbs=r["mbs"], bus=r["bus"], starved=r["starved"], stalled=r["stalled"], waited=r["waited"],
                bursts=r["counters"]["bursts"], refreshes=r["counters"]["refreshes"],
                counter_clocks=r["counters"]["total"], wall_ms=r["wall"] * 1e3,
                setup_ms=r["setup"] * 1e3, exact=exact, problems=r["problems"], time=time.strftime("%Y-%m-%d %H:%M"))


# ---------------------------------------------------------------------------------------------------------------
# the commands
# ---------------------------------------------------------------------------------------------------------------
def cmd_info(b, a):
    st = b.status()
    mhz = b.measure_clock(0.3)
    ph = b.phase()
    c = b.counters()
    print(f"fabric_top {ID:08X}: {b.n} units (T_MAX {b.t_max}), MAX_BURST {b.max_burst}, built for {b.clk_mhz} MHz, "
          f"measured {mhz:.3f} MHz")
    flags = [name for bit, name in ((ST_INIT, "SDRAM ready"), (ST_LOCKED, "PLL locked"), (ST_IDLE, "idle"),
                                    (ST_CH_RUN, "a channel running"), (ST_UNIT_BUSY, "a unit busy"),
                                    (ST_LOADER, "the loader on the bus"), (ST_FAULT, "FAULT"))
             if st["raw"] & bit]
    print(f"status {st['raw']:08X}: {', '.join(flags)}; DRAM_CLK phase {ph['pos']:+d} steps = {ph['ps']:+d} ps from "
          f"the compiled {b.phase_ps} ps (step {b.step_ps} ps)"
          f"{'; stepper busy' if ph['busy'] else ''}{'; PHASE ERROR' if ph['error'] else ''}; rd_delay {c['rd_delay']}")
    print(f"counters since the last clear: busy {c['busy']:,} of {c['total']:,} clocks "
          f"({pct(c['busy'] / c['total']) if c['total'] else '-'}), {c['refreshes']:,} refreshes, "
          f"{c['bursts']:,} bursts; loader wrote {b.r.peek(R_LOADED):,} words since its last WADDR")
    print(f"{'ch':>3} {'base':>9} {'len':>9} {'burst':>5} en lp run dn ovf {'level':>5} {'fetched':>10} {'waited':>10}")
    for u in range(b.n):
        ch = b.channel(u)
        print(f"{u:>3} {ch['base']:#9x} {ch['len']:>9,} {ch['burst']:>5} {ch['en']:>2} {ch['loop']:>2} "
              f"{ch['running']:>3} {ch['done']:>2} {ch['ovf']:>3} {ch['wlevel']:>5} {ch['fetched']:>10,} "
              f"{ch['waited']:>10,}")
    print(f"{'ln':>3} {'pointer':>9} {'wburst':>6} {'words':>10} ur {'lvl':>3}")
    for u in range(b.n):
        ln = b.lane(u)
        print(f"{u:>3} {ln['ptr']:#9x} {ln['wburst']:>6} {ln['words']:>10,} {ln['underrun']:>2} {ln['lvl']:>3}")
    print(f"{'un':>3} {'rows':>7} {'k':>5} {'t':>2} {'sh':>2} bz dn st ab {'rows_done':>9} {'words':>10} "
          f"{'busy':>10} {'starved':>10} {'stalled':>10}")
    for u in range(b.n):
        un = b.unit(u)
        print(f"{u:>3} {un['rows']:>7,} {un['k']:>5} {un['t']:>2} {un['shift']:>2} {un['busy']:>2} {un['done']:>2} "
              f"{un['lane_stalled']:>2} {un['aborted']:>2} {un['rows_done']:>9,} {un['words']:>10,} "
              f"{un['cyc_busy']:>10,} {un['cyc_starved']:>10,} {un['cyc_stalled']:>10,}")


def cmd_clock(b, a):
    print(f"built for {b.clk_mhz} MHz; measured {b.measure_clock(1.0):.4f} MHz")


def cmd_phase(b, a):
    if a.what:
        w = a.what[0]
        if w == "reset":
            b.pll_reset()
        elif w == "goto":
            b.goto(int(a.what[1]))
        else:
            b.step(int(w))
    ph = b.phase()
    print(f"DRAM_CLK phase: {ph['pos']:+d} steps = {ph['ps']:+d} ps from the compiled {b.phase_ps} ps "
          f"(a step is {b.step_ps} ps, the period {round(1e6 / b.clk_mhz)} ps)"
          f"{'; ERROR: the PLL did not answer' if ph['error'] else ''}")


def cmd_delay(b, a):
    if a.value is not None:
        b.r.poke(R_RD_DELAY, a.value)
    print(f"rd_delay {b.counters()['rd_delay']}")


def cmd_reset(b, a):
    b.quiesce()
    print(f"aborted and soft-reset; status {b.status()['raw']:08X}")


def cmd_stats(b, a):
    if a.clear:
        b.r.poke(R_CTRL, CTRL_CLEAR)
    c = b.counters()
    print(f"bus busy {c['busy']:,} of {c['total']:,} clocks ({pct(c['busy'] / c['total']) if c['total'] else '-'}), "
          f"{c['refreshes']:,} refreshes, {c['bursts']:,} bursts")
    for u in range(b.n):
        ch, ln, un = b.channel(u), b.lane(u), b.unit(u)
        print(f"  {u}: channel fetched {ch['fetched']:,} waited {ch['waited']:,} | lane wrote {ln['words']:,} | "
              f"unit busy {un['cyc_busy']:,} starved {un['cyc_starved']:,} stalled {un['cyc_stalled']:,} "
              f"words {un['words']:,} rows {un['rows_done']:,}")


def cmd_load(b, a):
    from sdram_load import read_file
    data = read_file(a.file)
    ok = b.sdram_write(a.addr, data, not a.no_check)
    print("OK" if ok else "FAIL")
    return 0 if ok else 1


def cmd_bench(b, a):
    units = [int(x) for x in a.units.split(",")] if a.units else sorted({1, 2, 3, b.n})
    bursts = [int(x) for x in a.bursts.split(",")]
    print(f"bench: every unit streams {a.rows:,} rows x {a.k} ({a.rows * rm.row_words(a.k):,} words) of whatever "
          f"is at word {a.base:#x}, T {a.t}; the memory is the limit")
    print(f"{'units':>5} {'burst':>5} {'words':>11} {'clocks':>11} {'ms':>8} {'MB/s':>7} {'bus':>7} {'starved':>8} "
          f"{'stalled':>8} {'waited':>10} {'bursts':>8}")
    fails = 0
    for nu in units:
        if nu < 1 or nu > b.n:
            print(f"  {nu} units: the design has {b.n}")
            continue
        for burst in bursts:
            spec = JobSpec(a.base, a.rows * nu, a.k, a.t, 0, nu, burst, a.wburst, name="bench")
            r = b.run_job(spec, with_x=False)
            print(f"{nu:>5} {burst:>5} {r['words']:>11,} {r['clocks']:>11,} {r['seconds'] * 1e3:>8.3f} "
                  f"{r['mbs']:>7.1f} {pct(r['bus']):>7} {pct(r['starved']):>8} {pct(r['stalled']):>8} "
                  f"{r['waited']:>10,} {r['counters']['bursts']:>8,}")
            for p in r["problems"]:
                print(f"  PROBLEM: {p}")
            fails += bool(r["problems"])
            record(a.out, dict(bench=True, **summary(r, spec, None)))
    return 1 if fails else 0


def parse_shape(s):
    try:
        rows, k = s.lower().split("x")
        return int(rows), int(k)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{s!r}: ROWSxK, e.g. 512x1024")


def resolve_model(name):
    """stories260K | path/to/model.q8.bin -> (bin path, map path)."""
    if os.path.exists(name):
        bin_path = name
    else:
        bin_path = os.path.join(MODELS, name + ".q8.bin")
        if not os.path.exists(bin_path):
            raise SystemExit(f"no model {name!r}: export it first, e.g. python examples/15_sdram_stream_fabric/tools/"
                             f"export_q8.py stories260K (looked for {bin_path})")
    stem = bin_path[:-len(".q8.bin")] if bin_path.endswith(".q8.bin") else os.path.splitext(bin_path)[0]
    map_path = stem + ".json"
    if not os.path.exists(map_path):
        raise SystemExit(f"the map {map_path} is missing next to {bin_path}")
    return bin_path, map_path


def job_once(b, spec, q, s, x, a, with_x=True, label=""):
    """Run one job and check it; returns (exact, result)."""
    r = b.run_job(spec, with_x)
    show_run(r, b.clk_mhz)
    exact = None
    if not a.no_check:
        y_hw, t_rd = b.read_results(spec, r["slices"])
        y_ref = rm.matvec(q, s, x, spec.shift)
        print(f"  read back {y_hw.size:,} results in {t_rd:.2f} s", end="")
        exact = compare(y_hw, y_ref)
    record(a.out, summary(r, spec, exact))
    return (exact is not False) and not r["problems"], r


def cmd_job(b, a):
    rng = np.random.default_rng(a.seed)
    units = a.units or b.n
    if a.t > b.t_max:
        raise SystemExit(f"--t {a.t}: this design holds T_MAX = {b.t_max} vectors")
    ok = True
    if a.random:
        rows, k = a.random
        q, s = rm.random_matrix(rows, k, rng, a.extreme)
        x = rm.random_x(k, a.t, rng, a.extreme)
        spec = JobSpec(a.scratch, rows, k, a.t, a.shift, units, a.burst, a.wburst, x, name="random")
        print("job: " + spec.describe(b.n))
        data = rm.stream_bytes(q, s)
        if not a.no_load:
            print(f"  loading the matrix: ", end="", flush=True)
            if not b.sdram_write(spec.matrix_word, data, check=True):
                raise SystemExit("FAIL: the matrix did not arrive intact; stopping")
        for i in range(a.repeat):
            if a.repeat > 1:
                print(f"  pass {i + 1} of {a.repeat}")
            good, r = job_once(b, spec, q, s, x, a, with_x=(i == 0))
            ok = ok and good
        return 0 if ok else 1

    bin_path, map_path = resolve_model(a.model)
    import export_q8 as ex
    m = ex.load_map(map_path)
    print(f"model {os.path.basename(bin_path)}: {m['source']}, dim {m['dim']}, hidden {m['hidden_dim']}, "
          f"{m['n_layers']} layers, vocab {m['vocab_size']}; {len(m['matrices'])} matrices, {m['total_words']:,} "
          f"words = {m['total_bytes'] / 2**20:.2f} MB")
    if a.list:
        for e in m["matrices"]:
            print(f"  {e['name']:10s} {e['rows']:6,} x {e['k']:<5} {e['words']:>10,} words at {e['offset_words']:#010x}"
                  f"  E {e['exponent']:4d}  SHIFT {e['default_shift']}")
        return 0
    with open(bin_path, "rb") as f:
        blob = f.read()
    want = zlib.crc32(blob)
    if a.load:
        print(f"  loading the model at word {MODEL_WORD:#x}: ", end="", flush=True)
        if not b.sdram_write(MODEL_WORD, blob, check=True):
            raise SystemExit("FAIL: the model did not arrive intact; stopping")
    else:
        crc, t = b.sdram_crc(MODEL_WORD, len(blob) // 2)
        if crc != want:
            raise SystemExit(f"the SDRAM does not hold this model (CRC {crc:08x}, file {want:08x}): add --load")
        print(f"  the model is in the SDRAM (board CRC {crc:08x} matches the file, {t:.2f} s)")
    entries = [ex.find_matrix(m, a.matrix)] if a.matrix else m["matrices"]
    total_clocks = total_words = 0
    t_all = time.perf_counter()
    for e in entries:
        q, s = rm.parse_stream(ex.read_matrix_words(bin_path, e), e["rows"], e["k"])
        x = rm.random_x(e["k"], a.t, rng)
        shift = e["default_shift"] if a.shift is None else a.shift
        spec = JobSpec(MODEL_WORD + e["offset_words"], e["rows"], e["k"], a.t, shift, units, a.burst, a.wburst, x,
                       name=e["name"])
        print("job: " + spec.describe(b.n))
        for i in range(a.repeat):
            good, r = job_once(b, spec, q, s, x, a, with_x=(i == 0))
            ok = ok and good
        total_clocks += r["clocks"]
        total_words += r["words"]
    if len(entries) > 1:
        secs = total_clocks / (b.clk_mhz * 1e6)
        print(f"all {len(entries)} matrices: {total_words:,} words ({total_words * 2 / 2**20:.2f} MB) in "
              f"{secs * 1e3:.2f} ms of board time = {total_words * 2 / secs / 1e6:.1f} MB/s; "
              f"{time.perf_counter() - t_all:.1f} s wall with the PC's checks; "
              f"{'all bit-exact' if ok else 'FAILURES above'}")
    return 0 if ok else 1


def num(s):
    return int(s, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--instance", type=int, default=1, help="the jtag_regs node (default 1)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    sub.add_parser("clock")
    p = sub.add_parser("phase")
    p.add_argument("what", nargs="*", help="+N | -N | goto P | reset")
    p = sub.add_parser("delay")
    p.add_argument("value", type=int, nargs="?")
    sub.add_parser("reset")
    p = sub.add_parser("stats")
    p.add_argument("--clear", action="store_true")
    p = sub.add_parser("load")
    p.add_argument("file")
    p.add_argument("--addr", type=num, default=0, help="first 16-bit word (default 0)")
    p.add_argument("--no-check", action="store_true", help="skip the board's CRC pass")
    p = sub.add_parser("bench")
    p.add_argument("--units", default=None, help="units streaming at once, e.g. 1,2,3,6 (default 1,2,3,N)")
    p.add_argument("--bursts", default="64,256,1024")
    p.add_argument("--rows", type=int, default=1024, help="rows per unit (default 1024)")
    p.add_argument("--k", type=int, default=1024)
    p.add_argument("--t", type=int, default=1)
    p.add_argument("--wburst", type=int, default=64)
    p.add_argument("--base", type=num, default=SCRATCH_WORD)
    p.add_argument("--out", default=None, help="append the rows to this JSON file")
    p = sub.add_parser("job")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--random", type=parse_shape, metavar="ROWSxK", help="a random matrix, e.g. 512x1024")
    g.add_argument("--model", metavar="NAME|model.q8.bin", help="stories260K, stories15M, or a path")
    p.add_argument("--matrix", default=None, help="one matrix of the model by name (default: all of them)")
    p.add_argument("--list", action="store_true", help="list the model's matrices and stop")
    p.add_argument("--load", action="store_true", help="load the model into the SDRAM first (word 0)")
    p.add_argument("--no-load", action="store_true", help="random: the matrix is already in the scratch area")
    p.add_argument("--t", type=int, default=1, help="activation vectors at once, 1..T_MAX (default 1)")
    p.add_argument("--shift", type=int, default=None, help="SHIFT 0..47 (default: the one that cannot saturate)")
    p.add_argument("--units", type=int, default=None, help="units to share the rows (default: all)")
    p.add_argument("--burst", type=int, default=1024, help="channel read burst, words (default 1024)")
    p.add_argument("--wburst", type=int, default=64, help="lane write burst, words (default 64)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--extreme", action="store_true", help="random: only -127/127 weights and extreme scales")
    p.add_argument("--repeat", type=int, default=1, help="run each job this many times")
    p.add_argument("--no-check", action="store_true", help="do not read the results back")
    p.add_argument("--scratch", type=num, default=SCRATCH_WORD, help=f"random: where the matrix goes "
                   f"(default {SCRATCH_WORD:#x})")
    p.add_argument("--out", default=None, help="append a summary of every job to this JSON file")
    a = ap.parse_args()
    try:
        board = Board(a.instance)
    except Exception as e:
        if type(e).__name__ in ("CableError", "CableBusy"):
            raise SystemExit(f"FAIL: {e}")
        raise
    with board as b:
        rc = globals()["cmd_" + a.cmd](b, a)
    sys.exit(rc or 0)


if __name__ == "__main__":
    main()
