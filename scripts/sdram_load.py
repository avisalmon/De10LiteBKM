"""PC <-> the DE10-Lite's 64 MB SDRAM over the USB-Blaster cable (lib/rtl/sdram_loader.sv, examples/14_usb_sdram_loader).

  python scripts/sdram_load.py status
  python scripts/sdram_load.py load <file> [--addr WORD]          file -> SDRAM, then the board CRCs it (no readback)
  python scripts/sdram_load.py read <out> --bytes N [--addr WORD]  SDRAM -> file
  python scripts/sdram_load.py verify <file> [--addr WORD]         read back over the cable and compare every byte
  python scripts/sdram_load.py check <file> [--addr WORD]          the board CRCs the range; compare with the file's
  python scripts/sdram_load.py bench [--mb N]                      time a write, the board CRC and a read back

Two routes to the cable, --via: "direct" drives the USB-Blaster itself (scripts/usb_blaster.py; Windows, ~583 KB/s
written, ~470-540 KB/s read) and "quartus" goes through quartus_stp and the JTAG server (any OS with Quartus;
~525 KB/s written, ~350 KB/s read). The default, "auto", takes the direct route and falls back to quartus when it
cannot (no driver DLL, not Windows).

Addresses are SDRAM word addresses (16-bit words, 0 .. 0x1FFFFFF); 2 file bytes make one word, the first byte in its
low half. A load is proven twice on the board: the CRC32 of what arrived (counted while writing) and the CRC32 of
what the SDRAM now holds (read back on the board at ~7 MB/s); both must equal zlib.crc32 of the file.
The design must contain sdram_loader (examples/14_usb_sdram_loader is the reference design); --instance picks the
loader when a design has more than one virtual JTAG node. Close nios2-terminal / de10.py log first (one cable user).
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from de10 import tool  # noqa: E402

TCL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sdram_load.tcl")
WORDS = 1 << 25                     # 32M words = 64 MB
CHUNK = 4 << 20                     # bytes per DR scan (progress is printed between scans)
MAGIC = 0x53444C44                  # "SDLD": the loader's status register starts with it
IR_WADDR, IR_WRITE, IR_RADDR, IR_READ, IR_STATUS, IR_CHECK = 1, 2, 3, 4, 5, 6
CHECK_TIMEOUT_S = 60.0
KB = 1024.0


class LoaderError(Exception):
    pass


def decode(words):
    """The 10 words of the status register -> a dict."""
    w = list(words)
    f = w[1]
    return dict(magic=w[0], init=f & 1, fifo_empty=f >> 1 & 1, reading=f >> 2 & 1, check_busy=f >> 3 & 1,
                check_done=f >> 4 & 1, overflow=f >> 5 & 1, underrun=f >> 6 & 1, version=f >> 8 & 0xFF,
                fifo_max=f >> 16 & 0x1F, written=w[2], wcrc=w[3], received=w[4], sent=w[5], ccrc=w[6],
                checked=w[7], user0=w[8], user1=w[9])


def decode_hex(h):
    """The status as quartus_stp prints it: 80 hex digits, most significant first."""
    return decode(int(h[80 - 8 * (i + 1):80 - 8 * i], 16) for i in range(10))


def decode_bytes(b):
    """The status as the direct route reads it: 40 bytes, the first bit shifted out first."""
    return decode(int.from_bytes(b[4 * i:4 * i + 4], "little") for i in range(10))


def progress(what, done, seconds):
    print(f"  {what} {done / (1 << 20):6.1f} MB  {done / KB / seconds:6.0f} KB/s", flush=True)


class Direct:
    """The loader through the cable itself (scripts/usb_blaster.py)."""

    name = "direct"

    def __init__(self, instance=0, chunk=CHUNK, quiet=False, jtag=None):
        """jtag: an open usb_blaster.UsbBlaster to share with another node (the caller closes it)."""
        import usb_blaster
        self.owns = jtag is None
        self.jtag = jtag or usb_blaster.UsbBlaster()
        try:
            self.node = usb_blaster.SldHub(self.jtag).find(node_id=8, instance=instance)
        except BaseException:
            if self.owns:
                self.jtag.close()
            raise
        self.chunk, self.quiet = chunk, quiet

    def close(self):
        if self.owns:
            self.jtag.close()

    def status(self):
        self.node.ir(IR_STATUS)
        return decode_bytes(self.node.read(40))

    def waddr(self, word):
        self.node.ir(IR_WADDR)
        self.node.write(word.to_bytes(8, "little"))

    def raddr(self, word):
        self.node.ir(IR_RADDR)
        self.node.write(word.to_bytes(8, "little"))

    def write(self, data):
        """data -> SDRAM at the write address; returns the seconds it took."""
        self.node.ir(IR_WRITE)
        t0 = time.perf_counter()
        view = memoryview(data)
        for i in range(0, len(data), self.chunk):
            self.node.write(view[i:i + self.chunk])
            if not self.quiet and i + self.chunk < len(data):
                progress("write", i + self.chunk, time.perf_counter() - t0)
        return time.perf_counter() - t0

    def read(self, nbytes):
        """SDRAM from the read address -> bytes; returns (data, seconds)."""
        self.node.ir(IR_READ)
        t0 = time.perf_counter()
        out = bytearray()
        while len(out) < nbytes:
            out += self.node.read(min(self.chunk, nbytes - len(out)))
            if not self.quiet and len(out) < nbytes:
                progress("read", len(out), time.perf_counter() - t0)
        return bytes(out), time.perf_counter() - t0

    def check(self, word, words):
        """The board CRCs words from word; returns (status, seconds)."""
        self.node.ir(IR_CHECK)
        self.node.write((words << 32 | word).to_bytes(8, "little"))
        t0 = time.perf_counter()
        while True:
            st = self.status()
            if st["check_done"]:
                return st, time.perf_counter() - t0
            if time.perf_counter() - t0 > CHECK_TIMEOUT_S:
                raise LoaderError(f"the board CRC did not finish in {CHECK_TIMEOUT_S:.0f} s")
            time.sleep(0.02)


class Quartus:
    """The loader through quartus_stp (scripts/sdram_load.tcl): one tool process, commands over its stdin.

    Its answers come through a file: quartus_stp holds its stdout back until it exits when stdout is a pipe.
    """

    name = "quartus"

    def __init__(self, instance=0, chunk=CHUNK, quiet=False):
        self.chunk, self.quiet = chunk, quiet
        self.tmp = tempfile.mkdtemp(prefix="sdram_load_")
        self.answers = os.path.join(self.tmp, "answers.txt")
        open(self.answers, "w").close()
        self.ans = open(self.answers, "r", errors="replace")
        self.log = os.path.join(self.tmp, "quartus_stp.log")
        with open(self.log, "w") as log:
            self.p = subprocess.Popen([tool("quartus_stp"), "-t", TCL, "-", str(instance), self.answers],
                                      stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT, text=True)
        try:
            self._cmd("status")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.p.poll() is None:
            try:
                self.p.stdin.write("quit\n")
                self.p.stdin.flush()
                self.p.wait(timeout=20)
            except (OSError, subprocess.TimeoutExpired):
                self.p.kill()
        self.ans.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _line(self):
        """The next answer line, waiting for it; None when the tool has stopped."""
        while True:
            pos = self.ans.tell()
            line = self.ans.readline()
            if line.endswith("\n"):
                return line.rstrip()
            self.ans.seek(pos)                      # a partial line: wait for the rest
            if self.p.poll() is not None:
                return None
            time.sleep(0.01)

    def _cmd(self, line):
        """Send one command; returns the lines it answered up to its OK."""
        if self.p.poll() is None:
            self.p.stdin.write(line + "\n")
            self.p.stdin.flush()
        out = []
        while True:
            ans = self._line()
            if ans is None:
                with open(self.log, errors="replace") as f:
                    errors = "; ".join(l.strip() for l in f if l.startswith("Error"))
                raise LoaderError(f"quartus_stp stopped: {errors or 'exit code %s' % self.p.poll()}")
            if ans == "OK":
                return out
            if ans.startswith("ERROR "):
                raise LoaderError(f"quartus_stp: {ans[6:]}")
            if ans.startswith("PROGRESS "):
                _, what, n, us = ans.split()
                if not self.quiet:
                    progress(what, int(n), int(us) / 1e6)
            else:
                out.append(ans)

    @staticmethod
    def _field(lines, key):
        return next(l.split()[1:] for l in lines if l.startswith(key + " "))

    @staticmethod
    def _path(p):
        return "{" + os.path.abspath(p).replace("\\", "/") + "}"

    def status(self):
        return decode_hex(self._field(self._cmd("status"), "STATUS")[0])

    def waddr(self, word):
        self._cmd(f"waddr {word}")

    def raddr(self, word):
        self._cmd(f"raddr {word}")

    def write(self, data):
        src = os.path.join(self.tmp, "src.bin")
        with open(src, "wb") as f:
            f.write(data)
        lines = self._cmd(f"write {self._path(src)} 0 {len(data)} {self.chunk}")
        return int(self._field(lines, "TIME")[2]) / 1e6

    def read(self, nbytes):
        out = os.path.join(self.tmp, "back.bin")
        open(out, "wb").close()
        lines = self._cmd(f"read {self._path(out)} {nbytes} {self.chunk}")
        with open(out, "rb") as f:
            return f.read(), int(self._field(lines, "TIME")[2]) / 1e6

    def check(self, word, words):
        lines = self._cmd(f"check {word} {words}")
        return decode_hex(self._field(lines, "STATUS")[0]), int(self._field(lines, "TIME")[2]) / 1e6


def open_loader(via="auto", instance=0, chunk=CHUNK, quiet=False):
    """The loader on the board through the chosen route; "auto" is direct, or quartus when the cable says no."""
    if via in ("auto", "direct"):
        try:
            return Direct(instance, chunk, quiet)
        except Exception as e:
            from usb_blaster import CableError
            if via == "direct" or not isinstance(e, CableError):
                raise
            print(f"direct route unavailable ({e}); taking the quartus route", flush=True)
    return Quartus(instance, chunk, quiet)


def speed(n, s):
    return n / KB / s


def loader_ok(st):
    if st["magic"] != MAGIC:
        raise LoaderError("no sdram_loader answered (wrong design on the board, or wrong --instance)")
    if not st["init"]:
        raise LoaderError("the SDRAM is not initialized (is the PLL locked? reprogram the board)")


def read_file(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % 2:
        data += b"\0"                                   # whole 16-bit words
    return data


def check_range(addr, nbytes):
    if addr < 0 or addr + nbytes // 2 > WORDS:
        raise LoaderError(f"{nbytes} bytes at word {addr:#x} do not fit in the 64 MB SDRAM")


def load(ld, data, addr, board_check=True):
    """data -> SDRAM at word addr, proven by the CRC of what arrived and (board_check) the CRC of the SDRAM."""
    check_range(addr, len(data))
    want = zlib.crc32(data)
    words = len(data) // 2
    loader_ok(ld.status())
    ld.waddr(addr)
    t = ld.write(data)
    st = ld.status()
    print(f"wrote {len(data):,} bytes in {t:.2f} s = {speed(len(data), t):.0f} KB/s ({ld.name} route)")
    ok = True
    if st["overflow"] or st["written"] != words or st["received"] != words:
        print(f"FAIL: words received {st['received']:,}, written {st['written']:,}, expected {words:,}"
              f"{' (write FIFO overflowed)' if st['overflow'] else ''}")
        ok = False
    if st["wcrc"] != want:
        print(f"FAIL: CRC32 of what arrived {st['wcrc']:08x}, file {want:08x}")
        ok = False
    if board_check:
        c, ct = ld.check(addr, words)
        good = c["ccrc"] == want and c["checked"] == words
        print(f"board CRC32 of the SDRAM {c['ccrc']:08x} over {c['checked']:,} words in {ct:.2f} s: "
              f"{'matches the file' if good else 'FAIL: the file has %08x' % want}")
        ok = ok and good
    return ok


def read(ld, addr, nbytes):
    """SDRAM from word addr -> (bytes, ok)."""
    check_range(addr, nbytes)
    loader_ok(ld.status())
    ld.raddr(addr)
    data, t = ld.read(nbytes)
    st = ld.status()
    print(f"read {len(data):,} bytes in {t:.2f} s = {speed(len(data), t):.0f} KB/s ({ld.name} route)")
    if st["underrun"] or st["sent"] != nbytes // 2:
        print(f"FAIL: words sent {st['sent']:,} of {nbytes // 2:,}{' (read underrun)' if st['underrun'] else ''}")
        return data, False
    return data, True


def cmd_load(ld, a):
    return load(ld, read_file(a.file), a.addr, not a.no_check)


def cmd_read(ld, a):
    data, ok = read(ld, a.addr, a.bytes)
    with open(a.out, "wb") as f:
        f.write(data)
    return ok


def cmd_verify(ld, a):
    data = read_file(a.file)
    back, ok = read(ld, a.addr, len(data))
    if back == data:
        print(f"OK: all {len(data):,} bytes read back equal the file")
        return ok
    bad = next((i for i in range(min(len(back), len(data))) if back[i] != data[i]), -1)
    print(f"FAIL: the read back differs (length {len(back):,} vs {len(data):,}, first difference at byte {bad})")
    return False


def cmd_check(ld, a):
    data = read_file(a.file)
    check_range(a.addr, len(data))
    loader_ok(ld.status())
    c, t = ld.check(a.addr, len(data) // 2)
    want = zlib.crc32(data)
    good = c["ccrc"] == want and c["checked"] == len(data) // 2
    print(f"board CRC32 {c['ccrc']:08x} over {c['checked']:,} words in {t:.2f} s, the file's {want:08x}: "
          f"{'OK' if good else 'FAIL'}")
    return good


def cmd_status(ld, a):
    st = ld.status()
    loader_ok(st)
    for k, v in st.items():
        print(f"  {k:11s} {v:#010x}" if k.endswith("crc") or k == "magic" else f"  {k:11s} {v:,}")
    return True


def cmd_bench(ld, a):
    """Random data: write it, let the board CRC it, read it back; one line of numbers."""
    n = a.mb << 20
    data = random.Random(a.seed).randbytes(n)
    want = zlib.crc32(data)
    loader_ok(ld.status())
    ld.quiet = True
    ld.waddr(a.addr)
    tw = ld.write(data)
    st = ld.status()
    c, tc = ld.check(a.addr, n // 2)
    ok = st["wcrc"] == want and st["written"] == n // 2 and not st["overflow"] and c["ccrc"] == want
    line = f"{ld.name:8s} {a.mb:4d} MB  write {speed(n, tw):5.0f} KB/s ({tw:6.2f} s)  board CRC {tc:5.2f} s"
    if a.read:
        ld.raddr(a.addr)
        back, tr = ld.read(n)
        rst = ld.status()
        ok = ok and back == data and not rst["underrun"]
        line += f"  read {speed(n, tr):5.0f} KB/s ({tr:6.2f} s)"
    print(f"{line}  {'OK' if ok else 'FAIL'} (CRC32 {want:08x})")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--via", choices=("auto", "direct", "quartus"), default="auto", help="the route to the cable")
    ap.add_argument("--instance", type=int, default=0, help="virtual JTAG instance of the loader (default 0)")
    ap.add_argument("--chunk", type=int, default=CHUNK, help="bytes per JTAG scan (even; default 4 MB)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("load")
    p.add_argument("file")
    p.add_argument("--addr", type=lambda s: int(s, 0), default=0)
    p.add_argument("--no-check", action="store_true", help="skip the board CRC of the SDRAM afterwards")
    p = sub.add_parser("read")
    p.add_argument("out")
    p.add_argument("--addr", type=lambda s: int(s, 0), default=0)
    p.add_argument("--bytes", type=lambda s: int(s, 0), required=True)
    for name in ("verify", "check"):
        p = sub.add_parser(name)
        p.add_argument("file")
        p.add_argument("--addr", type=lambda s: int(s, 0), default=0)
    p = sub.add_parser("bench")
    p.add_argument("--mb", type=int, default=8, help="MB of random data (default 8; 64 = the whole SDRAM)")
    p.add_argument("--addr", type=lambda s: int(s, 0), default=0)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--no-read", dest="read", action="store_false", help="skip the read back")
    a = ap.parse_args()
    if a.chunk % 2 or a.chunk < 2:
        sys.exit("FAIL: --chunk must be even (whole 16-bit words)")
    cmd = dict(status=cmd_status, load=cmd_load, read=cmd_read, verify=cmd_verify, check=cmd_check, bench=cmd_bench)
    try:
        ld = open_loader(a.via, a.instance, a.chunk)
    except Exception as e:
        sys.exit(f"FAIL: {e}")
    try:
        ok = cmd[a.cmd](ld, a)
    except LoaderError as e:
        ok = False
        print(f"FAIL: {e}")
    except Exception as e:                                # a cable error: say what and stop
        ok = False
        print(f"FAIL: {type(e).__name__}: {e}")
    finally:
        ld.close()
    print("OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
