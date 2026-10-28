"""The SDRAM stream fabric (example 15): the reference arithmetic and the weight-stream format, the model exporter
on a tiny synthetic llama2 checkpoint, the PC tool's job planner and its batched register writes (a fake cable
stands in for the board), the memtest sweep's window analysis, the three testbenches when Icarus Verilog is
installed, and the example's completeness."""

import json
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "examples" / "15_sdram_stream_fabric"
PY = sys.executable
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(EXAMPLE / "tools"))
import export_q8 as eq  # noqa: E402
import fabric_ctl as fc  # noqa: E402
import jtag_regs  # noqa: E402
import ref_matvec as rm  # noqa: E402
import sdram_memtest as mt  # noqa: E402
import usb_blaster as ub  # noqa: E402

ICARUS = shutil.which("iverilog") is not None or Path(r"C:\iverilog\bin\iverilog.exe").exists()


# --- the reference arithmetic and the stream format (tools/ref_matvec.py) ---

def test_the_reference_selftest_passes():
    rm._selftest()


def test_one_group_by_hand():
    q = np.ones((1, 32), np.int8)
    s = np.array([[3]], np.int16)
    x = np.full((1, 32), 2, np.int8)
    assert rm.matvec(q, s, x, 0)[0, 0] == 32 * 2 * 3
    assert rm.matvec(q, s, x, 1)[0, 0] == 96
    assert rm.matvec(q, -s, x, 1)[0, 0] == -96                    # arithmetic shift of a negative accumulator


def test_saturation_and_the_safe_shift():
    q = np.full((1, 1024), 127, np.int8)
    s = np.full((1, 32), 32767, np.int16)
    x = np.full((1, 1024), 127, np.int8)
    assert rm.matvec(q, s, x, 0)[0, 0] == rm.INT32_MAX
    assert rm.matvec(q, -s, x, 0)[0, 0] == rm.INT32_MIN
    exact = 1024 * 127 * 127 * 32767
    assert rm.matvec(q, s, x, rm.default_shift(1024))[0, 0] == exact >> rm.default_shift(1024)
    assert rm.default_shift(1024) == 9 and rm.default_shift(288) == 7 and rm.default_shift(32) == 4


def test_the_stream_is_17_words_per_group_and_rows_are_padded():
    assert rm.row_words(32) == 17 and rm.row_words(288) == 9 * 17 and rm.row_words(100) == 4 * 17
    q, s = rm.random_matrix(2, 40, np.random.default_rng(3))
    words = rm.stream_words(q, s)
    assert words.size == 2 * 2 * 17
    assert words[16] == np.uint16(s[0, 0]) and words[33] == np.uint16(s[0, 1])
    assert words[0] == (int(q[0, 1]) & 0xFF) << 8 | (int(q[0, 0]) & 0xFF)     # pairs little-endian
    qf, sf, _ = rm.quantize(np.random.default_rng(4).standard_normal((2, 40)))
    assert qf.shape == (2, 64) and not qf[:, 40:].any()                       # K padded with zero weights


def test_rows_split_big_slices_first_and_never_empty():
    assert rm.split_rows(512, 6) == [(0, 86), (86, 86), (172, 85), (257, 85), (342, 85), (427, 85)]
    assert rm.split_rows(3, 6) == [(0, 1), (1, 1), (2, 1)]
    assert rm.split_rows(7, 1) == [(0, 7)]


# --- the model exporter on a synthetic llama2.c checkpoint (tools/export_q8.py) ---

def write_tiny_llama(path, dim=32, hidden=64, n_layers=2, n_heads=2, vocab=16, seq_len=8, shared=True, seed=5):
    rng = np.random.default_rng(seed)
    head = dim // n_heads
    shapes = [("tok_emb", (vocab, dim)), ("rms_att", (n_layers, dim)), ("wq", (n_layers, dim, dim)),
              ("wk", (n_layers, dim, dim)), ("wv", (n_layers, dim, dim)), ("wo", (n_layers, dim, dim)),
              ("rms_ffn", (n_layers, dim)), ("w1", (n_layers, hidden, dim)), ("w2", (n_layers, dim, hidden)),
              ("w3", (n_layers, hidden, dim)), ("rms_final", (dim,)), ("freq_cis_real", (seq_len, head // 2)),
              ("freq_cis_imag", (seq_len, head // 2))]
    if not shared:
        shapes.append(("wcls", (vocab, dim)))
    tensors = {name: rng.standard_normal(shape).astype("<f4") for name, shape in shapes}
    with open(path, "wb") as f:
        f.write(struct.pack("<7i", dim, hidden, n_layers, n_heads, n_heads, vocab if shared else -vocab, seq_len))
        for name, _ in shapes:
            f.write(tensors[name].tobytes())
    return tensors


@pytest.mark.parametrize("shared", [True, False])
def test_export_writes_every_matrix_on_a_row_boundary_and_reads_back(tmp_path, shared):
    tensors = write_tiny_llama(tmp_path / "tiny.bin", shared=shared)
    model = eq.Llama2Bin(tmp_path / "tiny.bin")
    assert model.shared_classifier is shared and model.dims()["vocab_size"] == 16
    m = eq.export(model, tmp_path / "tiny.q8.bin", tmp_path / "tiny.json", tmp_path / "tiny.aux.npz", quiet=True)
    assert m == eq.load_map(tmp_path / "tiny.json")
    names = [e["name"] for e in m["matrices"]]
    assert names == [f"l{l}.{k}" for l in range(2) for k in eq.KINDS] + ["cls"]
    for e in m["matrices"]:
        assert e["offset_words"] % rm.MATRIX_ALIGN == 0
        assert e["words"] == rm.matrix_words(e["rows"], e["k"])
    w1 = eq.find_matrix(m, "l1.w1")
    assert (w1["rows"], w1["k"], w1["default_shift"]) == (64, 32, rm.default_shift(32))
    assert m["total_words"] == rm.aligned(m["matrices"][-1]["offset_words"] + m["matrices"][-1]["words"])
    assert (tmp_path / "tiny.q8.bin").stat().st_size == m["total_bytes"] == 2 * m["total_words"]
    # the classifier comes from the embedding when it is shared
    cls = tensors["tok_emb"] if shared else tensors["wcls"]
    q, s = rm.parse_stream(eq.read_matrix_words(tmp_path / "tiny.q8.bin", eq.find_matrix(m, "cls")), 16, 32)
    q2, s2, e2 = rm.quantize(cls)
    assert np.array_equal(q, q2) and np.array_equal(s, s2) and e2 == eq.find_matrix(m, "cls")["exponent"]
    aux = np.load(tmp_path / "tiny.aux.npz")
    assert set(aux.files) >= {"rms_att", "rms_ffn", "rms_final", "freq_cis_real", "freq_cis_imag"}
    assert ("tok_emb" in aux.files) is (not shared)
    with pytest.raises(KeyError):
        eq.find_matrix(m, "l7.wq")


def test_quantization_error_is_within_half_a_step():
    w = np.random.default_rng(2).standard_normal((5, 100))
    q, s, e = rm.quantize(w)
    back = rm.dequantize(q, s, e)[:, :100]
    # half the biggest group's step from rounding q, plus under 0.4 % of it from rounding the scales to int16
    step = np.abs(w).max() / 127
    assert np.all(np.abs(back - w) <= step * 0.51)
    assert q.dtype == np.int8 and s.dtype == np.int16 and 16384 <= s.max() <= 32767
    assert rm.quantize(np.zeros((2, 32)))[2] == 0 and not rm.quantize(np.zeros((2, 32)))[1].any()


# --- the PC tool's pure parts (scripts/fabric_ctl.py, scripts/jtag_regs.py) ---

def test_a_job_plans_channels_lanes_units_and_x_in_one_batch():
    x = rm.random_x(1024, 8, np.random.default_rng(1))
    spec = fc.JobSpec(fc.SCRATCH_WORD, 512, 1024, 8, None, None, 1024, 64, x, name="t")
    assert spec.slices(6) == rm.split_rows(512, 6)
    ops = spec.plan(6)
    xdata = [v for a, v in ops if a == fc.UN_BCAST + 9]
    assert len(xdata) == 8 * 256 and len(ops) == 6 * 10 + 8 * (1 + 256) + 1
    assert ops[0] == (fc.CH(0), fc.SCRATCH_WORD) and ops[1] == (fc.CH(0) + 1, 86 * rm.row_words(1024))
    assert ops[-1] == (fc.R_CTRL, fc.CTRL_CLEAR)
    assert [v for a, v in ops if a == fc.UN_BCAST + 8] == [t << 12 for t in range(8)]
    assert "512 x 1024" in spec.describe(6) and "SHIFT 9" in spec.describe(6)


def test_units_outside_a_job_are_switched_off_and_lanes_cannot_overflow():
    ops = fc.JobSpec(0, 3, 32, 1, 0, None, 64, 64).plan(6)
    assert (fc.CH(3) + 3, 0) in ops and (fc.UN(3), 0) in ops and (fc.UN(2), 1) in ops
    with pytest.raises(ValueError, match="do not fit a lane"):
        fc.JobSpec(0, 300000, 32, 8, 0, 1).plan(1)
    with pytest.raises(ValueError):
        fc.JobSpec(0, 1, 2048, 1, 0, None).plan(1)                  # K above the unit's 1024


def test_parse_shape_and_model_lookup():
    assert fc.parse_shape("512x1024") == (512, 1024) and fc.parse_shape("3X32") == (3, 32)
    with pytest.raises(Exception):
        fc.parse_shape("512")
    with pytest.raises(SystemExit, match="export it first"):
        fc.resolve_model("no_such_model_zz")


class FakeHub:
    m, addr_bits = 5, 3


class FakeNode:
    hub, addr = FakeHub(), 1

    def vir_value(self, v):
        return (self.addr << 5) | v, 8


class FakeJtag:
    def __init__(self):
        self.runs = []

    def run(self, seq, answer=0):
        self.runs.append(bytes(seq))
        return b""


def fake_regs():
    r = jtag_regs.JtagRegs.__new__(jtag_regs.JtagRegs)
    r.node, r.jtag, r._ir, r.owns = FakeNode(), FakeJtag(), None, False
    return r


def test_batch_rides_the_address_auto_increment_and_reselects_repeats():
    r = fake_regs()
    n = r.batch([(0x1F8, 0), (0x1F9, 1), (0x1F9, 2), (0x10, 7), (0x11, 8), (0x12, 9)], block=1 << 20)
    seq = b"".join(r.jtag.runs)
    select_addr = ub.ir_scan(ub.USER1) + ub.dr_scan((1 << 5) | jtag_regs.IR_ADDR, 8) + ub.ir_scan(ub.USER0)
    assert n == 6 and len(r.jtag.runs) == 1
    assert seq.count(select_addr) == 3                           # 0x1F8 (+1 rides), 0x1F9 again, 0x10 (+1, +2 ride)
    assert r._ir == jtag_regs.IR_WRITE                           # the cached instruction matches the hardware


def test_batch_splits_long_streams_into_blocks():
    r = fake_regs()
    r.batch([(0x1F9, i) for i in range(400)], block=4096)
    assert len(r.jtag.runs) > 1 and all(len(b) <= 4096 + 400 for b in r.jtag.runs)
    assert sum(len(b) for b in r.jtag.runs) < 400 * 400         # well under 400 bytes per word


# --- the memtest sweep's window analysis (scripts/sdram_memtest.py) ---

# The map measured on 2026-10-28 at the compiled phase 0: rd_delay 4 passed from -24..+1 and +17..+24 (one window
# across the wrap), rd_delay 3 from +4..+11, rd_delay 5 never.
POSITIONS = list(range(-24, 25))
RD4 = {p: (0 if p <= 1 or p >= 17 else 1) for p in POSITIONS}
RD3 = {p: (0 if 4 <= p <= 11 else 1) for p in POSITIONS}


def test_the_sweep_window_wraps_around_the_period():
    assert mt.windows(RD4, POSITIONS, 48) == (17, 49)            # +49 is +1: 33 steps wide, centre +33 = -15
    assert mt.windows(RD3, POSITIONS, 48) == (4, 11)
    assert mt.windows({p: 1 for p in POSITIONS}, POSITIONS, 48) is None
    assert mt.windows({p: 0 for p in POSITIONS}, POSITIONS, 48) == (-24, 23)   # one full circle, not two


def test_a_partial_sweep_is_analysed_as_a_line():
    assert mt.windows(RD4, POSITIONS, None) == (-24, 1)
    assert mt.windows(RD4, list(range(10, 25)), 48) == (17, 24)


# --- the RTL ---

@pytest.mark.skipif(not ICARUS, reason="Icarus Verilog is not installed")
@pytest.mark.parametrize("tb, defines, expect", [
    ("tb_sdram_burst_ctrl.sv", [], r"\nPASS"),
    ("tb_async_fifo.sv", [], r"PASS: async_fifo"),
    ("tb_matvec_unit.sv", [], r"PASS"),
    ("tb_stream_fabric.sv", [], r"PASS: stream_fabric N=\d+"),
    ("tb_sdram_memtest.sv", [], r"PASS: sdram_memtest"),
    ("tb_pll_phase_step.sv", [], r"PASS: pll_phase_step"),
    ("tb_jtag_regs.sv", ["-D", "JTAG_REGS_SIM"], r"PASS"),
])
def test_the_testbenches_pass(tb, defines, expect):
    p = subprocess.run([PY, "scripts/sim.py", f"lib/sim/{tb}", *defines], cwd=ROOT, capture_output=True, text=True,
                       timeout=1800)
    out = p.stdout + p.stderr
    assert p.returncode == 0 and re.search(expect, out) and "FAIL" not in out, out[-3000:]


def test_the_rtl_carries_the_board_measured_defaults():
    fabric = (ROOT / "lib" / "rtl" / "stream_fabric.sv").read_text(encoding="utf-8")
    assert "RD_DELAY_DEFAULT = 3'd4" in fabric
    top = (EXAMPLE / "src" / "fabric_top.sv").read_text(encoding="utf-8")
    assert 'C1_PHASE = "6875"' in top and "PHASE_PS = 6875" in top
    assert "32'h5F15_0001" in top
    memtest = (EXAMPLE / "memtest" / "src" / "memtest_top.sv").read_text(encoding="utf-8")
    assert 'C1_PHASE = "6875"' in memtest


# --- the example and its pages ---

def test_the_example_is_complete():
    for name in ("index.html", "spec.html", "sdram_stream_fabric.qar", "sdram_stream_fabric.qsf",
                 "sdram_stream_fabric.qpf", "sdram_stream_fabric.sdc", "src/fabric_top.sv", "src/extra.qsf",
                 "memtest/memtest.qsf", "memtest/src/memtest_top.sv", "tools/ref_matvec.py", "tools/export_q8.py",
                 "media/memtest_sweep.txt", "media/bench.txt"):
        assert (EXAMPLE / name).exists(), name
    qsf = (EXAMPLE / "sdram_stream_fabric.qsf").read_text(encoding="utf-8")
    for src in ("stream_fabric.sv", "matvec_unit.sv", "sdram_burst_ctrl.sv", "async_fifo.sv", "jtag_regs.sv",
                "sdram_loader.sv", "pll_phase_step.sv"):
        assert src in qsf, src
    for name in ("sdram_stream_fabric", "memtest"):
        assert not list(EXAMPLE.rglob(f"{name}*.sof")) and not list(EXAMPLE.rglob("*.pof"))


def test_the_pages_link_resolve_and_the_portals_point_at_it():
    for page_name in ("index.html", "spec.html"):
        page = (EXAMPLE / page_name).read_text(encoding="utf-8")
        for href in re.findall(r'href="([^"#:]+)"', page):
            assert (EXAMPLE / href).exists(), f"{page_name}: {href}"
        assert "FILL IN" not in page and "BKM-TODO" not in page
    page = (EXAMPLE / "index.html").read_text(encoding="utf-8")
    assert "196" in page and "rd_delay" in page and "6875" in page
    assert "15_sdram_stream_fabric/index.html" in (ROOT / "examples" / "index.html").read_text(encoding="utf-8")
    assert "examples/15_sdram_stream_fabric/index.html" in (ROOT / "index.html").read_text(encoding="utf-8")
    assert (ROOT / ".claude" / "skills" / "stream-from-sdram" / "SKILL.md").exists()
