"""Draw the two 64x64 test pictures for example 02 (chip.png, smiley.png) and convert them to ROM files.
python examples/02_rom/assets/make_images.py   (needs Pillow; run from the repo root)
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


def chip():
    im = Image.new("RGB", (64, 64), (20, 24, 40))
    d = ImageDraw.Draw(im)
    for y in range(64):						# background gradient
        d.line([(0, y), (63, y)], fill=(20 + y, 30 + y // 2, 90 + y))
    for i in range(6):							# pins
        for (x0, y0, x1, y1) in ((14 + i * 7, 4, 17 + i * 7, 12), (14 + i * 7, 52, 17 + i * 7, 60),
                                 (4, 14 + i * 7, 12, 17 + i * 7), (52, 14 + i * 7, 60, 17 + i * 7)):
            d.rectangle([x0, y0, x1, y1], fill=(220, 190, 90))
    d.rectangle([12, 12, 51, 51], fill=(40, 40, 48), outline=(200, 200, 210))
    d.rectangle([18, 18, 45, 45], outline=(90, 200, 120))
    d.text((21, 26), "ROM", fill=(255, 220, 60))
    return im


def smiley():
    im = Image.new("RGB", (64, 64), (0, 120, 160))
    d = ImageDraw.Draw(im)
    d.ellipse([6, 6, 57, 57], fill=(255, 210, 40), outline=(120, 80, 0), width=2)
    d.ellipse([20, 20, 27, 30], fill=(40, 30, 20))
    d.ellipse([36, 20, 43, 30], fill=(40, 30, 20))
    d.arc([18, 22, 45, 47], 20, 160, fill=(40, 30, 20), width=3)
    return im


def text_rom():
    """screen.txt (up to 30 lines of up to 40 characters) -> text.hex, one ASCII byte per character cell."""
    lines = open(os.path.join(HERE, "screen.txt")).read().split("\n")[:30]
    cells = [(l + " " * 40)[:40] for l in lines + [""] * (30 - len(lines))]
    with open(os.path.join(HERE, "text.hex"), "w", newline="\n") as f:
        f.write("".join(f"{ord(c):02X}\n" for row in cells for c in row))


if __name__ == "__main__":
    text_rom()
    for name, im in (("chip", chip()), ("smiley", smiley())):
        png = os.path.join(HERE, name + ".png")
        im.save(png)
        subprocess.check_call([sys.executable, os.path.join(ROOT, "scripts", "img2rom.py"), png, os.path.join(HERE, name)])
