"""Direct JTAG through the DE10-Lite's on-board USB-Blaster, without the Quartus JTAG server: the fast way.

  python scripts/usb_blaster.py            the cable, the FPGA and the virtual JTAG nodes of the design on it

  from usb_blaster import UsbBlaster, SldHub
  with UsbBlaster() as jtag:               # opens the cable; Quartus tools cannot use it until the block ends
      print(f"{jtag.idcode():08X}")        # 031050DD = the DE10-Lite's MAX 10 (10M50)
      node = SldHub(jtag).find(node_id=8)  # an sld_virtual_jtag node (id 8), instance 0
      node.ir(2)                           # its virtual IR
      node.write(data)                     # one long DR scan of whole bytes at the cable's full speed
      back = node.read(1024)               # one long DR scan, returning what came out of TDO

Why: every Quartus tool (quartus_stp, jtagconfig, nios2-terminal) reaches the cable through the JTAG server, which caps
a long virtual JTAG scan at ~525 KB/s written and ~350 KB/s read. Driving the cable directly reaches the cable's own
limit: 583 KB/s written, 470-540 KB/s read (examples/14_usb_sdram_loader; KB = 1024 bytes).

How: the on-board USB-Blaster is an FTDI FT245 USB FIFO in front of a small CPLD that turns bytes into JTAG. Quartus
installs FTDI's D2XX driver under its own name (drivers/usb-blaster/x64/usbblstr64.dll, service AlteraUSBBlaster), and
ctypes calls it. Windows only, no admin rights needed. One user of the cable at a time: opening fails with CableBusy
while a Quartus tool has it, and Quartus tools fail while a script here has it (they work again after close()).

The cable's byte protocol (Kolja Waschk's usb_jtag, also used by OpenOCD and UrJTAG):
  bit-bang byte, bit 7 = 0: bit 0 TCK, 1 TMS, 2 nCE, 3 nCS, 4 TDI, 5 LED, 6 READ (the cable answers one byte whose
      bit 0 is TDO). One TCK cycle is two bytes: TCK low with the new TMS and TDI, then TCK high.
  shift header, bit 7 = 1: bits 5..0 = n (1..63); n data bytes follow, each shifted out LSB first on TDI at the fixed
      6 MHz TCK while TMS stays low; with bit 6 (READ) the cable answers n bytes of TDO.
So a long scan goes out as 64 bytes per 63 data bytes, its last bit bit-banged with TMS = 1 to leave Shift-DR. The
cable's CPLD needs ~41 clocks of 24 MHz per byte, so ~580 KB/s is the ceiling for writing; a read also sends every
byte back, which brings the full-speed USB bus (12 Mb/s, shared by both directions) near its limit, so reads vary
with the bus's scheduling. Every scan here starts and ends in Run-Test/Idle. The chain is the DE10-Lite's: one device,
the MAX 10, with a 10-bit IR.

Safety: the cable has no framing, so if a byte were ever lost or misread, data bytes would be taken for commands; a
random command stream could even pulse the FPGA's nCONFIG (it then reloads its flash) or fill the cable's answer FIFO
until it stalls. Both show up as bytes arriving when none were asked for, or as a write that stalls: dr_write checks
the receive queue after every block and dr_read checks the count, and both raise CableError and reset the TAP, so the
caller can verify (the loader's CRC) and retry.
"""
import ctypes
import os
import sys
import time
from ctypes import byref, c_char_p, c_uint32, c_void_p

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TCK, TMS, NCE, NCS, TDI, LED, READ, SHIFT = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
IDLE = NCE | NCS | LED                      # a bit-bang byte with TCK, TMS and TDI low
IR_BITS = 10                                # the MAX 10's instruction register
IDCODE, USER0, USER1 = 0x006, 0x00C, 0x00E
WRITE_BLOCK = 63 * 1024                     # data bytes per USB write within a long scan (64 KB: 583 KB/s)
READ_BLOCK = 63 * 1024                      # TDO bytes asked for at a time within a long read
TIMEOUT_S = 10.0                            # a read that does not complete within this is an error
WRITE_TIMEOUT_S = 3.0                       # a 64 KB block takes 0.11 s; a stalled cable is detected within this
ALTERA = 0x6E                               # manufacturer id of Intel's (Altera's) virtual JTAG nodes
NODE_NAMES = {8: "virtual JTAG (sld_virtual_jtag)", 128: "JTAG UART"}


class CableError(IOError):
    pass


class CableBusy(CableError):
    pass


def clock(tms, tdi=0, read=False):
    """One TCK cycle in bit-bang mode; with read the cable answers TDO, sampled as TCK rises."""
    b = IDLE | (TMS if tms else 0) | (TDI if tdi else 0)
    return bytes((b, b | TCK | (READ if read else 0)))


def tms_path(*tms):
    return b"".join(clock(t) for t in tms)


def shift_bits(value, n, read=False):
    """n bits of value, LSB first, the last one with TMS = 1 (Shift -> Exit1)."""
    return b"".join(clock(i == n - 1, value >> i & 1, read) for i in range(n))


TO_SHIFT_DR = tms_path(1, 0, 0)             # Run-Test/Idle -> Select-DR -> Capture-DR -> Shift-DR
TO_SHIFT_IR = tms_path(1, 1, 0, 0)          # Run-Test/Idle -> Select-DR -> Select-IR -> Capture-IR -> Shift-IR
TO_IDLE = tms_path(1, 0)                    # Exit1 -> Update -> Run-Test/Idle


def ir_scan(value, n=IR_BITS):
    return TO_SHIFT_IR + shift_bits(value, n) + TO_IDLE


def dr_scan(value, n, read=False):
    return TO_SHIFT_DR + shift_bits(value, n, read) + TO_IDLE


def frame(body, read=False):
    """Byte-shift mode: a header byte (0x80 | n, plus 0x40 to read TDO back) before every n <= 63 data bytes."""
    cmd = SHIFT | (READ if read else 0)
    head = bytes((cmd | 63,))
    full = len(body) // 63 * 63
    parts = []
    for i in range(0, full, 63):
        parts += (head, body[i:i + 63])
    if full < len(body):
        parts += (bytes((cmd | len(body) - full,)), body[full:])
    return b"".join(parts)


def bits(answer):
    """The value a bit-banged read scan captured: bit 0 of each answer byte, the first byte is the LSB."""
    return sum((b & 1) << i for i, b in enumerate(answer))


def node_fields(word):
    """An SLD hub info word -> (version, id, manufacturer, instance); for the hub's own word the last is m."""
    return word >> 27, word >> 19 & 0xFF, word >> 8 & 0x7FF, word & 0xFF


_dll = None


def dll():
    """FTDI's D2XX API from the USB-Blaster driver that Quartus installed."""
    global _dll
    if _dll:
        return _dll
    if os.name != "nt":
        raise CableError("the direct USB-Blaster route is Windows-only here; use the Quartus route")
    from de10 import QUARTUS_CANDIDATES
    sub = r"drivers\usb-blaster\x64\usbblstr64.dll" if sys.maxsize > 2 ** 32 else r"drivers\usb-blaster\x32\usbblstr32.dll"
    paths = [os.environ.get("USB_BLASTER_DLL", "")] + [os.path.join(r, sub) for r in QUARTUS_CANDIDATES if r]
    path = next((p for p in paths if p and os.path.exists(p)), None)
    if not path:
        raise CableError("the USB-Blaster driver DLL (usbblstr64.dll) was not found: install Quartus Prime Lite 17.1 "
                         "with its USB-Blaster driver, or set USB_BLASTER_DLL")
    d = ctypes.WinDLL(path)
    p32 = ctypes.POINTER(c_uint32)
    d.FT_CreateDeviceInfoList.argtypes = [p32]
    d.FT_GetDeviceInfoDetail.argtypes = [c_uint32, p32, p32, p32, p32, c_char_p, c_char_p, ctypes.POINTER(c_void_p)]
    d.FT_Open.argtypes = [ctypes.c_int, ctypes.POINTER(c_void_p)]
    d.FT_Close.argtypes = [c_void_p]
    d.FT_ResetDevice.argtypes = [c_void_p]
    d.FT_Purge.argtypes = [c_void_p, c_uint32]
    d.FT_SetLatencyTimer.argtypes = [c_void_p, ctypes.c_ubyte]
    d.FT_SetUSBParameters.argtypes = [c_void_p, c_uint32, c_uint32]
    d.FT_SetTimeouts.argtypes = [c_void_p, c_uint32, c_uint32]
    d.FT_Write.argtypes = [c_void_p, c_char_p, c_uint32, p32]
    d.FT_Read.argtypes = [c_void_p, c_void_p, c_uint32, p32]
    d.FT_GetQueueStatus.argtypes = [c_void_p, p32]
    _dll = d
    return d


def cables():
    """The USB-Blaster (I) cables plugged in: [{index, desc, serial, busy}]; busy = another program has it open."""
    d = dll()
    n = c_uint32()
    if d.FT_CreateDeviceInfoList(byref(n)):
        raise CableError("cannot list the USB devices of the USB-Blaster driver")
    found = []
    for i in range(n.value):
        flags, kind, dev_id, loc = c_uint32(), c_uint32(), c_uint32(), c_uint32()
        serial, desc, h = ctypes.create_string_buffer(16), ctypes.create_string_buffer(64), c_void_p()
        if d.FT_GetDeviceInfoDetail(i, byref(flags), byref(kind), byref(dev_id), byref(loc), serial, desc, byref(h)):
            continue
        if desc.value.startswith(b"USB-Blaster"):
            found.append(dict(index=i, desc=desc.value.decode(errors="replace"),
                              serial=serial.value.decode(errors="replace"), busy=bool(flags.value & 1)))
    return found


class UsbBlaster:
    """The on-board USB-Blaster opened directly. Use it in a with block; scans start and end in Run-Test/Idle."""

    def __init__(self, cable=0):
        self.d, self.h = dll(), None
        found = cables()
        if not found:
            raise CableError("no USB-Blaster found: is the board plugged in through its USB-Blaster port?")
        if cable >= len(found):
            raise CableError(f"there is no USB-Blaster number {cable}; {len(found)} found")
        c = found[cable]
        busy = CableBusy("the USB-Blaster is in use by another program (a Quartus tool, nios2-terminal, de10.py log "
                         "or another script): close it and try again")
        if c["busy"]:
            raise busy
        h = c_void_p()
        st = self.d.FT_Open(c["index"], byref(h))
        if st == 3:                                   # FT_DEVICE_NOT_OPENED: someone else has it
            raise busy
        if st:
            raise CableError(f"cannot open the USB-Blaster (FT_Open error {st})")
        self.h, self.name = h, f"{c['desc']} {c['serial']}"
        try:
            for call, args in (("FT_ResetDevice", ()), ("FT_SetUSBParameters", (65536, 65536)),
                               ("FT_SetLatencyTimer", (2,)),
                               ("FT_SetTimeouts", (1000, int(WRITE_TIMEOUT_S * 1000))),
                               ("FT_Purge", (3,))):
                st = getattr(self.d, call)(self.h, *args)
                if st:
                    raise CableError(f"{call} failed (error {st})")
            self.reset()
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.h:
            try:
                self._write(bytes((IDLE & ~LED,)))
            except CableError:
                pass
            self.d.FT_Close(self.h)
            self.h = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _write(self, buf):
        n = c_uint32()
        st = self.d.FT_Write(self.h, bytes(buf), len(buf), byref(n))
        if st or n.value != len(buf):
            self._recover()
            raise CableError(f"USB write failed (error {st}, {n.value} of {len(buf)} bytes): the cable stalled or was "
                             "unplugged; check the board (did it reload its flash design?) and try again")

    def _recover(self):
        """After a stall or a stream out of sync: drop what is queued both ways and put the TAP back in a known state."""
        try:
            self.d.FT_Purge(self.h, 3)
            seq = tms_path(1, 1, 1, 1, 1, 0) + bytes((IDLE,))
            self.d.FT_Write(self.h, seq, len(seq), byref(c_uint32()))
            self.d.FT_Purge(self.h, 3)
        except Exception:
            pass

    def _check_sync(self, expected=0):
        """Bytes in the receive queue beyond the expected ones mean the cable misread the stream: stop at once."""
        extra = self._available() - expected
        if extra > 0:
            self._recover()
            raise CableError(f"the cable's byte stream went out of sync ({extra} unexpected bytes came back); the scan "
                             "was abandoned and the TAP reset: verify the data on the board and repeat the transfer")

    def _available(self):
        n = c_uint32()
        if self.d.FT_GetQueueStatus(self.h, byref(n)):
            raise CableError("USB status failed: was the cable unplugged?")
        return n.value

    def _read(self, k):
        buf = ctypes.create_string_buffer(k)
        pos, n, t0 = 0, c_uint32(), time.monotonic()
        while pos < k:
            if self.d.FT_Read(self.h, ctypes.addressof(buf) + pos, k - pos, byref(n)):
                raise CableError("USB read failed: was the cable unplugged?")
            pos += n.value
            if pos < k and time.monotonic() - t0 > TIMEOUT_S:
                raise CableError(f"the cable answered {pos} of {k} bytes")
        return buf.raw

    def run(self, seq, answer=0):
        """Send prebuilt bit-bang bytes (ir_scan, dr_scan, ...) at once; returns the bytes their READ clocks answer."""
        self._write(seq + bytes((IDLE,)))
        return self._read(answer) if answer else b""

    def reset(self):
        """Test-Logic-Reset, then Run-Test/Idle."""
        self.run(tms_path(1, 1, 1, 1, 1, 0))

    def ir(self, value, n=IR_BITS):
        self.run(ir_scan(value, n))

    def dr(self, value, n, read=False):
        """A short DR scan, bit-banged; returns the captured value when read."""
        a = self.run(dr_scan(value, n, read), n if read else 0)
        return bits(a) if read else None

    def idcode(self):
        self.ir(IDCODE)
        return self.dr(0, 32, read=True)

    def dr_write(self, data):
        """One DR scan of whole bytes, write only: bit 0 of data[0] goes first."""
        n = len(data)
        if not n:
            raise ValueError("a scan needs at least one byte")
        view = memoryview(data).cast("B")
        self._write(TO_SHIFT_DR)
        for i in range(0, n - 1, WRITE_BLOCK):
            self._write(frame(view[i:min(i + WRITE_BLOCK, n - 1)]))
            self._check_sync()
        self.run(shift_bits(view[n - 1], 8) + TO_IDLE)
        self._check_sync()

    def dr_read(self, n):
        """One DR scan of n whole bytes shifting zeros in; returns TDO, the first bit out in bit 0 of byte 0."""
        if n < 1:
            raise ValueError("a scan needs at least one byte")
        self._write(TO_SHIFT_DR)
        got, asked = bytearray(), 0
        zeros = bytes(min(READ_BLOCK, n))
        while asked < n - 1:
            k = min(READ_BLOCK, n - 1 - asked)
            self._write(frame(zeros[:k], read=True))
            asked += k
            # collect what came back, never leaving more than one block in the driver (its buffer holds 64 KB)
            waiting = self._available()
            if len(got) + waiting > asked:
                self._check_sync(asked - len(got))
            got += self._read(max(asked - len(got) - READ_BLOCK, waiting))
        self._write(shift_bits(0, 8, read=True) + TO_IDLE + bytes((IDLE,)))
        got += self._read(n - 1 + 8 - len(got))
        self._check_sync()
        return bytes(got[:n - 1]) + bytes((bits(got[n - 1:n + 7]),))


class VirtualNode:
    """One node behind the SLD hub, e.g. an sld_virtual_jtag instance."""

    def __init__(self, hub, addr, word):
        self.hub, self.jtag, self.addr, self.word = hub, hub.jtag, addr, word
        self.version, self.id, self.mfg, self.instance = node_fields(word)

    def __repr__(self):
        name = NODE_NAMES.get(self.id, "?") if self.mfg == ALTERA else "?"
        return f"node {self.addr}: {self.word:08X} {name}, id {self.id}, manufacturer {self.mfg:#x}, instance {self.instance}"

    def vir_value(self, value):
        """The USER1 scan that sets this node's virtual IR: (address << m) | value, m + address bits long."""
        return self.addr << self.hub.m | value, self.hub.m + self.hub.addr_bits

    def ir(self, value):
        """Set the virtual IR; the cable's IR is left at USER0, ready for this node's DR scans."""
        v, n = self.vir_value(value)
        self.jtag.run(ir_scan(USER1) + dr_scan(v, n) + ir_scan(USER0))

    def dr(self, value, n, read=False):
        return self.jtag.dr(value, n, read)

    def write(self, data):
        self.jtag.dr_write(data)

    def read(self, n):
        return self.jtag.dr_read(n)


class SldHub:
    """The hub Quartus adds to a design with virtual JTAG nodes (sld_virtual_jtag, JTAG UART, Signal Tap).

    IR = USER1 with a scan of zeros selects the hub's info register; then, with IR = USER0, eight 4-bit DR reads make
    a 32-bit word, low nibble first: the hub's own word ([31:27] version, [26:19] N nodes, [18:8] manufacturer 0x6E,
    [7:0] m = the widest node IR), then one word per node ([31:27] version, [26:19] id, [18:8] manufacturer,
    [7:0] instance), the words jtagconfig -n prints (0C006E00 = JTAG UART). A node's virtual IR is a USER1 scan of
    m + ceil(log2(N + 1)) bits, (address << m) | value, nodes numbered from 1; its data are USER0 DR scans.
    """

    def __init__(self, jtag):
        self.jtag = jtag
        jtag.run(ir_scan(USER1) + dr_scan(0, 64) + ir_scan(USER0))
        hub = self._words(1)[0]
        self.version, count, self.mfg, self.m = node_fields(hub)
        if self.mfg != ALTERA or not count:
            raise CableError(f"no virtual JTAG hub answered (hub word {hub:08X}): the design on the FPGA has no "
                             "virtual JTAG nodes, or the FPGA is not programmed")
        self.addr_bits = count.bit_length()          # ceil(log2(count + 1))
        self.nodes = [VirtualNode(self, a + 1, w) for a, w in enumerate(self._words(count))]

    def _words(self, count):
        a = self.jtag.run(dr_scan(0, 4, read=True) * (8 * count), 32 * count)
        return [sum(bits(a[32 * w + 4 * i:32 * w + 4 * i + 4]) << 4 * i for i in range(8)) for w in range(count)]

    def find(self, node_id, instance=0, mfg=ALTERA):
        for node in self.nodes:
            if (node.id, node.instance, node.mfg) == (node_id, instance, mfg):
                return node
        have = "; ".join(map(repr, self.nodes))
        raise CableError(f"no virtual JTAG node with id {node_id}, instance {instance} in this design (it has: {have})")


def main():
    found = cables()
    if not found:
        sys.exit("FAIL: no USB-Blaster found: is the board plugged in?")
    for i, c in enumerate(found):
        print(f"cable {i}: {c['desc']} {c['serial']}{' (in use by another program)' if c['busy'] else ''}")
    with UsbBlaster() as jtag:
        code = jtag.idcode()
        print(f"IDCODE {code:08X}{' = MAX 10 10M50 (DE10-Lite)' if code == 0x031050DD else ''}")
        try:
            hub = SldHub(jtag)
        except CableError as e:
            print(e)
            return
        print(f"SLD hub: {len(hub.nodes)} nodes, virtual IR {hub.m} bits + {hub.addr_bits} address bits")
        for node in hub.nodes:
            print(f"  {node!r}")


if __name__ == "__main__":
    try:
        main()
    except CableError as e:
        sys.exit(f"FAIL: {e}")
