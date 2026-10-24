"""Turn an image into ROM contents for the DE10-Lite screen (12-bit RGB444, one word per pixel, row by row).

  python scripts/img2rom.py <image.png> <out_base> [--size WxH] [--transparent RRGGBB]

Writes <out_base>.hex (for $readmemh in an inferred ROM) and <out_base>.mif (for the altsyncram ROM IP and the
In-System Memory Content Editor), plus <out_base>_preview.png showing the image after the cut to 12-bit colour.
--transparent: pixels of this colour become 0x000 and the design treats 0x000 as "see-through".
Needs Pillow (in requirements.txt).
"""
import argparse
import os

from PIL import Image


def to_words(img, transparent=None):
    words = []
    pixels = img.get_flattened_data() if hasattr(img, "get_flattened_data") else img.getdata()
    for (r, g, b, *a) in pixels:
        if (a and a[0] < 128) or (transparent and (r, g, b) == transparent):
            words.append(0x000)
            continue
        w = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        words.append(w if w else 0x111)		# real black stays visible (0x000 means transparent)
    return words


def write(base, words, w, h):
    with open(base + ".hex", "w", newline="\n") as f:
        f.write("".join(f"{x:03X}\n" for x in words))
    with open(base + ".mif", "w", newline="\n") as f:
        f.write(f"-- {os.path.basename(base)}: {w}x{h} RGB444, row by row, made by scripts/img2rom.py\n")
        f.write(f"WIDTH = 12;\nDEPTH = {len(words)};\nADDRESS_RADIX = HEX;\nDATA_RADIX = HEX;\nCONTENT BEGIN\n")
        f.write("".join(f"  {i:X} : {x:03X};\n" for i, x in enumerate(words)))
        f.write("END;\n")
    prev = Image.new("RGB", (w, h))
    prev.putdata([((x >> 8) * 17, ((x >> 4) & 15) * 17, (x & 15) * 17) for x in words])
    prev.resize((w * 4, h * 4), Image.NEAREST).save(base + "_preview.png")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("out_base")
    ap.add_argument("--size", default=None, help="resize first, e.g. 64x64")
    ap.add_argument("--transparent", default=None, help="RRGGBB colour to make see-through")
    a = ap.parse_args()
    img = Image.open(a.image).convert("RGBA")
    if a.size:
        img = img.resize(tuple(int(v) for v in a.size.lower().split("x")), Image.LANCZOS)
    t = tuple(int(a.transparent[i:i + 2], 16) for i in (0, 2, 4)) if a.transparent else None
    words = to_words(img, t)
    write(a.out_base, words, img.width, img.height)
    print(f"OK: {a.out_base}.hex/.mif ({img.width}x{img.height}, {len(words)} words of 12 bits = {len(words) * 12} bits)")
