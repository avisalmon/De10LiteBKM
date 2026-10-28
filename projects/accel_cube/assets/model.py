"""Bit-exact model of the accelerometer 3D cube (projects/accel_cube).

Everything the FPGA computes is written here first, with the same integer arithmetic:
  * per frame  (cube_math.sv): two vectors in -> angles -> rotation matrix -> projected cube -> face
    and line parameters, the numbers shown as text, the arrow of the vector widget;
  * per pixel  (cube_draw.sv): background, faces, edge lines, the text panel, the bars, the vector
    widget.
The testbench (sim/tb_accel_cube.sv) and the board captures (de10.py screen) are compared against
the pictures and frame hashes this file produces. If the RTL and this file disagree, one of them
is wrong; the float reference in `selftest` says which.

Two vectors go into a frame (cube_core.sv makes them from the sensor, both minus the calibration
offsets taken when KEY1 / 'c' was pressed with the board flat):
  gq  the steady one: the filtered acceleration (1/8 of the way per sample). It is the direction of
      gravity, so it turns the cube and gives pitch and roll.
  aq  the live one: the latest raw sample. It is what the board feels right now, shakes included:
      the arrow of the vector widget, the X / Y / Z bars and numbers, |a| and the peak.
In a test preset both are the preset.

Fixed-point formats (the same names are used in the RTL):
  aq, gq acceleration in Q4 counts: 1 g = 4096 (ADXL345 raw count 1 g = 256, shifted left by 4)
  Q14    trig values: 16384 = 1.0
  BAM16  angles: 65536 = 360 degrees, signed 16 bit (-180 .. +180 degrees)
  Q4 px  screen coordinates in 1/16 pixel

Usage (from the repo root, with env's Python):
  python projects/accel_cube/assets/model.py selftest
  python projects/accel_cube/assets/model.py render <case> out.png [--full]
  python projects/accel_cube/assets/model.py hashes                            frame hashes of the preset sequence
  python projects/accel_cube/assets/model.py compare <case> <capture.txt|.ppm> [diff.png]
  python projects/accel_cube/assets/model.py constants                         derived constants as Verilog localparams
  python projects/accel_cube/assets/model.py dump                              the engine's frame numbers (sim/tb_cube_math.sv)
  python projects/accel_cube/assets/model.py dumpcmp sim/math_dump.txt         ... compared with the RTL's dump
  python projects/accel_cube/assets/model.py report <case>                     the 114-character USB report line ('r')
Cases:
  N                 preset N (0..7) on its own: the peak restarted, the orientation not held from before
  seq:N             preset N as the testbench and the board show it: after presets 0..N-1, with the roll held
                    from the frame before when gravity is along x (preset 4) and the orientation held when it
                    is weak (preset 7)
  ax,ay,az          a live vector in mg, the board still (gq = aq), not calibrated:  row 13 "LIVE"
  q:ax,ay,az        the same in Q4 counts (1 g = 4096)
  cal:ax,ay,az      the same in Q4 counts, calibrated: row 13 "LIVE CAL"
  ema:V;B;K[;cal]   raw samples (1 g = 256): the filter settled on V, then K samples of B. gq is the filter's
                    value, aq = 16 B; with ";cal" both minus the offsets of a calibration done at V
Any case may end with "@psi": the view yaw in BAM16 (default VIEW_YAW; 's' spins it by SPIN_STEP a frame).
"""
import math
import os
import random
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
FONT_SV = os.path.join(ROOT, "lib", "rtl", "font8x8.sv")

# ---------------------------------------------------------------- screen layout
W, H = 640, 480
PANEL_X = 384                      # cube area 0..383, panel 384..639 (16 characters of 16 px)
CX, CY = 192, 240                  # cube centre (px)
S_PX = 96                          # half edge of the cube (px) at the centre distance
D_PX = 600                         # camera distance = focal length (px)
CX_Q4, CY_Q4, S_Q4, D_Q4 = CX * 16, CY * 16, S_PX * 16, D_PX * 16
WX, WY = 512, 352                  # vector widget origin (px)
WX_Q4, WY_Q4 = WX * 16, WY * 16
WREG = (386, 639, 224, 479)        # widget region: xmin, xmax, ymin, ymax (inclusive)
AXIS_PX = 80                       # widget axis length (px)
G_PX = 64                          # widget arrow: 1 g = 64 px
HEAD_Q4 = 160                      # arrowhead barb length (Q4 px) = 10 px
BAR_X = 512                        # bar centre; 1 g = 56 px
TEXT_ROWS = 14                     # text rows 0..13 (16 px each); the widget is below

PANEL_BG = 0x112
SEP_COLOR = 0x445
EDGE_DIV = 2                       # edge line colour = face colour >> EDGE_DIV
BAR_COLOR = (0xC44, 0x4C4, 0x44C)
TICK_COLOR = 0x999
CENTER_COLOR = 0xAAA
AXIS_COLOR = (0xF44, 0x4F4, 0x66F)
ARROW_COLOR = 0xFFC
SHADOW_COLOR = 0x999
ROW_COLOR = {0: 0xFE8, 2: 0xF99, 4: 0x9F9, 6: 0x99F, 8: 0xEEE, 9: 0xEEE, 10: 0xCCF, 11: 0xCCF}
LIVE_COLOR, TEST_COLOR = 0x9F9, 0xFC8
MODE_ROW = {"live": "LIVE            ", "cal": "LIVE CAL        ", "test": "TEST {}          "}
REPORT_LEN = 114                   # the USB report line ('r'); line_printer's len is 7 bits, so at most 127

# ---------------------------------------------------------------- math constants
HOLD_MAG = 1024                    # below 0.25 g the orientation is held
HOLD_R = 256                       # below 1/16 g in the y-z plane the roll is held
VIS_NZ = 2622                      # face visible iff n_z >= VIS_NZ  (n_z * D > S  <=>  n_z > 0.16 * 16384)
LIGHT = (-6554, 8192, 12583)       # light direction, Q14, unit length (0.4, 0.5, 0.768)
SHADE_MIN, SHADE_RANGE = 80, 176   # brightness b = SHADE_MIN + SHADE_RANGE * max(0, n.L)   (Q8)
SE, CE = 8192, 14189               # camera elevation 30 degrees: sin, cos in Q14
C30, S30 = 14189, 8192             # arrowhead half angle 30 degrees
VIEW_YAW = 5461                    # 30 degrees in BAM16
SPIN_STEP = 91                     # yaw added per frame while spinning (0.5 degree/frame)
ZF = 4                             # CORDIC angle accumulator has ZF fraction bits below BAM16 (wraps at 20 bits)
ATAN_Z = [round(math.atan(2.0 ** -i) / (2 * math.pi) * (65536 << ZF)) for i in range(16)]
_K = 1.0
for _i in range(16):
    _K *= math.sqrt(1 + 2.0 ** (-2 * _i))
GUARD = 2                          # CORDIC works in Q(14+GUARD) so 16 truncating iterations stay exact in Q14
CORDIC_X0 = round((16384 << GUARD) / _K)    # rotation mode start so that the gain lands on 1.0

# Faces listed counter-clockwise seen from outside. Vertex k has x>0 if k&1, y>0 if k&2, z>0 if k&4.
# (axis, sign, vertices, colour r g b 0..15)
FACES = [
    (0, +1, (1, 3, 7, 5), (15, 2, 2)),     # +X red
    (0, -1, (0, 4, 6, 2), (2, 13, 13)),    # -X cyan
    (1, +1, (2, 6, 7, 3), (2, 15, 2)),     # +Y green
    (1, -1, (0, 1, 5, 4), (15, 2, 15)),    # -Y magenta
    (2, +1, (4, 5, 7, 6), (3, 3, 15)),     # +Z blue
    (2, -1, (0, 2, 3, 1), (15, 15, 2)),    # -Z yellow
]

# Test presets, aq (1 g = 4096). Letters '0'..'7' on the USB link select them (filter bypassed, yaw fixed).
PRESETS = [
    (0, 0, 4096),          # 0 flat on the table, 1 g on z
    (-2048, 0, 3547),      # 1 pitched 30 degrees
    (0, 2048, 3547),       # 2 rolled 30 degrees
    (0, 0, -4096),         # 3 upside down
    (4096, 0, 0),          # 4 standing on its x side (pitch -90, roll held)
    (2365, 2365, 2365),    # 5 a corner up (1 g)
    (4800, -3200, 6400),   # 6 shaken: 2.1 g
    (0, 200, 300),         # 7 below 0.25 g: orientation held
]

# Extra cases for the engine's unit test (sim/tb_cube_math.sv, after the presets, the peak NOT cleared):
# (vector, view yaw in BAM16), gq = aq = the vector. They reach what the presets cannot: a yaw other than
# VIEW_YAW, both sides of the CORDIC's +-90 degree pre-rotation, +-180 degrees, and a peak kept from an
# earlier frame.
YAW_CASES = [
    ((2048, 1024, 3200), 0),           # 8 tilted both ways, no yaw
    ((2048, 1024, 3200), 16384),       # 9 exactly +90 degrees: the CORDIC's plain range ends here
    ((2048, 1024, 3200), 16385),       # 10 just past +90: the pre-rotated branch
    ((-1500, 2500, -2000), -16384),    # 11 upside down, exactly -90
    ((-1500, 2500, -2000), -16385),    # 12 just past -90
    ((4800, -3200, 6400), 32767),      # 13 2.1 g: a new peak, +180 degrees
    ((0, 0, 4096), -32768),            # 14 flat, -180 degrees (the sign wraps)
    ((300, -200, 900), 23661),         # 15 below 0.25 g: orientation held, the peak kept from case 13
]

# Cases with two different vectors (gq, aq, view yaw): the cube from gq, the arrow and the numbers from aq.
GA_CASES = [
    ((-400, 600, 4296), (-3200, 4800, 5696), VIEW_YAW),     # 16 a small tilt, a 2 g shake: the peak moves
    ((0, 200, 300), (4800, -3200, 14400), VIEW_YAW),        # 17 |g| < 0.25 g holds the cube; |a| 3.8 g shown
]


# ---------------------------------------------------------------- integer units (mirrored by the RTL)
def sat16(v):
    """Saturate to a signed 16-bit value (cube_core sat16: Q4 counts never beyond +-8 g)."""
    return max(-32768, min(32767, v))


def ema_live(v, b, k, cal=False):
    """The two live vectors of cube_core.sv after the filter settled on raw sample v (1 g = 256) and then saw
    k samples of b: gq = the filter's value (fx += (256 b - fx) >> 3, then rounded to Q4: (fx + 8) >> 4),
    aq = 16 b. With cal, both minus the offsets of a calibration done while settled on v:
    (16 vx, 16 vy, 16 vz - 4096), which makes gq exactly (0, 0, 4096) at that moment."""
    f = [256 * c for c in v]
    for _ in range(k):
        f = [fc + ((256 * bc - fc) >> 3) for fc, bc in zip(f, b)]
    g = [(fc + 8) >> 4 for fc in f]
    a = [16 * bc for bc in b]
    o = (16 * v[0], 16 * v[1], 16 * v[2] - 4096) if cal else (0, 0, 0)
    return tuple(sat16(gc - oc) for gc, oc in zip(g, o)), tuple(sat16(ac - oc) for ac, oc in zip(a, o))


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def sz(v):
    """The CORDIC angle accumulator: signed, 16 + ZF bits, wrapping."""
    bits = 16 + ZF
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def sdiv(num, den):
    """Signed numerator / positive denominator, truncated toward zero: the RTL divides magnitudes."""
    assert den > 0, "division by zero"
    q = abs(num) // den
    assert q < (1 << 16), f"quotient {q} does not fit the 16-bit divider"
    return -q if num < 0 else q


def isqrt(v):
    assert 0 <= v < (1 << 32)
    return math.isqrt(v)


def cordic(x, y, z, vectoring):
    """The shared CORDIC datapath: 16 iterations, x/y in Q(14+GUARD), z in BAM16 with ZF fraction bits.
    Vectoring drives y to 0 (z accumulates the angle); rotation drives z to 0 (x, y get rotated)."""
    for i in range(16):
        if (y >= 0) if vectoring else (z < 0):      # rotate clockwise
            x, y, z = x + (y >> i), y - (x >> i), sz(z + ATAN_Z[i])
        else:
            x, y, z = x - (y >> i), y + (x >> i), sz(z - ATAN_Z[i])
        assert -(1 << 18) <= x < (1 << 18) and -(1 << 18) <= y < (1 << 18), "CORDIC datapath overflow"
    return x, y, z


def cordic_vec(x, y):
    """atan2(y, x) in BAM16 for x, y up to +-16384, pre-rotated by 180 degrees when x < 0."""
    x, y, z = x << GUARD, y << GUARD, 0
    if x < 0:
        x, y, z = -x, -y, -32768 << ZF
    z = cordic(x, y, z, True)[2]
    return s16((z + (1 << (ZF - 1))) >> ZF)


def cordic_rot(a):
    """(cos a, sin a) in Q14 for a in BAM16, pre-rotated by 180 degrees when |a| > 90 degrees."""
    x, z = CORDIC_X0, a
    if a > 16384 or a < -16384:
        x, z = -CORDIC_X0, s16(a + 32768)
    x, y, _ = cordic(x, 0, z << ZF, False)
    half = 1 << (GUARD - 1)
    return (x + half) >> GUARD, (y + half) >> GUARD


def bam_deg10(b):
    """|angle| in 0.1 degree units (0..1800) and its sign."""
    return (abs(b) * 3600 + 32768) >> 16, b < 0


def mg_of(v):
    """|aq| in mg (1 g = 1000) and its sign."""
    return (abs(v) * 125 + 256) >> 9, v < 0


def deg2bam(d):
    return s16(round(d / 360 * 65536))


def remap(ax, ay, heading):
    """HEADING parameter: which way the board's +x points on the screen (0/90/180/270 about z)."""
    return {0: (ax, ay), 90: (-ay, ax), 180: (-ax, -ay), 270: (ay, -ax)}[heading]


# ---------------------------------------------------------------- the vector widget's fixed view
def widget_view():
    """Pw = camera(30 deg elevation) x Rz(VIEW_YAW) with the board flat: the widget's constant matrix (Q14)."""
    cps, sps = cordic_rot(VIEW_YAW)
    row0 = (cps, -sps, 0)
    row1 = ((SE * sps) >> 14, (SE * cps) >> 14, CE)
    return row0, row1


PW = widget_view()
AXIS_END = [(WX_Q4 + ((PW[0][j] * AXIS_PX * 16) >> 14), WY_Q4 - ((PW[1][j] * AXIS_PX * 16) >> 14))
            for j in range(3)]                                  # Q4 px


def label_box(j):
    """Top-left pixel of the 8x8 axis letter, just beyond the axis end."""
    ex, ey = AXIS_END[j][0] >> 4, AXIS_END[j][1] >> 4
    dx, dy = ex - WX, ey - WY
    lx = ex + (4 if dx >= 0 else -12)
    ly = ey + (2 if dy >= 0 else -10)
    return lx, ly


LABEL_BOX = [label_box(j) for j in range(3)]


# ---------------------------------------------------------------- per frame (cube_math.sv)
def new_state():
    return dict(sth=0, cth=16384, sph=0, cph=16384, peak2=0, spin=0)


def seg_unit(p0, p1, t8, color, dashed=False, valid=True):
    """A line segment as the pixel pipeline sees it: edge function + strip half-width + bounding box."""
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    c = (8 - x0) * dy - (8 - y0) * dx
    mx, mn = max(abs(dx), abs(dy)), min(abs(dx), abs(dy))
    t = (t8 * (16 * mx + 6 * mn)) >> 3               # t8 = half width in 1/8 px; |d| ~ mx + 3/8 mn
    pad = 2
    # clamped on both sides, as the RTL's 10-bit unsigned box must be: a segment wholly outside the widget
    # gives an empty box (min > max) that still reads as pixel coordinates
    xmin = min(max((min(x0, x1) >> 4) - pad, WREG[0]), WREG[1] + 1)
    xmax = max(min((max(x0, x1) >> 4) + pad, WREG[1]), WREG[0] - 1)
    ymin = min(max((min(y0, y1) >> 4) - pad, WREG[2]), WREG[3] + 1)
    ymax = max(min((max(y0, y1) >> 4) + pad, WREG[3]), WREG[2] - 1)
    return dict(valid=valid, dashed=dashed, dx=dx, dy=dy, c=c, t=t, box=(xmin, xmax, ymin, ymax), color=color)


def frame_math(gq, aq, psi, st, devid=0xE5, mode="test", test_n=0):
    """One frame. gq = the steady vector (the cube, pitch and roll), aq = the live vector (the arrow, the bars,
    x y z |a| and the peak), both in Q4 counts after the calibration / preset mux; psi = view yaw (BAM16).
    st carries the held orientation and the peak between frames. Returns the frame parameters."""
    gx, gy, gz = gq
    ax, ay, az = aq
    for v in gq + aq:
        assert -32768 <= v <= 32767
    g2, r2 = gx * gx + gy * gy + gz * gz, gy * gy + gz * gz
    a2 = ax * ax + ay * ay + az * az
    gmag, r, mag = isqrt(g2), isqrt(r2), isqrt(a2)
    if gmag >= HOLD_MAG:
        st["sth"] = -sdiv(gx << 14, gmag)
        st["cth"] = sdiv(r << 14, gmag)
        if r >= HOLD_R:
            st["sph"] = sdiv(gy << 14, r)
            st["cph"] = sdiv(gz << 14, r)
    sth, cth, sph, cph = st["sth"], st["cth"], st["sph"], st["cph"]
    pitch = cordic_vec(cth, sth)
    roll = cordic_vec(cph, sph)
    cps, sps = cordic_rot(psi)

    # M = Rz(psi) * Ry(theta) * Rx(phi), board -> world; then the camera elevation. All Q14.
    a01, a02, a21, a22 = (sth * sph) >> 14, (sth * cph) >> 14, (cth * sph) >> 14, (cth * cph) >> 14
    m0 = ((cps * cth) >> 14, (cps * a01 - sps * cph) >> 14, (cps * a02 + sps * sph) >> 14)
    m1 = ((sps * cth) >> 14, (sps * a01 + cps * cph) >> 14, (sps * a02 - cps * sph) >> 14)
    m2 = (-sth, a21, a22)
    p = (m0,
         tuple((SE * m1[j] + CE * m2[j]) >> 14 for j in range(3)),
         tuple((-CE * m1[j] + SE * m2[j]) >> 14 for j in range(3)))

    # The 8 corners: camera coordinates by adding signed columns, then perspective.
    col = [[(p[i][j] * S_Q4) >> 14 for j in range(3)] for i in range(3)]
    verts = []
    for k in range(8):
        sg = (1 if k & 1 else -1, 1 if k & 2 else -1, 1 if k & 4 else -1)
        cam = [sum(sg[j] * col[i][j] for j in range(3)) for i in range(3)]
        den = D_Q4 - cam[2]
        verts.append((CX_Q4 + sdiv(D_Q4 * cam[0], den), CY_Q4 - sdiv(D_Q4 * cam[1], den)))

    slots = []
    for axis, sign, idx, color in FACES:
        n = tuple(sign * p[i][axis] for i in range(3))
        if n[2] < VIS_NZ:
            continue
        nl = (n[0] * LIGHT[0] + n[1] * LIGHT[1] + n[2] * LIGHT[2]) >> 14
        b = SHADE_MIN + ((SHADE_RANGE * max(nl, 0)) >> 14)
        shade = tuple((cc * b) >> 8 for cc in color)
        edges = []
        for e in range(4):
            (xi, yi), (xj, yj) = verts[idx[e]], verts[idx[(e + 1) % 4]]
            dx, dy = xj - xi, yj - yi
            c = (8 - xi) * dy - (8 - yi) * dx
            mx, mn = max(abs(dx), abs(dy)), min(abs(dx), abs(dy))
            edges.append((dx, dy, c, 24 * mx + 9 * mn))        # half width 1.5 px
        slots.append(dict(color=shade, edges=edges, face=(axis, sign), nl=nl))
    assert len(slots) <= 3

    # Numbers for the text panel and the 7-segment display: the live vector, the angles of the steady one.
    st["peak2"] = max(st["peak2"], a2)
    nums = dict(x=mg_of(ax), y=mg_of(ay), z=mg_of(az), mag=mg_of(mag), peak=mg_of(isqrt(st["peak2"])),
                pitch=bam_deg10(pitch), roll=bam_deg10(roll))

    # The vector widget: the live acceleration in the board frame under the fixed view PW.
    tip = (WX_Q4 + ((PW[0][0] * ax + PW[0][1] * ay + PW[0][2] * az) >> 16),
           WY_Q4 - ((PW[1][0] * ax + PW[1][1] * ay + PW[1][2] * az) >> 16))
    shadow = (WX_Q4 + ((PW[0][0] * ax + PW[0][1] * ay) >> 16),
              WY_Q4 - ((PW[1][0] * ax + PW[1][1] * ay) >> 16))
    dx, dy = tip[0] - WX_Q4, tip[1] - WY_Q4
    dlen = isqrt(dx * dx + dy * dy)
    head_ok = dlen >= HEAD_Q4
    if head_ok:
        ux, uy = sdiv(dx * HEAD_Q4, dlen), sdiv(dy * HEAD_Q4, dlen)
        h1 = (tip[0] + ((-ux * C30 + uy * S30) >> 14), tip[1] + ((-ux * S30 - uy * C30) >> 14))
        h2 = (tip[0] + ((-ux * C30 - uy * S30) >> 14), tip[1] + ((ux * S30 - uy * C30) >> 14))
    else:
        h1 = h2 = tip
    origin = (WX_Q4, WY_Q4)
    segs = [seg_unit(origin, tip, 12, ARROW_COLOR),                     # first hit wins
            seg_unit(tip, h1, 12, ARROW_COLOR, valid=head_ok),
            seg_unit(tip, h2, 12, ARROW_COLOR, valid=head_ok),
            seg_unit(shadow, tip, 8, SHADOW_COLOR, dashed=True),
            seg_unit(origin, shadow, 8, SHADOW_COLOR, dashed=True),
            seg_unit(origin, AXIS_END[0], 6, AXIS_COLOR[0]),
            seg_unit(origin, AXIS_END[1], 6, AXIS_COLOR[1]),
            seg_unit(origin, AXIS_END[2], 6, AXIS_COLOR[2])]

    bars = [((abs(v) * 7) >> 9, v < 0) for v in aq]
    text, colors = panel_text(nums, devid, mode, test_n)
    return dict(gq=gq, aq=aq, psi=psi, mag=mag, gmag=gmag, r=r, angles=(sth, cth, sph, cph), pitch=pitch,
                roll=roll, cps=cps, sps=sps, p=p, verts=verts, slots=slots, nums=nums, segs=segs, bars=bars,
                text=text, colors=colors, tip=tip, shadow=shadow)


# ---------------------------------------------------------------- the text panel
def fmt_mg(num, signed=True):
    v, neg = num
    sign = "-" if neg else ("+" if signed else " ")
    return f"{sign}{v // 1000}.{v % 1000:03d}"


def fmt_deg(num):
    """6 chars: the sign floats to just before the first printed digit (' -30.0', '+180.0', '  +0.0')."""
    v, neg = num
    h, t, u, d = v // 1000, (v // 100) % 10, (v // 10) % 10, v % 10
    s = "-" if neg else "+"
    if h:
        head = f"{s}{h}{t}"
    elif t:
        head = f" {s}{t}"
    else:
        head = f"  {s}"
    return f"{head}{u}.{d}"


def panel_text(nums, devid, mode, test_n):
    """The 14 text rows. mode: "live", "cal" (live, calibrated) or "test". Row 12 is blank: an accelerometer
    cannot measure yaw (turning about gravity leaves it unchanged), so no yaw is shown."""
    rows = [" " * 16] * TEXT_ROWS
    rows[0] = f"ADXL345  ID {devid:02X}  "
    rows[2] = "X   " + fmt_mg(nums["x"]) + " G    "
    rows[4] = "Y   " + fmt_mg(nums["y"]) + " G    "
    rows[6] = "Z   " + fmt_mg(nums["z"]) + " G    "
    rows[8] = "MAG " + fmt_mg(nums["mag"], signed=False) + " G    "
    rows[9] = "PEAK" + fmt_mg(nums["peak"], signed=False) + " G    "
    rows[10] = "PITCH " + fmt_deg(nums["pitch"]) + " DEG"
    rows[11] = "ROLL  " + fmt_deg(nums["roll"]) + " DEG"
    rows[13] = MODE_ROW[mode].format(test_n)
    colors = dict(ROW_COLOR)
    colors[13] = TEST_COLOR if mode == "test" else LIVE_COLOR
    for r in rows:
        assert len(r) == 16, r
    return rows, colors


def report_line(fp, devid=0xE5):
    """The REPORT_LEN-character USB report ('r'), as cube_text.sv builds it: the live vector's Q4 counts with
    sign and five digits, then the panel's numbers and the mode row. The board adds CR LF."""
    aq, n = fp["aq"], fp["nums"]
    s = "AQ " + " ".join(f"{'-' if v < 0 else '+'}{abs(v):05d}" for v in aq)
    s += " X" + fmt_mg(n["x"]) + " Y" + fmt_mg(n["y"]) + " Z" + fmt_mg(n["z"])
    s += " MAG" + fmt_mg(n["mag"], signed=False) + " PEAK" + fmt_mg(n["peak"], signed=False)
    s += " PITCH" + fmt_deg(n["pitch"]) + " ROLL" + fmt_deg(n["roll"])
    s += f" ID {devid:02X} " + fp["text"][13]
    assert len(s) == REPORT_LEN, len(s)
    return s


_FONT = None


def font():
    """The glyphs of lib/rtl/font8x8.sv: code -> 8 rows, bit 0 = leftmost pixel."""
    global _FONT
    if _FONT is None:
        _FONT = {}
        for code, body in re.findall(r"7'h([0-9A-Fa-f]{2})\s*:\s*g\s*=\s*\{([^}]*)\}", open(FONT_SV).read()):
            rows = [int(b, 16) for b in re.findall(r"8'h([0-9A-Fa-f]{2})", body)]
            _FONT[int(code, 16)] = rows[::-1]
    return _FONT


# ---------------------------------------------------------------- per pixel (cube_draw.sv)
def gradient(y):
    """Four soft sky bands: 0x004, 0x005, 0x016, 0x017 (always brighter than the cube's dark edges)."""
    return ((y >> 8) << 4) | (4 + (y >> 7))


def dash_on(x, y):
    return ((x >> 2) ^ (y >> 2)) & 1


def pixel(x, y, fp):
    """RGB444 of pixel (x, y) for the frame parameters fp."""
    if x < PANEL_X:
        for slot in fp["slots"]:
            es = [((x * dy - y * dx) << 4) + c for dx, dy, c, t in slot["edges"]]
            if all(e >= 0 for e in es):
                r, g, b = slot["color"]
                if any(e <= t for e, (_, _, _, t) in zip(es, slot["edges"])):
                    r, g, b = r >> EDGE_DIV, g >> EDGE_DIV, b >> EDGE_DIV
                return (r << 8) | (g << 4) | b
        return gradient(y)
    if x < PANEL_X + 2:
        return SEP_COLOR
    fnt = font()
    if y >= WREG[2]:
        for s in fp["segs"]:
            xmin, xmax, ymin, ymax = s["box"]
            if not (s["valid"] and xmin <= x <= xmax and ymin <= y <= ymax):
                continue
            e = ((x * s["dy"] - y * s["dx"]) << 4) + s["c"]
            if abs(e) <= s["t"] and (not s["dashed"] or dash_on(x, y)):
                return s["color"]
        for j in range(3):
            lx, ly = LABEL_BOX[j]
            if lx <= x < lx + 8 and ly <= y < ly + 8 and (fnt[ord("XYZ"[j])][y - ly] >> (x - lx)) & 1:
                return AXIS_COLOR[j]
        return PANEL_BG
    row, col = y >> 4, (x - PANEL_X) >> 4
    ch = ord(fp["text"][row][col])
    if (fnt.get(ch, [0] * 8)[(y >> 1) & 7] >> ((x >> 1) & 7)) & 1:
        return fp["colors"].get(row, 0xEEE)
    rgb = PANEL_BG
    if row in (3, 5, 7):
        i, yy = (row - 3) >> 1, y & 15
        length, neg = fp["bars"][i]
        if 4 <= yy < 12 and ((not neg and BAR_X <= x < BAR_X + length) or (neg and BAR_X - length <= x < BAR_X)):
            rgb = BAR_COLOR[i]
        if 2 <= yy < 14:
            if x in (BAR_X - 57, BAR_X - 56, BAR_X + 55, BAR_X + 56):
                rgb = TICK_COLOR
            if x in (BAR_X - 1, BAR_X):
                rgb = CENTER_COLOR
    return rgb


def render(fp, full=False):
    """The frame as rows of RGB444: 320x240 (even pixels only, like the capture) or the full 640x480."""
    step = 1 if full else 2
    return [[pixel(x, y, fp) for x in range(0, W, step)] for y in range(0, H, step)]


def frame_hash(img):
    """h = h * 33 + rgb over the 320x240 picture in scan order (mod 2^32); the testbench computes the same."""
    h = 0
    for row in img:
        for v in row:
            h = (h * 33 + v) & 0xFFFFFFFF
    return h


# ---------------------------------------------------------------- pictures in and out
def write_png(path, img, scale=1):
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import frame_to_png
    pix = [[(((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17) for c in row] for row in img]
    frame_to_png.write_png(path, len(img[0]), len(img), pix, scale)


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


def compare(want, got, diff_png=None):
    bad = [(x, y) for y in range(len(want)) for x in range(len(want[0])) if got[y][x] != want[y][x]]
    if diff_png:
        marks = set(bad)
        img = [[0xF0F if (x, y) in marks else (want[y][x] >> 1) & 0x777 for x in range(len(want[0]))]
               for y in range(len(want))]
        write_png(diff_png, img, 2)
    return bad


# ---------------------------------------------------------------- cases
def parse_case(s):
    """A case string (see the module docstring) -> (test_n or None, gq, aq, mode, psi)."""
    s, _, yaw = s.partition("@")
    psi = int(yaw) if yaw else VIEW_YAW
    assert -32768 <= psi <= 32767, "the view yaw is a BAM16 angle: -32768 .. 32767"
    if s.isdigit() and len(s) == 1 and int(s) < len(PRESETS):
        return int(s), PRESETS[int(s)], PRESETS[int(s)], "test", psi
    kind, _, v = s.partition(":")
    if not v:
        kind, v = "", s
    if kind == "ema":
        parts = v.split(";")
        assert 3 <= len(parts) <= 4, "ema:vx,vy,vz;bx,by,bz;k[;cal]"
        vec = tuple(int(x) for x in parts[0].split(","))
        b = tuple(int(x) for x in parts[1].split(","))
        cal = len(parts) == 4
        assert len(vec) == 3 and len(b) == 3 and (not cal or parts[3] == "cal"), "ema:vx,vy,vz;bx,by,bz;k[;cal]"
        gq, aq = ema_live(vec, b, int(parts[2]), cal)
        return None, gq, aq, "cal" if cal else "live", psi
    vals = [int(x) for x in v.split(",")]
    assert len(vals) == 3 and kind in ("", "q", "cal"), \
        "case is a preset 0..7, seq:N, ax,ay,az in mg, q:..., cal:... or ema:... (see the docstring)"
    if kind == "":
        vals = [(x * 4096 + 500) // 1000 if x >= 0 else -((-x * 4096 + 500) // 1000) for x in vals]
    vec = tuple(sat16(x) for x in vals)
    return None, vec, vec, "cal" if kind == "cal" else "live", psi


def frame_for(case, st=None):
    if case.startswith("seq:"):                         # preset N as the testbench shows it, after presets 0..N-1
        return preset_sequence()[int(case[4:])]
    n, gq, aq, mode, psi = parse_case(case)
    st = new_state() if st is None else st
    if n is not None:
        st["peak2"] = 0                                 # selecting a preset resets the peak
        return frame_math(gq, aq, psi, st, mode="test", test_n=n)
    return frame_math(gq, aq, psi, st, mode=mode)


def preset_sequence():
    """The frames the testbench shows: presets 0..7 in order, the held orientation carried between them."""
    st = new_state()
    return [frame_for(str(n), st) for n in range(len(PRESETS))]


def math_sequence():
    """What sim/tb_cube_math.sv runs: the preset sequence, then YAW_CASES (gq = aq) and GA_CASES (gq != aq)
    with the same state (the peak kept)."""
    st = new_state()
    frames = [frame_for(str(n), st) for n in range(len(PRESETS))]
    frames += [frame_math(aq, aq, psi, st, mode="live") for aq, psi in YAW_CASES]
    frames += [frame_math(gq, aq, psi, st, mode="live") for gq, aq, psi in GA_CASES]
    return frames


def math_dump(fp, n):
    """The per-frame values as text, one line per item, in the format sim/tb_cube_math.sv prints:
    a line-by-line comparison points at the first wrong number instead of a wrong frame hash."""
    sth, cth, sph, cph = fp["angles"]
    lines = [f"frame {n}",
             f"mag {fp['mag']} g {fp['gmag']} r {fp['r']}",
             f"ang {sth} {cth} {sph} {cph}",
             f"pr {fp['pitch']} {fp['roll']} {fp['cps']} {fp['sps']}",
             "p " + " ".join(str(v) for row in fp["p"] for v in row),
             "v " + " ".join(f"{x} {y}" for x, y in fp["verts"]),
             f"slots {len(fp['slots'])}"]
    for i, sl in enumerate(fp["slots"]):
        lines.append(f"slot {i} {sl['color'][0]} {sl['color'][1]} {sl['color'][2]}")
        for e, (dx, dy, c, t) in enumerate(sl["edges"]):
            lines.append(f"edge {i} {e} {dx} {dy} {c} {t}")
    nm = fp["nums"]
    lines.append("nums " + " ".join(f"{nm[k][0]:04d} {int(nm[k][1])}"
                                    for k in ("x", "y", "z", "mag", "peak", "pitch", "roll")))
    lines.append("aq " + " ".join(f"{abs(v):05d} {int(v < 0)}" for v in fp["aq"]))
    lines.append("bars " + " ".join(f"{ln} {int(ng)}" for ln, ng in fp["bars"]))
    for i, sg in enumerate(fp["segs"]):
        lines.append(f"seg {i} {int(sg['valid'])} {int(sg['dashed'])} {sg['dx']} {sg['dy']} {sg['c']} {sg['t']} "
                     + " ".join(str(b) for b in sg["box"]) + f" {sg['color']:03x}")
    return lines


def dump_compare(path):
    """Compare the testbench's dump file with the model's; return the number of lines that differ."""
    want = [l for n, fp in enumerate(math_sequence()) for l in math_dump(fp, n)]
    got = [l.strip() for l in open(path, encoding="utf-8") if l.strip()]
    bad = 0
    for i in range(max(len(want), len(got))):
        w = want[i] if i < len(want) else "<missing>"
        g = got[i] if i < len(got) else "<missing>"
        if w != g:
            bad += 1
            if bad <= 20:
                print(f"line {i + 1}:\n  want {w}\n  got  {g}")
    print(f"{bad} of {len(want)} lines differ")
    return bad


# ---------------------------------------------------------------- float reference and self-tests
def float_angles(aq):
    ax, ay, az = aq
    r = math.hypot(ay, az)
    return math.degrees(math.atan2(-ax, r)), math.degrees(math.atan2(ay, az))


def bam_deg(b):
    return b * 360 / 65536


def selftest(seed=1):
    rnd = random.Random(seed)
    # 1. CORDIC against math
    worst_rot = worst_vec = 0
    for a in range(-32768, 32768, 7):
        c, s = cordic_rot(a)
        rad = a * 2 * math.pi / 65536
        worst_rot = max(worst_rot, abs(c - math.cos(rad) * 16384), abs(s - math.sin(rad) * 16384))
    for _ in range(5000):
        x, y = rnd.randint(-16384, 16384), rnd.randint(-16384, 16384)
        if math.hypot(x, y) < 8192:              # the design feeds unit vectors (|v| ~ 16384)
            continue
        got = cordic_vec(x, y)
        want = math.degrees(math.atan2(y, x))
        d = (bam_deg(got) - want + 180) % 360 - 180
        worst_vec = max(worst_vec, abs(d))
    assert worst_rot <= 4, worst_rot
    assert worst_vec <= 0.02, worst_vec
    print(f"cordic: rotation within {worst_rot:.0f} LSB of Q14, vectoring within {worst_vec:.4f} deg")

    # 2. angles, magnitude, winding, overlap, extent over random orientations
    worst_ang = worst_mg = 0
    maxes = dict(dx=0, c=0, t=0, e=0, x=0, y=0, vx=(10 ** 9, 0), vy=(10 ** 9, 0))
    st = new_state()
    for it in range(400):
        gmag = rnd.uniform(0.3, 2.0)
        th, ph = rnd.uniform(0, 2 * math.pi), math.acos(rnd.uniform(-1, 1))
        aq = tuple(int(round(gmag * 4096 * v)) for v in (math.sin(ph) * math.cos(th), math.sin(ph) * math.sin(th), math.cos(ph)))
        aq = tuple(max(-8192, min(8191, v)) for v in aq)
        psi = rnd.randint(-32768, 32767)
        fp = frame_math(aq, aq, psi, st)
        fpitch, froll = float_angles(aq)
        pm, pn = fp["nums"]["pitch"]
        rm, rn = fp["nums"]["roll"]
        worst_ang = max(worst_ang, abs((-pm if pn else pm) / 10 - fpitch))
        if math.hypot(aq[1], aq[2]) >= HOLD_R:
            worst_ang = max(worst_ang, abs(((-rm if rn else rm) / 10 - froll + 180) % 360 - 180))
        worst_mg = max(worst_mg, abs(fp["nums"]["mag"][0] - math.sqrt(sum(v * v for v in aq)) / 4.096))
        for xq, yq in fp["verts"]:
            assert 0 <= xq < PANEL_X * 16 and 0 <= yq < H * 16, (aq, psi, fp["verts"])
            maxes["vx"] = (min(maxes["vx"][0], xq), max(maxes["vx"][1], xq))
            maxes["vy"] = (min(maxes["vy"][0], yq), max(maxes["vy"][1], yq))
        for i, slot in enumerate(fp["slots"]):
            axis, sign = slot["face"]
            idx = next(f[2] for f in FACES if f[0] == axis and f[1] == sign)
            cxq = sum(fp["verts"][k][0] for k in idx) // 4
            cyq = sum(fp["verts"][k][1] for k in idx) // 4
            px, py = cxq >> 4, cyq >> 4
            for dx, dy, c, t in slot["edges"]:
                e = ((px * dy - py * dx) << 4) + c
                assert e > 0, f"winding: centroid of face {axis, sign} outside its own edge {(aq, psi)}"
                maxes["dx"] = max(maxes["dx"], abs(dx), abs(dy))
                maxes["c"] = max(maxes["c"], abs(c))
                maxes["t"] = max(maxes["t"], t)
            for j, other in enumerate(fp["slots"]):
                if j != i:
                    es = [((px * dy - py * dx) << 4) + c for dx, dy, c, t in other["edges"]]
                    assert not all(e >= 0 for e in es), "two visible faces overlap"
        for s in fp["segs"]:
            maxes["dx"] = max(maxes["dx"], abs(s["dx"]), abs(s["dy"]))
            maxes["c"] = max(maxes["c"], abs(s["c"]))
            maxes["t"] = max(maxes["t"], s["t"])
    for x in (0, PANEL_X - 1, W - 1):
        for y in (0, H - 1):
            maxes["e"] = max(maxes["e"], 16 * (x * maxes["dx"] + y * maxes["dx"]) + maxes["c"])
    assert worst_ang <= 0.2, worst_ang
    assert worst_mg <= 1.0, worst_mg
    print(f"angles within {worst_ang:.3f} deg of float, |a| within {worst_mg:.2f} mg; winding and no-overlap hold")
    print(f"ranges: |dx|,|dy| <= {maxes['dx']} (14 bit signed ok: {maxes['dx'] < 8192}), |C| <= {maxes['c']} "
          f"({maxes['c'].bit_length() + 1} bits), T <= {maxes['t']} ({maxes['t'].bit_length()} bits), "
          f"|E| <= {maxes['e']} ({maxes['e'].bit_length() + 1} bits)")
    print(f"vertex x {maxes['vx'][0] / 16:.1f}..{maxes['vx'][1] / 16:.1f} px, y {maxes['vy'][0] / 16:.1f}..{maxes['vy'][1] / 16:.1f} px")

    # 3. the preset sequence: 3 visible faces at most, pictures render, hashes are stable
    for n, fp in enumerate(preset_sequence()):
        img = render(fp)
        print(f"preset {n}: aq={fp['aq']} |a|={fp['nums']['mag'][0]} mg pitch={fmt_deg(fp['nums']['pitch'])} "
              f"roll={fmt_deg(fp['nums']['roll'])} faces={[s['face'] for s in fp['slots']]} hash={frame_hash(img):08x}")

    # 4. two vectors: the cube follows gq only, the numbers follow aq only; the calibration zeroes gq.
    st = new_state()
    flat = frame_math((0, 0, 4096), (0, 0, 4096), VIEW_YAW, st, mode="live")
    shaken = frame_math((0, 0, 4096), (3000, -2000, 9000), VIEW_YAW, st, mode="live")
    assert shaken["verts"] == flat["verts"] and shaken["slots"] == flat["slots"], "the cube moved with aq"
    assert shaken["nums"]["x"] == (732, False) and shaken["nums"]["peak"][0] > flat["nums"]["peak"][0]
    assert shaken["tip"] != flat["tip"] and shaken["bars"] != flat["bars"], "the widget did not follow aq"
    weak = frame_math((0, 200, 300), (4800, -3200, 14400), VIEW_YAW, st, mode="live")
    assert weak["angles"] == shaken["angles"], "a weak gq must hold the orientation whatever aq is"
    gq, aq = ema_live((300, -200, 900), (300, -200, 900), 0, cal=True)
    assert gq == aq == (0, 0, 4096), (gq, aq)
    gq, aq = ema_live((300, -200, 900), (100, 100, 1000), 1, cal=True)
    assert gq == (-400, 600, 4296) and aq == (-3200, 4800, 5696), (gq, aq)
    assert ema_live((0, 0, 2047), (0, 0, 2047), 0)[0] == (0, 0, 32752) and sat16(40000) == 32767
    for case in ("q:4800,-3200,14400", "cal:0,0,4096", "ema:300,-200,900;100,100,1000;1;cal",
                 "ema:300,-200,900;100,100,1000;1@5552"):
        assert len(report_line(frame_for(case))) == REPORT_LEN
    print("two-vector split, calibration offsets and the report length hold")
    print("PASS")


# ---------------------------------------------------------------- constants for the RTL
def sv(v, bits=16):
    """A sized signed Verilog literal: 16'sd6554 or -16'sd6554 (gotcha 8: size every constant)."""
    return f"-{bits}'sd{-v}" if v < 0 else f"{bits}'sd{v}"


def constants():
    out = []
    out.append("// Generated by assets/model.py constants. Keep in step with the model.")
    out.append(f"localparam signed [17:0] CORDIC_X0 = {sv(CORDIC_X0, 18)};  // Q{14 + GUARD}")
    out.append(f"localparam signed [15:0] SE = {sv(SE)}, CE = {sv(CE)}, C30 = {sv(C30)}, S30 = {sv(S30)};")
    out.append(f"localparam signed [15:0] VIEW_YAW = {sv(VIEW_YAW)}, SPIN_STEP = {sv(SPIN_STEP)};")
    out.append(f"localparam signed [15:0] LX = {sv(LIGHT[0])}, LY = {sv(LIGHT[1])}, LZ = {sv(LIGHT[2])};  // light, Q14")
    out.append(f"localparam signed [15:0] VIS_NZ = {sv(VIS_NZ)};")
    for i in range(2):
        out.append(f"localparam signed [15:0] PW{i}0 = {sv(PW[i][0])}, PW{i}1 = {sv(PW[i][1])}, PW{i}2 = {sv(PW[i][2])};")
    for j in range(3):
        out.append(f"localparam signed [15:0] AX{j}_X = {sv(AXIS_END[j][0])}, AX{j}_Y = {sv(AXIS_END[j][1])};  // Q4 px")
    for j in range(3):
        out.append(f"localparam [9:0] LB{j}_X = 10'd{LABEL_BOX[j][0]}, LB{j}_Y = 10'd{LABEL_BOX[j][1]};")
    out.append("// atan table for the CORDIC, BAM16 << ZF (a function: Quartus 17.1 and Icarus both take it)")
    out.append("function automatic [19:0] atan_z(input [3:0] i);")
    out.append("  case (i)")
    for i, v in enumerate(ATAN_Z):
        out.append(f"    4'd{i}: atan_z = 20'd{v};")
    out.append("    default: atan_z = 20'd0;")
    out.append("  endcase")
    out.append("endfunction")
    return "\n".join(out)


# ---------------------------------------------------------------- command line
def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "selftest":
        selftest()
    elif cmd == "render":
        fp = frame_for(argv[1])
        full = "--full" in argv
        img = render(fp, full)
        write_png(argv[2], img, 1 if full else 2)
        print(f"{argv[2]}: {len(img[0])}x{len(img)}, hash {frame_hash(render(fp)):08x}")
    elif cmd == "hashes":
        for n, fp in enumerate(preset_sequence()):
            print(f"{n} {frame_hash(render(fp)):08x}")
    elif cmd == "compare":
        fp = frame_for(argv[1])
        got = read_ppm(argv[2]) if argv[2].lower().endswith(".ppm") else read_dump(argv[2])
        want = render(fp)
        bad = compare(want, got, argv[3] if len(argv) > 3 else None)
        print(f"{len(bad)} of {len(want) * len(want[0])} pixels differ")
        return 1 if bad else 0
    elif cmd == "constants":
        print(constants())
    elif cmd == "dump":
        for n, fp in enumerate(math_sequence()):
            print("\n".join(math_dump(fp, n)))
    elif cmd == "dumpcmp":
        return 1 if dump_compare(argv[1]) else 0
    elif cmd == "report":
        print(report_line(frame_for(argv[1])))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
