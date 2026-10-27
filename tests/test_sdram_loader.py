"""The USB -> SDRAM loader (example 14): the pure parts of the cable driver and of the loader script are checked
here without a board (a fake loader stands in for the cable), the loader's testbench passes when Icarus Verilog is
installed, and the example is complete and reachable from the portal pages."""

import random
import re
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "examples" / "14_usb_sdram_loader"
PY = sys.executable
sys.path.insert(0, str(ROOT / "scripts"))
import sdram_load as sl  # noqa: E402
import usb_blaster as ub  # noqa: E402

ICARUS = shutil.which("iverilog") is not None or Path(r"C:\oss-cad-suite-20261009").exists()


# --- the cable driver's pure parts (scripts/usb_blaster.py) ---

def test_one_tck_cycle_is_two_bitbang_bytes():
    low, high = ub.clock(tms=1, tdi=1, read=True)
    assert low == ub.IDLE | ub.TMS | ub.TDI
    assert high == low | ub.TCK | ub.READ
    assert ub.clock(0) == bytes((ub.IDLE, ub.IDLE | ub.TCK))     # READ only when asked: an answer byte costs USB time


def test_shift_bits_sends_lsb_first_and_leaves_shift_on_the_last_bit():
    out = ub.shift_bits(0b1011, 4)
    assert len(out) == 8
    tdi = [bool(out[2 * i] & ub.TDI) for i in range(4)]
    tms = [bool(out[2 * i] & ub.TMS) for i in range(4)]
    assert tdi == [True, True, False, True]
    assert tms == [False, False, False, True]


def test_ir_and_dr_scans_walk_the_tap_state_machine():
    assert ub.ir_scan(ub.USER1) == ub.TO_SHIFT_IR + ub.shift_bits(ub.USER1, 10) + ub.TO_IDLE
    assert ub.dr_scan(5, 3, read=True) == ub.TO_SHIFT_DR + ub.shift_bits(5, 3, read=True) + ub.TO_IDLE
    assert len(ub.TO_SHIFT_IR) == 8 and len(ub.TO_SHIFT_DR) == 6 and len(ub.TO_IDLE) == 4


def test_byte_shift_frames_carry_63_bytes_per_header():
    body = bytes(range(130))
    out = ub.frame(body)
    assert out[0] == 0x80 | 63 and out[64] == 0x80 | 63 and out[128] == 0x80 | 4
    assert out[1:64] == body[:63] and out[65:128] == body[63:126] and out[129:] == body[126:]
    assert ub.frame(body[:63], read=True)[0] == 0xFF
    assert ub.frame(b"") == b""


def test_bits_rebuilds_a_bitbanged_answer():
    assert ub.bits(bytes((1, 0, 1, 1))) == 0b1101
    assert ub.bits(bytes((0xFF, 0xFE))) == 1                     # only bit 0 of each answer byte is TDO


def test_sld_hub_words_decode_as_on_the_board():
    version, nodes, mfg, m = ub.node_fields(0x08106E05)          # the hub's own word, read on the DE10-Lite
    assert (version, nodes, mfg, m) == (1, 2, ub.ALTERA, 5)
    version, node_id, mfg, inst = ub.node_fields(0x00406E00)      # the loader (sld_virtual_jtag)
    assert (node_id, mfg, inst) == (8, ub.ALTERA, 0)
    assert ub.node_fields(0x0C006E00)[1] == 128                   # the JTAG UART
    assert ub.NODE_NAMES[8].startswith("virtual JTAG")


# --- the loader script's pure parts (scripts/sdram_load.py) ---

STATUS_WORDS = [sl.MAGIC, 1 | 1 << 1 | 1 << 8 | 7 << 16, 1234, 0xDEADBEEF, 1234, 0, 0xCAFEBABE, 0, 0x11, 0x22]


def test_status_decodes_the_same_from_both_routes():
    as_hex = "".join(f"{w:08X}" for w in reversed(STATUS_WORDS))                 # quartus_stp: MSB first
    as_bytes = b"".join(w.to_bytes(4, "little") for w in STATUS_WORDS)           # the cable: first bit first
    st = sl.decode_hex(as_hex)
    assert st == sl.decode_bytes(as_bytes)
    assert st["magic"] == sl.MAGIC and sl.MAGIC.to_bytes(4, "big") == b"SDLD"
    assert (st["init"], st["fifo_empty"], st["reading"], st["version"], st["fifo_max"]) == (1, 1, 0, 1, 7)
    assert (st["written"], st["wcrc"], st["ccrc"], st["user0"], st["user1"]) == (1234, 0xDEADBEEF, 0xCAFEBABE, 0x11, 0x22)


def test_the_status_must_come_from_a_live_loader():
    sl.loader_ok(sl.decode(STATUS_WORDS))
    with pytest.raises(sl.LoaderError, match="no sdram_loader"):
        sl.loader_ok(sl.decode([0] + STATUS_WORDS[1:]))
    with pytest.raises(sl.LoaderError, match="not initialized"):
        sl.loader_ok(sl.decode([sl.MAGIC, 0] + STATUS_WORDS[2:]))


def test_addresses_are_word_addresses_in_64_mb():
    sl.check_range(0, 2 * sl.WORDS)
    sl.check_range(sl.WORDS - 1, 2)
    with pytest.raises(sl.LoaderError):
        sl.check_range(sl.WORDS - 1, 4)
    with pytest.raises(sl.LoaderError):
        sl.check_range(-1, 2)


def test_files_are_padded_to_whole_words(tmp_path):
    p = tmp_path / "odd.bin"
    p.write_bytes(b"abc")
    assert sl.read_file(p) == b"abc\0"
    p.write_bytes(b"abcd")
    assert sl.read_file(p) == b"abcd"


class FakeLoader:
    """A board in memory: the same calls Direct and Quartus answer, with the loader's counters and CRCs."""

    name = "fake"

    def __init__(self, corrupt_word=None):
        self.mem = {}
        self.wptr = self.rptr = 0
        self.written = self.received = self.sent = 0
        self.wcrc = self.ccrc = self.checked = 0
        self.overflow = self.underrun = 0
        self.corrupt_word = corrupt_word

    def status(self):
        flags = 1 | 1 << 1 | 1 << 4 | self.overflow << 5 | self.underrun << 6 | 1 << 8
        return sl.decode([sl.MAGIC, flags, self.written, self.wcrc, self.received, self.sent, self.ccrc,
                          self.checked, 0, 0])

    def waddr(self, word):
        self.wptr, self.written, self.received, self.wcrc = word, 0, 0, 0

    def raddr(self, word):
        self.rptr, self.sent = word, 0

    def write(self, data):
        self.wcrc = zlib.crc32(data, self.wcrc)
        for i in range(0, len(data), 2):
            self.mem[self.wptr] = data[i:i + 2]
            self.wptr += 1
        self.written = self.received = self.written + len(data) // 2
        return 0.5

    def read(self, nbytes):
        out = b"".join(self.mem.get(self.rptr + i, b"\0\0") for i in range(nbytes // 2))
        self.rptr += nbytes // 2
        self.sent += nbytes // 2
        return out, 0.5

    def check(self, word, words):
        data = bytearray(b"".join(self.mem.get(word + i, b"\0\0") for i in range(words)))
        if self.corrupt_word is not None:
            data[2 * (self.corrupt_word - word)] ^= 1
        self.ccrc, self.checked = zlib.crc32(bytes(data)), words
        return self.status(), 0.1


def test_load_proves_a_file_by_the_boards_crc_and_read_brings_it_back(capsys):
    data = random.Random(1).randbytes(3000)
    ld = FakeLoader()
    assert sl.load(ld, data, 0x100) is True
    back, ok = sl.read(ld, 0x100, len(data))
    assert ok and back == data
    out = capsys.readouterr().out
    assert "wrote 3,000 bytes" in out and "matches the file" in out and "read 3,000 bytes" in out


def test_load_fails_when_the_sdram_holds_something_else(capsys):
    data = bytes(range(256)) * 4
    assert sl.load(FakeLoader(corrupt_word=0x300), data, 0x300) is False
    assert "FAIL: the file has" in capsys.readouterr().out


def test_read_reports_an_underrun(capsys):
    ld = FakeLoader()
    sl.load(ld, b"\x01\x02\x03\x04", 0, board_check=False)
    ld.underrun = 1
    _, ok = sl.read(ld, 0, 4)
    assert ok is False and "read underrun" in capsys.readouterr().out


def test_the_cli_has_every_command_and_both_routes():
    text = (ROOT / "scripts" / "sdram_load.py").read_text(encoding="utf-8")
    for cmd in ("status", "load", "read", "verify", "check", "bench"):
        assert f'"{cmd}"' in text, cmd
    assert '"auto", "direct", "quartus"' in text
    tcl = (ROOT / "scripts" / "sdram_load.tcl").read_text(encoding="utf-8")
    assert "-buffering none" in tcl                               # gotcha 31: answers go through a file, not stdout
    assert re.search(r"global\s+inst\s+IR_WRITE\s+IR_STATUS", tcl)   # a timed write ends with a captured STATUS scan


# --- the RTL ---

@pytest.mark.skipif(not ICARUS, reason="Icarus Verilog is not installed")
def test_the_loader_testbench_passes():
    p = subprocess.run([PY, "scripts/sim.py", "lib/sim/tb_sdram_loader.sv", "-D", "SDRAM_LOADER_SIM"],
                       cwd=ROOT, capture_output=True, text=True, timeout=900)
    out = p.stdout + p.stderr
    assert p.returncode == 0 and "\nPASS" in out and "FAIL" not in out, out[-3000:]
    assert re.search(r"3 checks.*overflow and underrun caught.*0 errors", out), out[-3000:]


def test_the_rtl_documents_its_protocol():
    rtl = (ROOT / "lib" / "rtl" / "sdram_loader.sv").read_text(encoding="utf-8")
    assert "IR_WADDR = 4'd1, IR_WRITE = 4'd2, IR_RADDR = 4'd3, IR_READ = 4'd4, IR_STATUS = 4'd5, IR_CHECK = 4'd6" in rtl
    assert f"32'h{sl.MAGIC:08X}" in rtl
    assert "sld_virtual_jtag" in rtl


# --- the example and its pages ---

def test_the_example_is_complete():
    for name in ("index.html", "usb_sdram_loader.qar", "usb_sdram_loader.qsf", "usb_sdram_loader.qpf",
                 "usb_sdram_loader.sdc", "src/loader_top.sv", "src/extra.qsf", "media/bench.txt"):
        assert (EXAMPLE / name).exists(), name
    qsf = (EXAMPLE / "usb_sdram_loader.qsf").read_text(encoding="utf-8")
    assert "sdram_loader.sv" in qsf and "sdram_ctrl.sv" in qsf
    assert "583 KB/s" in (EXAMPLE / "media" / "bench.txt").read_text(encoding="utf-8")


def test_the_page_links_resolve_and_the_portals_point_at_it():
    page = (EXAMPLE / "index.html").read_text(encoding="utf-8")
    for href in re.findall(r'href="([^"#:]+)"', page):
        assert (EXAMPLE / href).exists(), href
    assert "583 KB/s" in page and "gotchas.md" in page
    assert '14_usb_sdram_loader/index.html' in (ROOT / "examples" / "index.html").read_text(encoding="utf-8")
    assert 'examples/14_usb_sdram_loader/index.html' in (ROOT / "index.html").read_text(encoding="utf-8")
    assert (ROOT / ".claude" / "skills" / "load-sdram-usb" / "SKILL.md").exists()
