"""RV32I instruction-set simulator of the Tetris SoC: the CPU, the 32 KB RAM, the text screen and the I/O registers.

    python tools/rv32sim.py build/prog.hex [--frames N] [--keys "10:left,12:a,30:down*20"] [--screen out.txt]
                                          [--trace out.trc] [--max 20000000] [--uart]
Runs until the program writes IO_EXIT (exit code = the value), ecall, or --max instructions. A "frame" is
FRAME_CYCLES cycles of 4 per instruction (the RTL takes 3-4), so the FRAME register and key timing behave as on the
board at 60 Hz. --keys holds a button for one frame at the given frame (name*N holds it N frames); the RTL and the
board get the same presses through the USB letters. --screen writes the 80 x 60 text as lines (block glyphs as #, +,
:, [ ). --trace writes one line per instruction with a register or memory write, for lock-step comparison with the RTL
(tools/trace_compare.py): "pc rd value" or "pc W addr value mask".
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from memmap import IO, IO_BASE, RAM_SIZE, TEXT_BASE, TEXT_COLS, TEXT_ROWS  # noqa: E402

FRAME_CYCLES = 25_000_000 // 60
CYCLES_PER_INSTR = 4
BUTTON_BITS = {"a": 1, "b": 2, "select": 4, "start": 8, "down": 16, "up": 32, "right": 64, "left": 128,
               "key0": 256, "key1": 512}
GLYPH = {0x80: "#", 0x81: "+", 0x82: ":", 0x83: "["}


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class Exit(Exception):
    def __init__(self, code):
        self.code = code


class SoC:
    def __init__(self, image, trace=None, uart_echo=False):
        self.mem = bytearray(RAM_SIZE)
        self.mem[:len(image)] = image
        self.text = [[0x20] * TEXT_COLS for _ in range(TEXT_ROWS)]
        self.regs = [0] * 32
        self.pc = 0
        self.cycles = 0
        self.instrs = 0
        self.lfsr = 0xACE1_1234
        self.buttons = 0
        self.switches = 0
        self.hexd = 0
        self.leds = 0
        self.buzzer = 0
        self.uart = bytearray()
        self.uart_echo = uart_echo
        self.trace = trace
        self.volatile = False
        self.taint = [False] * 32   # registers holding a value derived from a time / random / button read
        self.taint_mem = set()      # word addresses holding such a value
        self.volatile_pc = -1   # pc of the last load from a time / random / button register
        self.fast_wait = True   # skip to the next frame when the program spins polling FRAME
        self.keys = {}          # frame -> button mask held during that frame

    @property
    def frame(self):
        return self.cycles // FRAME_CYCLES

    # ---- memory
    def load(self, addr, size, signed):
        if addr + size <= RAM_SIZE:
            v = int.from_bytes(self.mem[addr:addr + size], "little")
            return sext(v, 8 * size) & 0xFFFFFFFF if signed else v
        if IO_BASE <= addr < IO_BASE + 0x100:
            return self.io_read(addr - IO_BASE)
        raise RuntimeError(f"load from unmapped address 0x{addr:08x} at pc 0x{self.pc:08x}")

    def store(self, addr, size, value, tainted=False):
        value &= (1 << (8 * size)) - 1
        if tainted:
            self.taint_mem.add(addr & ~3)
        else:
            self.taint_mem.discard(addr & ~3)
        if self.trace is not None:
            mask = ((1 << size) - 1) << (addr & 3)
            self.trace.write(f"{self.pc:08x} W {addr & ~3:08x} {(value << (8 * (addr & 3))) & 0xFFFFFFFF:08x} {mask:x}"
                             f"{' ~' if tainted else ''}\n")
        if addr + size <= RAM_SIZE:
            self.mem[addr:addr + size] = value.to_bytes(size, "little")
        elif TEXT_BASE <= addr < TEXT_BASE + TEXT_COLS * TEXT_ROWS * 4:
            cell = (addr - TEXT_BASE) >> 2
            self.text[cell // TEXT_COLS][cell % TEXT_COLS] = value & 0xFFFF
        elif IO_BASE <= addr < IO_BASE + 0x100:
            self.io_write(addr - IO_BASE, value)
        else:
            raise RuntimeError(f"store to unmapped address 0x{addr:08x} at pc 0x{self.pc:08x}")

    def io_read(self, off):
        if off == IO["BUTTONS"]:
            self.volatile = True
            self.volatile_pc = self.pc
            self.volatile_kind = "BUTTONS"
            return self.buttons | self.keys.get(self.frame, 0)
        if off == IO["FRAME"]:
            self.volatile = True
            self.volatile_pc = self.pc
            self.volatile_kind = "FRAME"
            return self.frame & 0xFFFFFFFF
        if off == IO["RANDOM"]:
            self.volatile = True
            x = self.lfsr
            x ^= (x << 13) & 0xFFFFFFFF
            x ^= x >> 17
            x ^= (x << 5) & 0xFFFFFFFF
            self.lfsr = x
            return x
        if off == IO["UART"]:
            return 0
        if off == IO["SWITCHES"]:
            return self.switches
        if off == IO["CYCLES"]:
            self.volatile = True
            return self.cycles & 0xFFFFFFFF
        return 0

    def io_write(self, off, value):
        if off == IO["HEX"]:
            self.hexd = value & 0xFFFFFF
        elif off == IO["LEDS"]:
            self.leds = value & 0x3FF
        elif off == IO["BUZZER"]:
            self.buzzer = value & 0xFFFF
        elif off == IO["UART"]:
            self.uart.append(value & 0xFF)
            if self.uart_echo:
                sys.stdout.write(chr(value & 0xFF))
                sys.stdout.flush()
        elif off == IO["EXIT"]:
            raise Exit(value)

    def maybe_skip_wait(self, pc, target):
        """A short backward jump over a loop that read FRAME is a wait for the next frame: skip the spinning.
        Off while tracing, so lock-step runs keep every instruction."""
        if self.fast_wait and self.trace is None and 0 < pc - target <= 48 and \
                target <= self.volatile_pc <= pc and self.volatile_kind == "FRAME":
            self.cycles += FRAME_CYCLES - self.cycles % FRAME_CYCLES - CYCLES_PER_INSTR

    # ---- one instruction
    def step(self):
        pc = self.pc
        if pc + 4 > RAM_SIZE or pc & 3:
            raise RuntimeError(f"fetch from 0x{pc:08x}")
        ins = int.from_bytes(self.mem[pc:pc + 4], "little")
        op = ins & 0x7F
        rd = (ins >> 7) & 0x1F
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 0x1F
        rs2 = (ins >> 20) & 0x1F
        f7 = ins >> 25
        r = self.regs
        a = r[rs1]
        b = r[rs2]
        next_pc = pc + 4
        result = None
        if op == 0x33:          # R
            if f3 == 0:
                result = (a - b) if f7 == 0x20 else (a + b)
            elif f3 == 1:
                result = a << (b & 31)
            elif f3 == 2:
                result = 1 if sext(a, 32) < sext(b, 32) else 0
            elif f3 == 3:
                result = 1 if a < b else 0
            elif f3 == 4:
                result = a ^ b
            elif f3 == 5:
                result = (sext(a, 32) >> (b & 31)) if f7 == 0x20 else (a >> (b & 31))
            elif f3 == 6:
                result = a | b
            else:
                result = a & b
        elif op == 0x13:        # I ALU
            imm = sext(ins >> 20, 12)
            if f3 == 0:
                result = a + imm
            elif f3 == 1:
                result = a << (imm & 31)
            elif f3 == 2:
                result = 1 if sext(a, 32) < imm else 0
            elif f3 == 3:
                result = 1 if a < (imm & 0xFFFFFFFF) else 0
            elif f3 == 4:
                result = a ^ imm
            elif f3 == 5:
                result = (sext(a, 32) >> (imm & 31)) if f7 == 0x20 else (a >> (imm & 31))
            elif f3 == 6:
                result = a | imm
            else:
                result = a & imm
        elif op == 0x03:        # loads
            addr = (a + sext(ins >> 20, 12)) & 0xFFFFFFFF
            size = 1 << (f3 & 3)
            if addr % size:
                raise RuntimeError(f"misaligned load 0x{addr:08x} at pc 0x{pc:08x}")
            result = self.load(addr, size, f3 < 4)
            if (addr & ~3) in self.taint_mem:
                self.volatile = True
        elif op == 0x23:        # stores
            imm = sext(((f7 << 5) | rd), 12)
            addr = (a + imm) & 0xFFFFFFFF
            size = 1 << f3
            if addr % size:
                raise RuntimeError(f"misaligned store 0x{addr:08x} at pc 0x{pc:08x}")
            self.store(addr, size, b, tainted=self.taint[rs2])
        elif op == 0x63:        # branches
            off = sext((((ins >> 31) & 1) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) |
                       (((ins >> 8) & 0xF) << 1), 13)
            sa, sb = sext(a, 32), sext(b, 32)
            take = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}.get(f3)
            if take is None:
                raise RuntimeError(f"bad branch funct3 at 0x{pc:08x}")
            if take:
                next_pc = (pc + off) & 0xFFFFFFFF
                self.maybe_skip_wait(pc, next_pc)
        elif op == 0x37:        # lui
            result = ins & 0xFFFFF000
        elif op == 0x17:        # auipc
            result = pc + (ins & 0xFFFFF000)
        elif op == 0x6F:        # jal
            off = sext((((ins >> 31) & 1) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) |
                       (((ins >> 21) & 0x3FF) << 1), 21)
            result = pc + 4
            next_pc = (pc + off) & 0xFFFFFFFF
            if rd == 0:
                self.maybe_skip_wait(pc, next_pc)
        elif op == 0x67:        # jalr
            result = pc + 4
            next_pc = (a + sext(ins >> 20, 12)) & 0xFFFFFFFE
        elif op == 0x73:        # ecall / ebreak: stop
            raise Exit(r[10])
        elif op == 0x0F:        # fence: nothing to do
            pass
        else:
            raise RuntimeError(f"illegal instruction {ins:08x} at 0x{pc:08x}")
        if result is not None and rd != 0:
            r[rd] = result & 0xFFFFFFFF
            # "~" marks a value that depends on time or randomness: the RTL's will differ by nature. The mark follows
            # the value: through registers (any tainted source taints the result) and through memory.
            uses = {0x33: (rs1, rs2), 0x13: (rs1,), 0x03: (rs1,), 0x67: (rs1,)}.get(op, ())
            tainted = self.volatile or any(self.taint[x] for x in uses)
            self.taint[rd] = tainted
            if self.trace is not None:
                self.trace.write(f"{pc:08x} {rd} {r[rd]:08x}{' ~' if tainted else ''}\n")
        self.volatile = False
        self.pc = next_pc
        self.cycles += CYCLES_PER_INSTR
        self.instrs += 1

    def run(self, max_instr=None, frames=None):
        try:
            while True:
                if max_instr is not None and self.instrs >= max_instr:
                    return None
                if frames is not None and self.frame >= frames:
                    return None
                self.step()
        except Exit as e:
            return e.code

    def screen_text(self):
        rows = []
        for row in self.text:
            rows.append("".join(GLYPH.get(c & 0xFF, chr(c & 0x7F) if 0x20 <= (c & 0x7F) < 0x7F else "?") for c in row))
        return "\n".join(rows) + "\n"


def parse_keys(spec):
    keys = {}
    if not spec:
        return keys
    for item in spec.split(","):
        frame, name = item.strip().split(":")
        hold = 1
        if "*" in name:
            name, hold = name.split("*")
            hold = int(hold)
        for f in range(int(frame), int(frame) + hold):
            keys[f] = keys.get(f, 0) | BUTTON_BITS[name.strip().lower()]
    return keys


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("hexfile")
    ap.add_argument("--frames", type=int)
    ap.add_argument("--max", type=int, default=50_000_000)
    ap.add_argument("--keys", default="")
    ap.add_argument("--screen")
    ap.add_argument("--trace")
    ap.add_argument("--uart", action="store_true", help="echo UART bytes to stdout")
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0xACE1_1234, help="the RANDOM register's start value")
    ap.add_argument("--no-fast-wait", action="store_true", help="simulate every instruction of a wait-for-frame loop")
    a = ap.parse_args(argv)
    words = [int(l, 16) for l in Path(a.hexfile).read_text().split()]
    image = b"".join(w.to_bytes(4, "little") for w in words)
    trace = open(a.trace, "w", newline="\n") if a.trace else None
    soc = SoC(image, trace=trace, uart_echo=a.uart)
    soc.keys = parse_keys(a.keys)
    soc.lfsr = a.seed & 0xFFFFFFFF or 1
    soc.fast_wait = not a.no_fast_wait
    try:
        code = soc.run(max_instr=a.max, frames=a.frames)
    except RuntimeError as e:
        print(f"FAIL: {e}")
        return 2
    finally:
        if trace:
            trace.close()
    if a.screen:
        Path(a.screen).write_text(soc.screen_text(), encoding="utf-8", newline="\n")
    status = f"exit {code}" if code is not None else f"stopped after {soc.instrs} instructions"
    print(f"{status}; {soc.instrs} instructions, {soc.cycles} cycles, {soc.frame} frames, HEX={soc.hexd:06x} "
          f"LEDS={soc.leds:03x}, UART {len(soc.uart)} bytes")
    if not a.uart and soc.uart:
        print("UART: " + soc.uart.decode("latin-1").replace("\n", "\n      "))
    return 0 if code in (None, 0) else 1


if __name__ == "__main__":
    sys.exit(main())
