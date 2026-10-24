"""RV32I assembler: GNU-style source -> a flat memory image for the 32 KB RAM.

    python tools/asm.py prog.s -o build/prog            # writes prog.hex (8192 words, for $readmemh and the
                                                        # simulator), prog.mif (Quartus / memory editor), prog.lst
Supports: the RV32I base instructions, the usual pseudo-instructions (li, la, mv, not, neg, seqz, snez, sltz,
sgtz, beqz, bnez, blez, bgez, bltz, bgtz, bgt, ble, bgtu, bleu, j, jal label, jr, jalr rs, ret, call, tail, nop),
%hi / %lo, labels (global and numeric-free), directives .text .data .bss .word .half .byte .space .zero .ascii
.asciz .string .align .balign .equ .set .globl .global .type .size .section .p2align .option (the last six ignored).
Immediates are expressions of numbers (decimal, hex, binary, 'c'), symbols, + - * and parentheses.
The image is one segment starting at 0: .data and .bss simply follow .text (we have one RAM).
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from memmap import RAM_SIZE  # noqa: E402

REGS = {f"x{i}": i for i in range(32)}
REGS.update({"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
             "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15, "a6": 16, "a7": 17,
             "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27,
             "t3": 28, "t4": 29, "t5": 30, "t6": 31})

R_TYPE = {"add": (0, 0), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0), "sltu": (3, 0), "xor": (4, 0),
          "srl": (5, 0), "sra": (5, 0x20), "or": (6, 0), "and": (7, 0)}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
I_SHIFT = {"slli": (1, 0), "srli": (5, 0), "srai": (5, 0x20)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class AsmError(Exception):
    pass


def reg(name):
    name = name.strip()
    if name not in REGS:
        raise AsmError(f"not a register: {name}")
    return REGS[name]


def lo(v):
    v &= 0xFFF
    return v - 0x1000 if v >= 0x800 else v


def hi(v):
    return ((v + 0x800) >> 12) & 0xFFFFF


class Assembler:
    def __init__(self):
        self.cur = 0
        self.local_count = {}       # numeric local labels: how many of each number so far
        self.symbols = {}
        self.items = []         # (kind, data, line_no) in order; kind: "word" (encoded instruction fn), "bytes"
        self.pc = 0
        self.errors = []

    # ---- expressions
    def expr(self, text, allow_undefined=False):
        """Evaluate an immediate expression; symbols must be defined (pass 2) unless allow_undefined."""
        text = text.strip()
        m = re.fullmatch(r"%(hi|lo)\((.*)\)", text)
        if m:
            v = self.expr(m.group(2), allow_undefined)
            return (hi(v) if m.group(1) == "hi" else lo(v)) if v is not None else None
        tokens = re.findall(r"'(?:\\.|[^'\\])'|0[xX][0-9a-fA-F]+|0[bB][01]+|\d+|[A-Za-z_.$][\w.$]*|[()+\-*/%<>&|^~]+", text)
        if "".join(tokens).replace(" ", "") != text.replace(" ", ""):
            raise AsmError(f"bad expression: {text}")
        py = []
        undefined = False
        for t in tokens:
            if t.startswith("'"):
                py.append(str(ord(bytes(t[1:-1], "utf-8").decode("unicode_escape"))))
            elif re.fullmatch(r"0[xX][0-9a-fA-F]+|0[bB][01]+|\d+", t):
                py.append(str(int(t, 0)))
            elif t == ".":
                py.append(str(self.cur))          # the address of the current instruction / data item
            elif re.fullmatch(r"[A-Za-z_.$][\w.$]*", t):
                if t in self.symbols:
                    py.append(str(self.symbols[t]))
                elif allow_undefined:
                    undefined = True
                    py.append("0")
                else:
                    raise AsmError(f"undefined symbol: {t}")
            else:
                if not re.fullmatch(r"[()+\-*/%<>&|^~]+", t):
                    raise AsmError(f"bad token: {t}")
                py.append(t)
        if undefined:
            return None
        try:
            return int(eval("".join(py), {"__builtins__": {}}, {}))
        except Exception as e:  # noqa: BLE001
            raise AsmError(f"bad expression: {text} ({e})") from None

    # ---- encoders
    @staticmethod
    def enc_r(f3, f7, rd, rs1, rs2):
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33

    @staticmethod
    def enc_i(op, f3, rd, rs1, imm):
        if not -2048 <= imm <= 2047:
            raise AsmError(f"immediate out of range: {imm}")
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def enc_s(f3, rs1, rs2, imm):
        if not -2048 <= imm <= 2047:
            raise AsmError(f"store offset out of range: {imm}")
        imm &= 0xFFF
        return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23

    @staticmethod
    def enc_b(f3, rs1, rs2, off):
        if off % 2 or not -4096 <= off <= 4095:
            raise AsmError(f"branch offset out of range: {off}")
        o = off & 0x1FFF
        return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
               (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63

    @staticmethod
    def enc_u(op, rd, imm20):
        return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

    @staticmethod
    def enc_j(rd, off):
        if off % 2 or not -(1 << 20) <= off < (1 << 20):
            raise AsmError(f"jump offset out of range: {off}")
        o = off & 0x1FFFFF
        return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) | \
               (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

    # ---- one instruction -> list of "deferred" encoders (closures evaluated in pass 2 with final symbols)
    def instruction(self, mnem, ops, pc):
        """Returns a list of functions f(pc_of_word) -> 32-bit word; most are one word."""
        def mem_operand(text):
            m = re.fullmatch(r"(.*)\((\w+)\)", text.strip())
            if m:
                return m.group(1).strip() or "0", reg(m.group(2))
            return text, None

        a = [o.strip() for o in ops]
        n = len(a)
        if mnem in R_TYPE and n == 3:
            f3, f7 = R_TYPE[mnem]
            return [lambda p: self.enc_r(f3, f7, reg(a[0]), reg(a[1]), reg(a[2]))]
        if mnem in I_ALU and n == 3:
            return [lambda p: self.enc_i(0x13, I_ALU[mnem], reg(a[0]), reg(a[1]), self.expr(a[2]))]
        if mnem in I_SHIFT and n == 3:
            f3, f7 = I_SHIFT[mnem]
            return [lambda p: self.enc_i(0x13, f3, reg(a[0]), reg(a[1]), (f7 << 5) | (self.expr(a[2]) & 0x1F))]
        if mnem in LOADS and n == 2:
            off, base = mem_operand(a[1])
            if base is None:
                # lw rd, symbol  ->  lui + lw %lo (two words)
                return [lambda p: self.enc_u(0x37, reg(a[0]), hi(self.expr(a[1]))),
                        lambda p: self.enc_i(0x03, LOADS[mnem], reg(a[0]), reg(a[0]), lo(self.expr(a[1])))]
            return [lambda p: self.enc_i(0x03, LOADS[mnem], reg(a[0]), base, self.expr(off))]
        if mnem in STORES and n in (2, 3):
            if n == 3:   # sw rs2, symbol, rt
                return [lambda p: self.enc_u(0x37, reg(a[2]), hi(self.expr(a[1]))),
                        lambda p: self.enc_s(STORES[mnem], reg(a[2]), reg(a[0]), lo(self.expr(a[1])))]
            off, base = mem_operand(a[1])
            if base is None:
                raise AsmError(f"{mnem} needs offset(reg) or a temp register")
            return [lambda p: self.enc_s(STORES[mnem], base, reg(a[0]), self.expr(off))]
        if mnem in BRANCHES and n == 3:
            return [lambda p: self.enc_b(BRANCHES[mnem], reg(a[0]), reg(a[1]), self.expr(a[2]) - p)]
        if mnem == "lui" and n == 2:
            return [lambda p: self.enc_u(0x37, reg(a[0]), self.expr(a[1]))]
        if mnem == "auipc" and n == 2:
            return [lambda p: self.enc_u(0x17, reg(a[0]), self.expr(a[1]))]
        if mnem == "jal":
            if n == 1:
                return [lambda p: self.enc_j(1, self.expr(a[0]) - p)]
            return [lambda p: self.enc_j(reg(a[0]), self.expr(a[1]) - p)]
        if mnem == "jalr":
            if n == 1:
                return [lambda p: self.enc_i(0x67, 0, 1, reg(a[0]), 0)]
            if n == 2:
                off, base = mem_operand(a[1])
                if base is None:
                    return [lambda p: self.enc_i(0x67, 0, reg(a[0]), reg(a[1]), 0)]
                return [lambda p: self.enc_i(0x67, 0, reg(a[0]), base, self.expr(off))]
            return [lambda p: self.enc_i(0x67, 0, reg(a[0]), reg(a[1]), self.expr(a[2]))]
        if mnem == "ecall":
            return [lambda p: 0x73]
        if mnem == "ebreak":
            return [lambda p: 0x100073]
        if mnem in ("fence", "fence.i"):
            return [lambda p: 0x0FF0000F if mnem == "fence" else 0x100F]
        # ---- pseudo-instructions
        if mnem == "nop":
            return [lambda p: self.enc_i(0x13, 0, 0, 0, 0)]
        if mnem == "li" and n == 2:
            def li_words(p):
                v = self.expr(a[1]) & 0xFFFFFFFF
                if v >= 0x80000000:
                    v -= 0x100000000
                if -2048 <= v <= 2047:
                    return [self.enc_i(0x13, 0, reg(a[0]), 0, v)]
                return [self.enc_u(0x37, reg(a[0]), hi(v)), self.enc_i(0x13, 0, reg(a[0]), reg(a[0]), lo(v))]
            return [("multi", li_words, 2)]
        if mnem == "la" and n == 2:
            return [lambda p: self.enc_u(0x37, reg(a[0]), hi(self.expr(a[1]))),
                    lambda p: self.enc_i(0x13, 0, reg(a[0]), reg(a[0]), lo(self.expr(a[1])))]
        if mnem == "mv" and n == 2:
            return [lambda p: self.enc_i(0x13, 0, reg(a[0]), reg(a[1]), 0)]
        if mnem == "not" and n == 2:
            return [lambda p: self.enc_i(0x13, 4, reg(a[0]), reg(a[1]), -1)]
        if mnem == "neg" and n == 2:
            return [lambda p: self.enc_r(0, 0x20, reg(a[0]), 0, reg(a[1]))]
        if mnem == "seqz" and n == 2:
            return [lambda p: self.enc_i(0x13, 3, reg(a[0]), reg(a[1]), 1)]
        if mnem == "snez" and n == 2:
            return [lambda p: self.enc_r(3, 0, reg(a[0]), 0, reg(a[1]))]
        if mnem == "sltz" and n == 2:
            return [lambda p: self.enc_r(2, 0, reg(a[0]), reg(a[1]), 0)]
        if mnem == "sgtz" and n == 2:
            return [lambda p: self.enc_r(2, 0, reg(a[0]), 0, reg(a[1]))]
        zero_br = {"beqz": ("beq", False), "bnez": ("bne", False), "blez": ("bge", True), "bgez": ("bge", False),
                   "bltz": ("blt", False), "bgtz": ("blt", True)}
        if mnem in zero_br and n == 2:
            base, swap = zero_br[mnem]
            r1, r2 = (0, reg(a[0])) if swap else (reg(a[0]), 0)
            return [lambda p: self.enc_b(BRANCHES[base], r1, r2, self.expr(a[1]) - p)]
        swap_br = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}
        if mnem in swap_br and n == 3:
            return [lambda p: self.enc_b(BRANCHES[swap_br[mnem]], reg(a[1]), reg(a[0]), self.expr(a[2]) - p)]
        if mnem == "j" and n == 1:
            return [lambda p: self.enc_j(0, self.expr(a[0]) - p)]
        if mnem == "jr" and n == 1:
            return [lambda p: self.enc_i(0x67, 0, 0, reg(a[0]), 0)]
        if mnem == "ret" and n == 0:
            return [lambda p: self.enc_i(0x67, 0, 0, 1, 0)]
        if mnem == "call" and n == 1:
            return [lambda p: self.enc_j(1, self.expr(a[0]) - p)]
        if mnem == "tail" and n == 1:
            return [lambda p: self.enc_j(0, self.expr(a[0]) - p)]
        raise AsmError(f"unknown instruction or wrong operands: {mnem} {', '.join(a)}")

    # ---- pass 1: layout
    def assemble(self, source, filename="<asm>"):
        self.image = bytearray()
        lines = source.splitlines()
        pending = []    # (closure or multi, line_no, address)
        for no, raw in enumerate(lines, 1):
            line = raw.split("#", 1)[0]
            line = re.sub(r"//.*", "", line).strip()
            if not line:
                continue
            try:
                # labels (numeric local labels "1:" with "1f" / "1b" references become unique .Ln_k symbols)
                while True:
                    m = re.match(r"([A-Za-z_.$][\w.$]*|\d+)\s*:\s*(.*)", line)
                    if not m:
                        break
                    name = m.group(1)
                    if name.isdigit():
                        k = self.local_count.get(name, 0)
                        self.local_count[name] = k + 1
                        name = f".L{name}_{k}"
                    if name in self.symbols:
                        raise AsmError(f"duplicate label {name}")
                    self.symbols[name] = len(self.image)
                    line = m.group(2).strip()
                if not line:
                    continue
                line = re.sub(r"\b(\d+)([fb])\b", lambda m: f".L{m.group(1)}_"
                              f"{self.local_count.get(m.group(1), 0) - (1 if m.group(2) == 'b' else 0)}", line)
                parts = line.split(None, 1)
                mnem = parts[0].lower()
                rest = parts[1] if len(parts) > 1 else ""
                if mnem.startswith("."):
                    self.directive(mnem, rest, no)
                    continue
                ops = self.split_operands(rest)
                words = self.instruction(mnem, ops, len(self.image))
                for w in words:
                    addr = len(self.image)
                    self.cur = addr
                    if isinstance(w, tuple):            # ("multi", fn, max_words): size decided in pass 2 -> reserve
                        # li: decide the size now if the value is known, else reserve 2 words
                        _, fn, maxw = w
                        try:
                            v = self.expr(ops[1], allow_undefined=True)
                        except AsmError:
                            v = None
                        size = maxw if v is None else len(fn(addr))
                        pending.append(("multi", fn, no, addr, size))
                        self.image += bytes(4 * size)
                    else:
                        pending.append(("one", w, no, addr, 1))
                        self.image += bytes(4)
            except AsmError as e:
                self.errors.append(f"{filename}:{no}: {e}")
        # pass 2: encode with all symbols known
        for kind, fn, no, addr, size in pending:
            self.cur = addr
            try:
                if kind == "one":
                    ws = [fn(addr)]
                else:
                    ws = fn(addr)
                    ws += [self.enc_i(0x13, 0, 0, 0, 0)] * (size - len(ws))   # pad a short li with nops
                for i, word in enumerate(ws):
                    self.image[addr + 4 * i: addr + 4 * i + 4] = (word & 0xFFFFFFFF).to_bytes(4, "little")
            except AsmError as e:
                self.errors.append(f"{filename}:{no}: {e}")
        if len(self.image) > RAM_SIZE:
            self.errors.append(f"image is {len(self.image)} bytes, the RAM has {RAM_SIZE}")
        return self.image

    @staticmethod
    def split_operands(text):
        if not text.strip():
            return []
        ops, depth, cur = [], 0, ""
        for ch in text:
            if ch == "," and depth == 0:
                ops.append(cur)
                cur = ""
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            cur += ch
        ops.append(cur)
        return ops

    def directive(self, d, rest, no):
        if d in (".text", ".data", ".bss", ".globl", ".global", ".type", ".size", ".section", ".option", ".file",
                 ".ident", ".attribute", ".cfi_startproc", ".cfi_endproc"):
            return
        if d in (".align", ".p2align"):
            n = 1 << self.expr(rest)
            while len(self.image) % n:
                self.image += b"\0"
            return
        if d == ".balign":
            n = self.expr(rest)
            while len(self.image) % n:
                self.image += b"\0"
            return
        if d in (".equ", ".set"):
            name, value = [s.strip() for s in rest.split(",", 1)]
            self.symbols[name] = self.expr(value)
            return
        if d in (".word", ".long", ".int"):
            for item in self.split_operands(rest):
                addr = len(self.image)
                self.image += bytes(4)
                self.fixup(addr, 4, item, no)
            return
        if d in (".half", ".short"):
            for item in self.split_operands(rest):
                addr = len(self.image)
                self.image += bytes(2)
                self.fixup(addr, 2, item, no)
            return
        if d == ".byte":
            for item in self.split_operands(rest):
                addr = len(self.image)
                self.image += bytes(1)
                self.fixup(addr, 1, item, no)
            return
        if d in (".space", ".zero", ".skip"):
            self.image += bytes(self.expr(rest.split(",")[0]))
            return
        if d in (".ascii", ".asciz", ".string"):
            m = re.fullmatch(r'\s*"((?:\\.|[^"\\])*)"\s*', rest)
            if not m:
                raise AsmError(f"{d} needs a quoted string")
            data = bytes(m.group(1), "utf-8").decode("unicode_escape").encode("latin-1")
            self.image += data + (b"\0" if d != ".ascii" else b"")
            return
        raise AsmError(f"unknown directive {d}")

    def fixup(self, addr, size, text, no):
        """Data items may use symbols defined later: resolve at the end of pass 1 via a deferred list."""
        if not hasattr(self, "data_fixups"):
            self.data_fixups = []
        self.data_fixups.append((addr, size, text, no))

    def finish_data(self, filename):
        for addr, size, text, no in getattr(self, "data_fixups", []):
            self.cur = addr
            try:
                v = self.expr(text) & ((1 << (8 * size)) - 1)
                self.image[addr: addr + size] = v.to_bytes(size, "little")
            except AsmError as e:
                self.errors.append(f"{filename}:{no}: {e}")


def assemble_file(path):
    asm = Assembler()
    src = Path(path).read_text(encoding="utf-8")
    asm.assemble(src, str(path))
    asm.finish_data(str(path))
    return asm


def write_outputs(asm, out_base):
    out_base = Path(out_base)
    out_base.parent.mkdir(parents=True, exist_ok=True)
    words = RAM_SIZE // 4
    image = asm.image + bytes(RAM_SIZE - len(asm.image))
    with open(out_base.with_suffix(".hex"), "w", newline="\n") as f:
        for i in range(words):
            f.write(f"{int.from_bytes(image[4*i:4*i+4], 'little'):08x}\n")
    with open(out_base.with_suffix(".mif"), "w", newline="\n") as f:
        f.write(f"WIDTH=32;\nDEPTH={words};\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\nCONTENT BEGIN\n")
        used = (len(asm.image) + 3) // 4
        for i in range(used):
            f.write(f"  {i:04X} : {int.from_bytes(image[4*i:4*i+4], 'little'):08X};\n")
        if used < words:
            f.write(f"  [{used:04X}..{words-1:04X}] : 00000000;\n")
        f.write("END;\n")
    with open(out_base.with_suffix(".sym"), "w", newline="\n") as f:
        for name, addr in sorted(asm.symbols.items(), key=lambda kv: kv[1]):
            f.write(f"{addr:08x} {name}\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source")
    ap.add_argument("-o", "--out", help="output base name (default: build/<source stem>)")
    a = ap.parse_args(argv)
    asm = assemble_file(a.source)
    if asm.errors:
        print("\n".join(asm.errors))
        return 1
    out = a.out or str(Path("build") / Path(a.source).stem)
    write_outputs(asm, out)
    print(f"OK: {len(asm.image)} bytes ({len(asm.image) * 100 // RAM_SIZE} % of the RAM) -> {out}.hex / .mif / .sym")
    return 0


if __name__ == "__main__":
    sys.exit(main())
