"""fft_lab model: the bit-exact Python twin of the design.

It computes what the hardware computes, with the same integer arithmetic: the generator's samples, our FFT
(fft_r2), the magnitude bars, the scope trace, the whole 320 x 240 screen and the report line. The RTL is checked
against it: the unit testbenches read the vectors it writes; the frames of the system testbench and the board's
screen captures are compared with the frames it renders, pixel by pixel.

  python projects/fft_lab/sim/lab_model.py make                    assets/sine.hex, hann.hex, twiddle.hex, mag_rom.bin (dB/linear)
  python projects/fft_lab/sim/lab_model.py expect                  sim/expect_wave.hex, expect_mag.hex, expect_fft.hex (unit tests)
  python projects/fft_lab/sim/lab_model.py render S0N80 out.png    the screen the board should show for a case
  python projects/fft_lab/sim/lab_model.py compare S0N80 shot.txt  compare a capture (board .txt dump or tb .ppm) with it
  python projects/fft_lab/sim/lab_model.py report S0N80            the report line ('R') the board should send

A case is the USB command that sets it: S<shape> N<step> W<window> L<linear>, e.g. S0N80W0L0. Missing letters keep
the defaults (S0 N80 W0 L0). Shapes: 0 sine, 1 square, 2 triangle, 3 saw, 4 spikes, 5 noise. The frequency is
N x 12.5 Hz (N = 0..1023); one FFT bin is 100 Hz.
The Altera IP panel is exact only for recorded cases (sim/ip_vectors.hex, recorded from the real IP in ModelSim);
for any other case it is left out of a comparison.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PROJ))
ASSETS = os.path.join(PROJ, "assets")
FONT_SV = os.path.join(ROOT, "lib", "rtl", "font8x8.sv")
IP_VECTORS = os.path.join(HERE, "ip_vectors.hex")

N = 256                 # FFT points
A = 24576               # amplitude of the shapes (3/4 of full scale)
SINE_LEN = 2048         # sine table: one cycle
SHAPES = ["SINE", "SQUARE", "TRIANGLE", "SAW", "SPIKES", "NOISE"]
NOISE = 5
SEED = 0x2545F491       # xorshift32 start value (power-up)
DIY_OFFSET = 16         # our FFT divides by 256: |X|^2 = out^2 * 2^16
DIY_CLOCKS = 6145       # first input to last output, inclusive: 256 in + 8 x 128 x 5 butterflies + 256 x 3 out + 1
IP_LATENCY = 1381       # the Altera IP: first input to first output (recorded); its time = IP_LATENCY + 256 clocks
DEFAULTS = dict(shape=0, fq=80, win=0, lin=0)

# colours (RGB444)
BLACK, WHITE, YELLOW, GREY, RED = 0x000, 0xFFF, 0xFF0, 0xAAA, 0xF00
GRID, AXIS, TRACE, BAR_D, BAR_I = 0x333, 0x555, 0x0F0, 0x0FF, 0xF80
W, H = 320, 240


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s8(v):
    v &= 0xFF
    return v - 0x100 if v & 0x80 else v


def rev8(n):
    return int(f"{n:08b}"[::-1], 2)


# ---------------------------------------------------------------- tables (the ROM contents)
def sine_table():
    return [round(A * math.sin(2 * math.pi * i / SINE_LEN)) for i in range(SINE_LEN)]


def hann_table():
    """Hann window in Q15, 0..32768 (unsigned; 32768 = 1.0 at the middle)."""
    return [round(32768 * 0.5 * (1 - math.cos(2 * math.pi * n / N))) for n in range(N)]


def twiddle_table():
    """cos and sin of 2 pi k / 256 in Q15 (k = 0..127), the contents of fft_r2's twiddle ROM."""
    out = []
    for k in range(N // 2):
        c = min(round(math.cos(2 * math.pi * k / N) * 32767), 32767)
        s = min(round(math.sin(2 * math.pi * k / N) * 32767), 32767)
        out.append((c, s))
    return out


def mag_rom():
    """4096 x 7: address {lin, e[5:0], m[4:0]} -> bar height 0..90 px.

    The power |X|^2 is 2^e x (1 + (m + 0.5) / 32); full scale (a full-scale sine) is 2^44.
    dB: 1 px per dB, 90 dB tall. Linear: amplitude, full scale = 90 px."""
    rom = []
    for lin in (0, 1):
        for e in range(64):
            for m in range(32):
                r = 2.0 ** (e - 44) * (1 + (m + 0.5) / 32)
                v = round(90 * math.sqrt(r)) if lin else round(10 * math.log10(r)) + 90
                rom.append(min(max(v, 0), 90))
    return rom


_TW, _ROM, _FONT = None, None, None


def tw():
    global _TW
    if _TW is None:
        _TW = twiddle_table()
    return _TW


def rom():
    global _ROM
    if _ROM is None:
        _ROM = mag_rom()
    return _ROM


def write_hex(path, values, digits):
    mask = (1 << (4 * digits)) - 1
    with open(path, "w", newline="\n") as f:
        f.write("".join(f"{v & mask:0{digits}X}\n" for v in values))


def write_bin(path, values, bits):
    """One value per line in binary ($readmemb): for words that are not whole hex digits (Quartus warning 10230)."""
    with open(path, "w", newline="\n") as f:
        f.write("".join(f"{v & ((1 << bits) - 1):0{bits}b}\n" for v in values))


def make():
    os.makedirs(ASSETS, exist_ok=True)
    write_hex(os.path.join(ASSETS, "sine.hex"), sine_table(), 4)
    write_hex(os.path.join(ASSETS, "hann.hex"), hann_table(), 4)
    write_hex(os.path.join(ASSETS, "twiddle.hex"), [((c & 0xFFFF) << 16) | (s & 0xFFFF) for c, s in twiddle_table()], 8)
    write_bin(os.path.join(ASSETS, "mag_rom.bin"), mag_rom(), 7)
    print("OK: assets/sine.hex (2048), hann.hex (256), twiddle.hex (128), mag_rom.bin (4096)")


# ---------------------------------------------------------------- the generator (wave_gen.sv)
def xorshift(x):
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= x >> 17
    x ^= (x << 5) & 0xFFFFFFFF
    return x


def shape_value(shape, ph, fq, sine, rnd):
    if shape == 0:
        return sine[ph]
    if shape == 1:
        return A if ph < 1024 else -A
    if shape == 2:
        return 48 * ph if ph < 512 else 48 * (1024 - ph) if ph < 1536 else 48 * (ph - 2048)
    if shape == 3:
        return 24 * (ph - 1024)
    if shape == 4:
        return A if ph < fq else 0
    if shape == 5:
        return (rnd * 3) >> 2
    return 0


class Gen:
    """One frame = 256 samples; the phase restarts at 0 every frame, the noise generator runs on."""

    def __init__(self):
        self.lfsr = SEED
        self.sine = sine_table()
        self.hann = hann_table()

    def frame(self, shape, fq, win):
        xw = []
        for n in range(N):
            ph = (n * fq) % SINE_LEN
            x = shape_value(shape, ph, fq, self.sine, s16(self.lfsr >> 16))
            self.lfsr = xorshift(self.lfsr)
            xw.append((x * self.hann[n] + 16384) >> 15 if win else x)
        return xw


# ---------------------------------------------------------------- our FFT (src/fft_r2.sv)
def half(v):
    return s16((v + 1) >> 1)


def fft_r2(xre, xim=None):
    """Radix-2 decimation in time, in place, 1/2 per stage (output = DFT / 256), natural order out."""
    t = tw()
    if xim is None:
        xim = [0] * N
    mem = [None] * N
    for n in range(N):
        mem[rev8(n)] = (xre[n], xim[n])
    for stage in range(8):
        span = 1 << stage
        for bf in range(N // 2):
            j = bf & (span - 1)
            top = ((bf >> stage) << (stage + 1)) | j
            bot = top | span
            c, s = t[j << (7 - stage)]
            ar, ai = mem[top]
            br, bi = mem[bot]
            tr = (c * br + s * bi + 16384) >> 15
            ti = (c * bi - s * br + 16384) >> 15
            mem[top] = (half(ar + tr), half(ai + ti))
            mem[bot] = (half(ar - tr), half(ai - ti))
    return mem


# ---------------------------------------------------------------- bars (mag_px.sv)
def mag_px(re, im, off, lin):
    pw = re * re + im * im
    if pw == 0:
        return 0
    p = pw.bit_length() - 1
    m = ((pw << 5) >> p) & 31
    e = min(max(p + off, 0), 63)
    return rom()[(lin << 11) | (e << 5) | m]


def bars(spectrum, off, lin):
    px = [mag_px(re, im, off, lin) for re, im in spectrum[:N // 2]]
    pk = max(range(N // 2), key=lambda k: (px[k], -k))       # the tallest bar, the lowest bin on a tie
    return px, pk


def scope(xw):
    """Scope memory: entry n = the vertical span from sample n to sample n + 1 (a connected trace)."""
    y = [min(max(64 - (v >> 9), 16), 112) for v in xw]
    e = [(min(y[n], y[n + 1]), max(y[n], y[n + 1])) for n in range(N - 1)]
    e.append((y[-1], y[-1]))
    return e


# ---------------------------------------------------------------- the real IP: recorded vectors
def load_ip_vectors(path=IP_VECTORS):
    """sim/ip_vectors.hex: per case 513 words: {CA, exp, latency}, 256 inputs {re, im}, 256 outputs {re, im}."""
    if not os.path.exists(path):
        return []
    words = []
    for line in open(path, encoding="ascii"):
        line = line.split("//")[0].strip()
        if line:
            words.append(int(line, 16))
    cases = []
    for i in range(0, len(words) - 512, 513):
        h = words[i]
        if h >> 24 != 0xCA:
            raise ValueError(f"{path}: word {i} is not a case header")
        cases.append(dict(exp=s8(h >> 16), lat=h & 0xFFFF,
                          inputs=[(s16(w >> 16), s16(w)) for w in words[i + 1:i + 257]],
                          outputs=[(s16(w >> 16), s16(w)) for w in words[i + 257:i + 513]]))
    return cases


def find_ip(xw, cases):
    want = [(v, 0) for v in xw]
    for c in cases:
        if c["inputs"] == want:
            return c
    return None


# ---------------------------------------------------------------- one frame, as the board computes it
def parse_case(case):
    c = dict(DEFAULTS)
    for letter, num in re.findall(r"([SNWL])(\d+)", case.upper()):
        v = int(num)
        if letter == "S" and v <= 5:
            c["shape"] = v
        elif letter == "N":
            c["fq"] = min(v, 1023)
        elif letter == "W":
            c["win"] = v & 1
        elif letter == "L":
            c["lin"] = v & 1
    return c


def case_name(c):
    return f"S{c['shape']}N{c['fq']}W{c['win']}L{c['lin']}"


def ip_failed(xw, kind):
    """The IP panel when the IP fails: 'dead' = it never answered (the engine's watchdog; its numbers are 0),
    'zero' = it answered all zeros (not ok when the input was not all zeros)."""
    if kind == "dead":
        return dict(clk=0, px=[0] * (N // 2), pk=0, exp=0, bad=True, zero=False, dead=True)
    if kind == "zero":
        zero = any(xw)
        return dict(clk=IP_LATENCY + N, px=[0] * (N // 2), pk=0, exp=0, bad=zero, zero=zero, dead=False)
    raise ValueError(f"unknown IP failure {kind!r}")


def frame_state(case, gen=None, ip_cases=None, hold=0, sound=0, ip_fault=None):
    """One frame. st["ip"] is None when there is no recording of the IP for this input; ip_fault = 'dead' or
    'zero' makes the IP fail instead (ip_failed)."""
    c = parse_case(case) if isinstance(case, str) else dict(case)
    xw = (gen or Gen()).frame(c["shape"], c["fq"], c["win"])
    dpx, dpk = bars(fft_r2(xw), DIY_OFFSET + 2 * c["win"], c["lin"])
    st = dict(c, hold=hold, sound=sound, xw=xw, scope=scope(xw), diy=dict(clk=DIY_CLOCKS, px=dpx, pk=dpk), ip=None)
    if ip_fault:
        st["ip"] = ip_failed(xw, ip_fault)
        return st
    ipc = find_ip(xw, load_ip_vectors() if ip_cases is None else ip_cases)
    if ipc:
        ipx, ipk = bars(ipc["outputs"], -2 * ipc["exp"] + 2 * c["win"], c["lin"])
        zero = any(xw) and not any(re or im for re, im in ipc["outputs"])
        st["ip"] = dict(clk=ipc["lat"] + N, px=ipx, pk=ipk, exp=ipc["exp"], bad=zero, zero=zero, dead=False)
    return st


# ---------------------------------------------------------------- the screen (lab_draw.sv)
def load_font():
    global _FONT
    if _FONT is None:
        _FONT = {}
        for code, body in re.findall(r"7'h([0-9A-Fa-f]{2})\s*:\s*g\s*=\s*\{([^}]*)\}", open(FONT_SV).read()):
            rows = [int(b, 16) for b in re.findall(r"8'h([0-9A-Fa-f]{2})", body)]
            _FONT[int(code, 16)] = rows[::-1]           # the last byte listed is row 0
    return _FONT


def digits(v, n, blank_to=1):
    """v as n decimal digits; leading zeros become spaces, keeping the last blank_to digits."""
    s = f"{v:0{n}d}"[-n:]
    lead = len(s) - len(s.lstrip("0"))
    lead = min(lead, n - blank_to)
    return " " * lead + s[lead:]


def text_cells(st):
    """(row, col) -> (char, colour) for every character cell that is not a space."""
    cells = {}

    def put(row, col, s, colour):
        for i, ch in enumerate(s):
            if ch != " ":
                cells[(row, col + i)] = (ch, colour)

    hz10 = st["fq"] * 125
    put(0, 0, SHAPES[st["shape"]] if st["shape"] < len(SHAPES) else "", WHITE)
    put(0, 9, digits(hz10 // 10, 5) + "." + str(hz10 % 10), YELLOW)
    put(0, 17, "HZ", GREY)
    put(0, 21, "BIN", GREY)
    put(0, 25, digits(st["fq"] >> 3, 3) + "." + f"{(st['fq'] & 7) * 125:03d}", YELLOW)
    if st["hold"]:
        put(0, 36, "HOLD", RED)
    put(1, 0, "WIN HANN" if st["win"] else "WIN RECT", GREY)
    put(1, 10, "LINEAR" if st["lin"] else "10DB/DIV", GREY)
    put(1, 20, "SOUND ON" if st["sound"] else "SOUND OFF", GREY)
    put(1, 30, "1.25MS/DIV", GREY)
    put(15, 2, "OUR RTL FFT", WHITE)
    put(15, 22, "ALTERA FFT IP", WHITE)
    ip = st["ip"] or dict(clk=0, bad=False)
    for pc, clk in ((0, st["diy"]["clk"]), (20, 0 if ip.get("dead") else ip["clk"])):
        us = clk * 4
        put(16, pc + 1, digits(clk, 5), YELLOW)
        put(16, pc + 7, "CLK", GREY)
        put(16, pc + 11, digits(us // 100, 4) + "." + f"{us % 100:02d}", YELLOW)
        put(16, pc + 18, "US", GREY)
        put(29, pc + 2, "0", GREY)
        put(29, pc + 8, "6.4K", GREY)
        put(29, pc + 13, "12.8K", GREY)
    if ip["bad"]:
        put(20, 21, "IP IS NOT RUNNING", RED)
        put(21, 21, "(EVALUATION TIME?)", RED)
    return cells


def render(st):
    """The 320 x 240 picture (RGB444 ints, rows of columns), pixel rules in lab_draw.sv order."""
    font = load_font()
    cells = text_cells(st)
    ip = st["ip"]
    panels = [(0, st["diy"]["px"], BAR_D)]
    if ip and not ip["bad"]:
        panels.append((160, ip["px"], BAR_I))
    grid_y = set(range(138, 228, 18) if st["lin"] else range(138, 228, 10))
    img = []
    for Y in range(H):
        row = []
        for X in range(W):
            c = BLACK
            # grid (lowest)
            if 16 <= Y <= 112 and Y % 2 == 0 and X in range(32, 289, 32):
                c = GRID
            if 32 <= X <= 288 and X % 2 == 0 and Y in (16, 40, 88, 112):
                c = GRID
            if 32 <= X <= 288 and X % 2 == 0 and Y == 64:
                c = AXIS
            for xp in (0, 160):
                if xp + 16 <= X <= xp + 143:
                    if X % 2 == 0 and Y in grid_y:
                        c = GRID
                    if Y == 228:
                        c = AXIS
                if X in (xp + 48, xp + 80, xp + 112) and 138 <= Y <= 227 and Y % 2 == 0:
                    c = GRID
            # bars
            if 138 <= Y <= 227:
                for xp, px, colour in panels:
                    if xp + 16 <= X <= xp + 143 and Y >= 228 - px[X - xp - 16]:
                        c = colour
            # scope trace (the Y range keeps an empty scope memory, all zeros at power-up, off the screen)
            if 32 <= X <= 287 and 16 <= Y <= 112:
                lo, hi = st["scope"][X - 32]
                if lo <= Y <= hi:
                    c = TRACE
            # text (highest)
            cell = cells.get((Y >> 3, X >> 3))
            if cell and (font.get(ord(cell[0]), [0] * 8)[Y & 7] >> (X & 7)) & 1:
                c = cell[1]
            row.append(c)
        img.append(row)
    return img


def report_line(st):
    hz10 = st["fq"] * 125
    d = st["diy"]
    ip = st["ip"] or dict(clk=0, pk=0, px=[0] * 128, exp=0, bad=True, dead=True)
    exp = ip["exp"]
    return (f"FFTLAB SHAPE={st['shape']} N={st['fq']:04d} HZ={hz10 // 10:05d}.{hz10 % 10} WIN={st['win']} "
            f"LIN={st['lin']} HOLD={st['hold']} OUR_CLK={d['clk']:05d} OUR_PK={d['pk']:03d}/{d['px'][d['pk']]:03d} "
            f"IP_CLK={0 if ip.get('dead') else ip['clk']:05d} IP_PK={ip['pk']:03d}/{ip['px'][ip['pk']]:03d} "
            f"IP_EXP={'-' if exp < 0 else '+'}{abs(exp):02d} IP_OK={0 if ip['bad'] else 1}")


# ---------------------------------------------------------------- pictures in and out
def read_ppm(path):
    tok = open(path).read().split()
    if tok[0] != "P3":
        raise ValueError(f"{path}: not a P3 PPM")
    w, h = int(tok[1]), int(tok[2])
    v = list(map(int, tok[4:4 + 3 * w * h]))
    return [[(v[3 * (y * w + x)] << 8) | (v[3 * (y * w + x) + 1] << 4) | v[3 * (y * w + x) + 2] for x in range(w)]
            for y in range(h)]


def read_dump(path):
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import frame_to_png
    w, h, pix = frame_to_png.parse(open(path, encoding="ascii", errors="replace").read())
    return [[((r // 17) << 8) | ((g // 17) << 4) | (b // 17) for r, g, b in row] for row in pix]


def read_picture(path):
    return read_ppm(path) if path.lower().endswith(".ppm") else read_dump(path)


def write_png(path, img, scale=2):
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import frame_to_png
    pix = [[(((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17) for c in row] for row in img]
    frame_to_png.write_png(path, len(img[0]), len(img), pix, scale)


def in_ip_panel(x, y):
    return x >= 160 and 120 <= y


def compare(st, got, diff_png=None, skip_ip=False):
    """Number of pixels that differ; skip_ip leaves the Altera panel out (no recorded IP vectors for the case)."""
    want = render(st)
    bad = [(x, y) for y in range(H) for x in range(W)
           if got[y][x] != want[y][x] and not (skip_ip and in_ip_panel(x, y))]
    if diff_png:
        marks = set(bad)
        img = [[(0xF0F if (x, y) in marks else (want[y][x] >> 1) & 0x777) for x in range(W)] for y in range(H)]
        write_png(diff_png, img)
    return bad


# ---------------------------------------------------------------- unit-test vectors
WAVE_CASES = [(0, 80, 0), (0, 84, 1), (1, 80, 0), (2, 80, 0), (3, 80, 0), (4, 80, 0), (5, 80, 0), (5, 80, 1),
              (0, 1023, 0), (2, 333, 1), (4, 0, 0), (3, 517, 1), (1, 7, 1), (0, 1, 0)]


def expect():
    g = Gen()
    words = []
    for shape, fq, win in WAVE_CASES:
        words.append(0xC5000000 | (win << 16) | (shape << 12) | fq)
        words += [v & 0xFFFF for v in g.frame(shape, fq, win)]
    write_hex(os.path.join(HERE, "expect_wave.hex"), words, 8)
    # mag_px: {re, im, off[7:0], lin, px[6:0]}
    import random
    rnd = random.Random(1)
    vec = [(0, 0), (1, 0), (0, -1), (-32768, -32768), (32767, 32767), (-32768, 0), (16384, 0), (24576, 0)]
    for _ in range(3000):
        sh = rnd.randrange(16)
        vec.append((rnd.randrange(-32768, 32768) >> sh, rnd.randrange(-32768, 32768) >> sh))
    words = []
    for i, (re_, im_) in enumerate(vec):
        off = [16, 18, 0, 2, 14, 30, -6, 64, -62, 40][i % 10]
        lin = (i // 10) & 1
        words.append(((re_ & 0xFFFF) << 32) | ((im_ & 0xFFFF) << 16) | ((off & 0xFF) << 8) | (lin << 7)
                     | mag_px(re_, im_, off, lin))
    write_hex(os.path.join(HERE, "expect_mag.hex"), words, 12)
    # fft_r2: per frame a header 0xFF7 << 20 | clocks << 4 | paced, the 256 inputs {re, im}, the model's 256 outputs
    frames = fft_frames()
    words = []
    for paced, xre, xim in frames:
        words.append(0xFF700000 | ((0 if paced else DIY_CLOCKS) << 4) | paced)
        words += [((a & 0xFFFF) << 16) | (b & 0xFFFF) for a, b in zip(xre, xim)]
        words += [((a & 0xFFFF) << 16) | (b & 0xFFFF) for a, b in fft_r2(xre, xim)]
    write_hex(os.path.join(HERE, "expect_fft.hex"), words, 8)
    print(f"OK: sim/expect_wave.hex ({len(WAVE_CASES)} frames), sim/expect_mag.hex ({len(vec)} vectors), "
          f"sim/expect_fft.hex ({len(frames)} frames)")


def fft_frames():
    """fft_r2's unit-test inputs: (paced, re[256], im[256]). Paced frames come with random gaps, so they are not
    timed. Complex inputs keep |re| and |im| <= 23170 (a magnitude of at most 32767), the range the halving per
    stage is made for; complex full scale (|x| up to 46341) could overflow a butterfly's 16-bit result."""
    import random
    rnd = random.Random(2)
    g = Gen()
    zero = [0] * N
    real = [rnd.randrange(-32768, 32768) for _ in range(N)]
    cplx = [(rnd.randrange(-23170, 23171), rnd.randrange(-23170, 23171)) for _ in range(N)]
    tiny = [(rnd.randrange(-64, 64), rnd.randrange(-64, 64)) for _ in range(N)]
    return [
        (0, g.frame(0, 80, 0), zero),                                   # the lab's default: a 1 kHz sine
        (1, g.frame(1, 80, 0), zero),                                   # square
        (0, [32767] + [0] * (N - 1), zero),                             # impulse: a flat spectrum
        (0, [-32768] * N, zero),                                        # the most negative DC: the largest sums
        (1, real, zero),                                                # random, full scale
        (0, [c[0] for c in cplx], [c[1] for c in cplx]),                # random complex
        (0, [c[0] for c in tiny], [c[1] for c in tiny]),                # tiny values: the rounding
        (0, [32767 if n % 2 else -32768 for n in range(N)], zero),      # Nyquist
        (1, g.frame(5, 80, 1), zero),                                   # noise through the Hann window
    ]


def main(argv):
    if not argv:
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "make":
        make()
    elif cmd == "expect":
        expect()
    elif cmd in ("render", "report", "compare"):
        st = frame_state(argv[1])
        if cmd == "render":
            write_png(argv[2], render(st))
            print(f"wrote {argv[2]}" + ("" if st["ip"] else " (no recorded IP vectors: the IP panel is empty)"))
        elif cmd == "report":
            print(report_line(st))
        else:
            got = read_picture(argv[2])
            diff = argv[3] if len(argv) > 3 else None
            bad = compare(st, got, diff, skip_ip=st["ip"] is None)
            where = "" if not bad else (f", x {min(b[0] for b in bad)}..{max(b[0] for b in bad)},"
                                        f" y {min(b[1] for b in bad)}..{max(b[1] for b in bad)}")
            print(f"{'OK' if not bad else 'FAIL'}: {case_name(st)}: {len(bad)} of {W * H} pixels differ{where}"
                  + ("" if st["ip"] else " (IP panel not compared)"))
            return 1 if bad else 0
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
