"""Turn a debug_link frame dump (FRAME w h / rows of 3-hex-digit RGB444 pixels / END) into a PNG.

Usage: python frame_to_png.py <dump.txt> <out.png> [scale]
The dump may contain other lines (status / event lines) before and after the frame.
"""
import sys
import zlib
import struct


def parse(text):
    # juart-terminal on Windows turns "\r\n" into "\r\r\n": drop every \r and any empty line
    lines = [l.strip() for l in text.replace("\r", "").split("\n") if l.strip()]
    start = max(i for i, l in enumerate(lines) if l.startswith("FRAME "))
    _, w, h = lines[start].split()
    w, h = int(w), int(h)
    # pixel rows are exactly 3*w hex digits; other lines (log lines from another sender) may sit in between
    rows = [l for l in lines[start + 1:] if len(l) == 3 * w and all(c in "0123456789ABCDEF" for c in l)][:h]
    if len(rows) != h or any(len(r) != 3 * w for r in rows):
        raise ValueError(f"frame incomplete: {len(rows)} rows, lengths {sorted(set(len(r) for r in rows))}")
    pix = [[tuple(int(r[3 * x + c], 16) * 17 for c in range(3)) for x in range(w)] for r in rows]
    return w, h, pix


def write_png(path, w, h, pix, scale):
    raw = b""
    for y in range(h * scale):
        row = pix[y // scale]
        raw += b"\x00" + b"".join(bytes(row[x // scale]) for x in range(w * scale))

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    with open(src, "r", encoding="ascii", errors="replace") as f:
        w, h, pix = parse(f.read())
    write_png(dst, w, h, pix, scale)
    print(f"{dst}: {w}x{h} frame, scaled x{scale}")
