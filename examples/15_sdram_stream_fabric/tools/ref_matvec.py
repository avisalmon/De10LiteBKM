"""The weight stream format and the compute unit's arithmetic, in numpy (spec sections 6 and 7).

This is the reference the hardware is compared against, bit for bit: lib/sim/tb_matvec_unit.sv carries the same
rules in Verilog, scripts/fabric_ctl.py uses this file to build jobs and to check the results read back from the
board, tools/export_q8.py uses it to write a model.

The format: a matrix W (ROWS x K, rows = outputs, K = inputs) is quantized to int8 in groups of G = 32 along K
with one int16 scale per group and one exponent E per matrix: w ~ q * s_g * 2^E. On the stream (and in the SDRAM)
a group is 17 16-bit words: 16 words of int8 pairs, word j = {w[2j+1], w[2j]} (little-endian), then s_g. A row is
K/32 groups, 17 * K/32 words, rows follow each other; K is padded to a multiple of 32 with zeros.

The arithmetic: for a row and an activation vector x_t (K int8), acc = sum_g (sum_j q_j * x_t[j]) * s_g exactly
(48-bit in hardware, int64 here), then y = saturate_int32(acc >> SHIFT) with an arithmetic shift. T vectors at
once; the unit pushes y[row][t] for t = 0..T-1, row after row, and the lane writes each int32 as two 16-bit words,
low half first.

  python tools/ref_matvec.py --selftest       round trips and a few invariants
"""
import numpy as np

G = 32                              # weights per group
GROUP_WORDS = 17                    # 16 words of pairs + the scale
MATRIX_ALIGN = 1024                 # words: every matrix starts on an SDRAM row
INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1


def pad_k(k):
    """K rounded up to a multiple of G."""
    return -(-k // G) * G


def row_words(k):
    """16-bit words per row of a K-wide matrix (K padded)."""
    return pad_k(k) // G * GROUP_WORDS


def matrix_words(rows, k):
    return rows * row_words(k)


def aligned(words):
    """words rounded up to the matrix alignment."""
    return -(-words // MATRIX_ALIGN) * MATRIX_ALIGN


def default_shift(k):
    """A SHIFT that cannot saturate for any int8 x: |acc| <= K * 128 * 128 * 32768 (groups of 32 add up to K)."""
    bound = pad_k(k) * 128 * 128 * 32768
    return max(0, bound.bit_length() - 31)


def quantize(w):
    """float W (ROWS x K) -> (q int8 [ROWS, Kpad], s int16 [ROWS, groups], E) with w ~ q * s * 2^E.

    Per group the scale is max|w| / 127; E is the smallest exponent that brings every scale under 32767 as an
    int16, so the biggest group uses the full int16 range. Zero groups get scale 0.
    """
    w = np.asarray(w, dtype=np.float64)
    rows, k = w.shape
    kp = pad_k(k)
    wp = np.zeros((rows, kp))
    wp[:, :k] = w
    groups = wp.reshape(rows, kp // G, G)
    amax = np.abs(groups).max(axis=2)                      # [rows, groups]
    scale = amax / 127.0
    top = scale.max()
    if top == 0:
        return np.zeros((rows, kp), np.int8), np.zeros(amax.shape, np.int16), 0
    e = int(np.ceil(np.log2(top / 32767.0)))
    while top / 2.0 ** e > 32767.0:                        # guard against rounding at the edge
        e += 1
    s = np.rint(scale / 2.0 ** e).astype(np.int64)
    s = np.clip(s, 0, 32767).astype(np.int16)
    real_scale = s.astype(np.float64) * 2.0 ** e           # the scale the hardware will apply
    with np.errstate(divide="ignore", invalid="ignore"):
        q = np.where(real_scale[:, :, None] > 0, groups / real_scale[:, :, None], 0.0)
    q = np.clip(np.rint(q), -127, 127).astype(np.int8)
    return q.reshape(rows, kp), s, e


def dequantize(q, s, e):
    """The weights the hardware effectively uses: float64 [ROWS, Kpad]."""
    rows, kp = q.shape
    groups = q.astype(np.float64).reshape(rows, kp // G, G)
    return (groups * (s.astype(np.float64) * 2.0 ** e)[:, :, None]).reshape(rows, kp)


def stream_words(q, s):
    """(q int8 [ROWS, Kpad], s int16 [ROWS, groups]) -> the uint16 words of the matrix on the stream."""
    rows, kp = q.shape
    ng = kp // G
    pairs = q.astype(np.uint8).reshape(rows, ng, G // 2, 2).astype(np.uint16)
    words = np.empty((rows, ng, GROUP_WORDS), np.uint16)
    words[:, :, :16] = pairs[:, :, :, 0] | (pairs[:, :, :, 1] << 8)
    words[:, :, 16] = s.astype(np.uint16)
    return words.reshape(-1)


def stream_bytes(q, s):
    """The matrix as the loader writes it: little-endian 16-bit words."""
    return stream_words(q, s).astype("<u2").tobytes()


def parse_stream(words, rows, k):
    """uint16 words of one matrix -> (q int8 [ROWS, Kpad], s int16 [ROWS, groups])."""
    kp = pad_k(k)
    ng = kp // G
    w = np.asarray(words, dtype=np.uint16)[:rows * ng * GROUP_WORDS].reshape(rows, ng, GROUP_WORDS)
    lo = (w[:, :, :16] & 0xFF).astype(np.uint8).astype(np.int8)
    hi = (w[:, :, :16] >> 8).astype(np.uint8).astype(np.int8)
    q = np.stack([lo, hi], axis=3).reshape(rows, kp)
    s = w[:, :, 16].astype(np.int16)
    return q, s


def group_sums(q, x):
    """sum_j q_j x_j per group: int64 [ROWS, groups, T] (x: int8 [T, Kpad])."""
    rows, kp = q.shape
    ng = kp // G
    qg = q.astype(np.int64).reshape(rows, ng, G)
    xg = np.asarray(x, dtype=np.int64).reshape(-1, ng, G)
    return np.einsum("rgj,tgj->rgt", qg, xg)


def accumulate(q, s, x):
    """The 48-bit accumulators before the shift: int64 [ROWS, T]."""
    gs = group_sums(q, x)
    return np.einsum("rgt,rg->rt", gs, s.astype(np.int64))


def matvec(q, s, x, shift):
    """What the unit pushes: int32 [ROWS, T] = saturate(acc >> shift), x int8 [T, Kpad]."""
    acc = accumulate(q, s, x) >> shift
    return np.clip(acc, INT32_MIN, INT32_MAX).astype(np.int32)


def matvec_float(q, s, e, x, x_scale, shift):
    """The real-valued product the hardware result stands for: y_float = y << shift * 2^E * x_scale."""
    y = matvec(q, s, x, shift).astype(np.float64)
    return y * 2.0 ** shift * 2.0 ** e * x_scale


def quantize_x(x):
    """float x (T x K or K) -> (int8 [T, Kpad], x_scale) with x ~ q * x_scale (one scale for the whole batch)."""
    x = np.atleast_2d(np.asarray(x, dtype=np.float64))
    t, k = x.shape
    xp = np.zeros((t, pad_k(k)))
    xp[:, :k] = x
    top = np.abs(xp).max()
    x_scale = top / 127.0 if top > 0 else 1.0
    return np.clip(np.rint(xp / x_scale), -127, 127).astype(np.int8), x_scale


def results_words(y):
    """int32 [ROWS, T] -> the uint16 words a lane writes: row after row, t after t, low half first."""
    v = np.asarray(y, dtype=np.int32).reshape(-1).astype(np.uint32)
    return np.stack([v & 0xFFFF, v >> 16], axis=1).reshape(-1).astype(np.uint16)


def parse_results(words, rows, t):
    """uint16 words read back from a lane -> int32 [rows, t]."""
    w = np.asarray(words, dtype=np.uint16)[:rows * t * 2].astype(np.uint32).reshape(rows, t, 2)
    return (w[:, :, 0] | (w[:, :, 1] << 16)).astype(np.uint32).astype(np.int32)


def x_words(x):
    """int8 [T, Kpad] -> uint32 [T, Kpad/4]: what the host writes to XDATA, vector t from XADDR = t << 12."""
    x = np.asarray(x, dtype=np.int8)
    t, kp = x.shape
    b = x.astype(np.uint8).reshape(t, kp // 4, 4).astype(np.uint32)
    return b[:, :, 0] | (b[:, :, 1] << 8) | (b[:, :, 2] << 16) | (b[:, :, 3] << 24)


def split_rows(rows, units):
    """Row slices for the units: a list of (first_row, n_rows), the big slices first, no empty slice."""
    n = min(units, rows)
    base, extra = divmod(rows, n)
    out, r = [], 0
    for u in range(n):
        cnt = base + (1 if u < extra else 0)
        out.append((r, cnt))
        r += cnt
    return out


def random_matrix(rows, k, rng, extreme=False):
    """A random quantized matrix (q, s) like the testbench's: full-range int8 and int16, or only the extremes."""
    kp = pad_k(k)
    if extreme:
        q = rng.choice(np.array([-127, 127], np.int8), size=(rows, kp))
        s = rng.choice(np.array([-32768, 32767], np.int16), size=(rows, kp // G))
    else:
        q = rng.integers(-128, 128, size=(rows, kp), dtype=np.int64).astype(np.int8)
        s = rng.integers(-32768, 32768, size=(rows, kp // G), dtype=np.int64).astype(np.int16)
    return q, s


def random_x(k, t, rng, extreme=False):
    kp = pad_k(k)
    if extreme:
        return rng.choice(np.array([-128, 127], np.int8), size=(t, kp))
    return rng.integers(-128, 128, size=(t, kp), dtype=np.int64).astype(np.int8)


def _selftest():
    rng = np.random.default_rng(1)
    # the stream round trip
    for rows, k in ((3, 32), (5, 288), (2, 1024), (4, 172)):
        q, s = random_matrix(rows, k, rng)
        words = stream_words(q, s)
        assert words.size == matrix_words(rows, k), (rows, k, words.size)
        q2, s2 = parse_stream(words, rows, k)
        assert np.array_equal(q, q2) and np.array_equal(s, s2), (rows, k)
        assert len(stream_bytes(q, s)) == 2 * words.size
    # the result words round trip, and x words
    y = rng.integers(INT32_MIN, INT32_MAX + 1, size=(7, 3), dtype=np.int64).astype(np.int32)
    assert np.array_equal(parse_results(results_words(y), 7, 3), y)
    x = random_x(64, 2, rng)
    xw = x_words(x)
    assert xw.shape == (2, 16) and xw[1, 0] == int.from_bytes(x[1, :4].tobytes(), "little")
    # the arithmetic against a plain loop
    q, s = random_matrix(4, 96, rng)
    x = random_x(96, 3, rng)
    shift = 5
    y = matvec(q, s, x, shift)
    for r in range(4):
        for t in range(3):
            acc = 0
            for g in range(3):
                gs = sum(int(q[r, 32 * g + j]) * int(x[t, 32 * g + j]) for j in range(32))
                acc += gs * int(s[r, g])
            acc >>= shift
            acc = max(INT32_MIN, min(INT32_MAX, acc))
            assert acc == int(y[r, t]), (r, t, acc, y[r, t])
    # saturation both ways at shift 0, none at the default shift
    q, s = random_matrix(4, 288, rng, extreme=True)
    x = random_x(288, 2, rng, extreme=True)
    y0 = matvec(q, s, x, 0)
    assert (y0 == INT32_MAX).any() or (y0 == INT32_MIN).any()
    acc = accumulate(q, s, x) >> default_shift(288)
    assert acc.min() >= INT32_MIN and acc.max() <= INT32_MAX
    # quantize: the error is within the step
    w = rng.normal(size=(6, 172)) * rng.uniform(0.01, 1.0, size=(6, 1))
    q, s, e = quantize(w)
    assert q.shape == (6, 192) and s.shape == (6, 6) and s.max() <= 32767 and s.min() >= 0
    back = dequantize(q, s, e)[:, :172]
    step = (s.astype(np.float64) * 2.0 ** e).repeat(G, axis=1)[:, :172]
    assert np.all(np.abs(back - w) <= 0.5 * step + 1e-12)
    assert np.all(back[:, 172:] == 0) if back.shape[1] > 172 else True
    # the exponent choice: the biggest scale uses the top of the int16 range
    assert s.max() >= 16384
    # split_rows
    assert split_rows(10, 6) == [(0, 2), (2, 2), (4, 2), (6, 2), (8, 1), (9, 1)]
    assert split_rows(2, 6) == [(0, 1), (1, 1)]
    # a float matvec stands for the real product
    xq, xs = quantize_x(rng.normal(size=(2, 172)))
    yf = matvec_float(q, s, e, xq, xs, default_shift(172))
    ref = back @ (xq.astype(np.float64)[:, :172] * xs).T
    assert np.allclose(yf, ref, rtol=1e-6, atol=1e-6 * np.abs(ref).max() + 2.0 ** default_shift(172) * 2.0 ** e * xs)
    print("ref_matvec self-test: OK")


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv or len(sys.argv) == 1:
        _selftest()
    else:
        sys.exit(__doc__)
