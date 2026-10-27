"""Peek and poke a design's 32-bit registers over the USB-Blaster cable (lib/rtl/jtag_regs.sv).

  python scripts/jtag_regs.py id                      which design answers (the ID parameter)
  python scripts/jtag_regs.py peek ADDR [N]           read N registers from ADDR (hex or decimal)
  python scripts/jtag_regs.py poke ADDR VALUE [...]   write one or more words from ADDR
  python scripts/jtag_regs.py watch ADDR [--every S]  print the register until Ctrl-C

The node: a 4-bit virtual IR, 1 ADDR (16 bits in), 2 WRITE (32 in, then ADDR + 1), 3 READ (32 out, then ADDR + 1),
4 ID (32 out). Direct route only (scripts/usb_blaster.py: Windows with the USB-Blaster driver); --instance picks
the node when a design has several (jtag_regs defaults to instance 1, the loader of example 14 is 0). Close
nios2-terminal / de10.py log first: one program at a time owns the cable.
Library use: with JtagRegs() as r: r.poke(1, 1); print(r.peek(0)); words = r.peek(8, 4).
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

IR_ADDR, IR_WRITE, IR_READ, IR_ID = 1, 2, 3, 4
NODE_ID = 8                         # sld_virtual_jtag


class JtagRegs:
    def __init__(self, instance=1):
        import usb_blaster
        self.jtag = usb_blaster.UsbBlaster()
        try:
            self.node = usb_blaster.SldHub(self.jtag).find(node_id=NODE_ID, instance=instance)
        except BaseException:
            self.jtag.close()
            raise
        self._ir = None

    def close(self):
        self.jtag.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _select(self, ir):
        if self._ir != ir:
            self.node.ir(ir)
            self._ir = ir

    def id(self):
        self._select(IR_ID)
        return self.node.dr(0, 32, read=True)

    def addr(self, a):
        self._select(IR_ADDR)
        self.node.dr(a & 0xFFFF, 16)

    def peek(self, a, n=None):
        """One register (an int), or a list of n registers from a."""
        self.addr(a)
        self._select(IR_READ)
        words = [self.node.dr(0, 32, read=True) for _ in range(n or 1)]
        return words if n is not None else words[0]

    def poke(self, a, *values):
        self.addr(a)
        self._select(IR_WRITE)
        for v in values:
            self.node.dr(v & 0xFFFFFFFF, 32)

    def wait(self, a, mask, value=None, timeout=5.0, every=0.002):
        """Poll register a until (reg & mask) == value (default: == mask); returns the register."""
        want = mask if value is None else value
        t_end = time.perf_counter() + timeout
        while True:
            w = self.peek(a)
            if (w & mask) == want:
                return w
            if time.perf_counter() > t_end:
                raise TimeoutError(f"register {a:#x} = {w:08X}: bits {mask:#x} did not become {want:#x} "
                                   f"within {timeout} s")
            time.sleep(every)


def num(s):
    return int(s, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--instance", type=int, default=1)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("id")
    p = sub.add_parser("peek")
    p.add_argument("addr", type=num)
    p.add_argument("n", type=num, nargs="?", default=1)
    p = sub.add_parser("poke")
    p.add_argument("addr", type=num)
    p.add_argument("values", type=num, nargs="+")
    p = sub.add_parser("watch")
    p.add_argument("addr", type=num)
    p.add_argument("--every", type=float, default=0.5)
    a = ap.parse_args()
    with JtagRegs(a.instance) as r:
        if a.cmd == "id":
            print(f"ID {r.id():08X}")
        elif a.cmd == "peek":
            for i, w in enumerate(r.peek(a.addr, a.n)):
                print(f"{a.addr + i:#06x}  {w:08X}  {w}")
        elif a.cmd == "poke":
            r.poke(a.addr, *a.values)
            print(f"wrote {len(a.values)} word(s) from {a.addr:#06x}")
        elif a.cmd == "watch":
            try:
                while True:
                    print(f"{time.strftime('%H:%M:%S')}  {a.addr:#06x}  {r.peek(a.addr):08X}", flush=True)
                    time.sleep(a.every)
            except KeyboardInterrupt:
                pass


if __name__ == "__main__":
    main()
