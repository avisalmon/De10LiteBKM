"""Space Invaders sprites -> the Verilog sprite tables and a preview picture.

    python assets/make_sprites.py        (from projects/invaders)

Our own pixel art, drawn at the arcade's sizes (the 1978 game's bitmaps are Taito's and are not used):
  invaders  8, 11 and 12 pixels wide (30, 20 and 10 points) in a 16 x 8 cell, two frames each, and the explosion
  cannon    13 x 8 in a 16 x 8 cell, and two explosion frames
  saucer    16 x 8 in a 24 x 8 cell, and its explosion
  bombs     3 x 8, three kinds, four frames each; the shot's explosion 8 x 8; a bomb's explosion 6 x 8
  shield    22 x 16
Writes:
  src/inv_sprites.sv         combinational tables, one module per kind of picture; bit 0 = the leftmost column
  assets/sprites_preview.png every picture, magnified, to check by eye
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------- the art ('#' lit, '.' dark), rows top to bottom
INVADERS = {  # kind: (frame 0, frame 1); kind 0 = 10 points (bottom rows) .. 2 = 30 points (top row)
    0: ([".....######.....",      # the jellyfish, 12 wide (columns 2..13): the tentacles open and close
         "...##########...",
         "..###.####.###..",
         "..############..",
         ".....#.##.#.....",
         "....#..##..#....",
         "...#...##...#...",
         "..#....##....#.."],
        [".....######.....",
         "...##########...",
         "..###.####.###..",
         "..############..",
         ".....#.##.#.....",
         ".....#.##.#.....",
         "....#..##..#....",
         "....#..##..#...."]),
    1: ([".......#........",      # the robot, 11 wide (columns 2..12): arms up / arms down
         "..#..#####..#...",
         "..#..#.#.#..#...",
         "..###########...",
         "....#######.....",
         "....#.###.#.....",
         "....##...##.....",
         "...##.....##...."],
        [".......#........",
         ".....#####......",
         ".....#.#.#......",
         "..###########...",
         "..#.#######.#...",
         "..#.#.###.#.#...",
         "....##...##.....",
         "....#.....#....."]),
    2: (["......####......",      # the visor, 8 wide (columns 4..11): the light in the visor scans
         ".....######.....",
         "....########....",
         "....##.#..##....",
         "....########....",
         "......####......",
         ".....#....#.....",
         "....##....##...."],
        ["......####......",
         ".....######.....",
         "....########....",
         "....##..#.##....",
         "....########....",
         "......####......",
         "......#..#......",
         ".....##..##....."]),
}
INVADER_BOOM = ["...#...#...#....",       # 13 wide (columns 1..13)
                "....#..#..#.....",
                ".#...#...#...#..",
                "..##.......##...",
                ".#...#...#...#..",
                "....#..#..#.....",
                "...#...#...#....",
                "..#.........#..."]
CANNON = [["........#.......",          # 13 wide (columns 2..14), the gun at column 8
           "........#.......",
           ".......###......",
           ".....#######....",
           "..#############.",
           "..#############.",
           "..#.#.#.#.#.#.#.",
           "...###########.."],
          ["....#.....#.....",          # explosion, two frames
           "..#....#.....#..",
           ".....#.##.#.....",
           "...#.#####..#...",
           "..##########.#..",
           ".#.###########..",
           "..#############.",
           ".#.#.#.#.#.#.#.."],
          ["..#....#....#...",
           "......#.#.......",
           "...#.#.....#..#.",
           ".....#.###......",
           ".#..#######.#...",
           "...##########.#.",
           "..#.##########..",
           "#.#.#.#.#.#.#.#."]]
SAUCER = [["..........####..........",  # 16 wide (columns 4..19): a dome, a rim with lights, two thrusters
           "........##.##.##........",
           "......############......",
           "....################....",
           "....#.##.##..##.##.#....",
           "......############......",
           "........#.#..#.#........",
           "........................"],
          ["....#.....#..#.....#....",  # explosion
           ".#....#..#....#..#....#.",
           "...#....########....#...",
           ".....#.##########.#.....",
           "..#...############...#..",
           ".....#.##########.#.....",
           "...#....########....#...",
           ".#....#..#....#..#....#."]]
SHOT_BOOM = ["#..##..#",                 # the player's shot hits something: 8 x 8, centred on the shot
             ".#.##.#.",
             "..####..",
             "########",
             "########",
             "..####..",
             ".#.##.#.",
             "#..##..#"]
BOMB_BOOM = [".#..#...",                 # a bomb hits something: 6 x 8
             "#.##.#..",
             ".####...",
             "######..",
             ".####...",
             "#.##.#..",
             ".#..#...",
             "#....#.."]


def cycle(base, f):
    return [base[(r + f) % len(base)] for r in range(8)]


BOMBS = {  # kind: four frames, 3 x 8
    0: [cycle([".#.", ".##", ".#.", "##."], f) for f in range(4)],              # the twister
    1: [[("###" if r == k else ".#.") for r in range(8)] for k in (0, 2, 4, 6)],  # the plunger: the bar slides
    2: [cycle(["#..", ".#.", "..#", ".#."], f) for f in range(4)],              # the zigzag
}
SHIELD = [".......########.......",   # 22 x 16: a dome with a notch underneath
          ".....############.....",
          "...################...",
          "..##################..",
          ".####################.",
          *(["######################"] * 8),
          "#######........#######",
          "######..........######",
          "######..........######"]


# ---------------------------------------------------------------- checks and conversion
def bits(row):
    """'#' at column c -> bit c (bit 0 = the leftmost column)."""
    return sum(1 << c for c, ch in enumerate(row) if ch == "#")


def check(name, img, w, h):
    assert len(img) == h, f"{name}: {len(img)} rows, want {h}"
    for r in img:
        assert len(r) == w and set(r) <= {".", "#"}, f"{name}: bad row '{r}'"


def extent(imgs):
    cols = [c for img in imgs for r in img for c, ch in enumerate(r) if ch == "#"]
    return min(cols), max(cols)


for k, fr in INVADERS.items():
    for i, img in enumerate(fr):
        check(f"invader {k}.{i}", img, 16, 8)
check("invader boom", INVADER_BOOM, 16, 8)
for i, img in enumerate(CANNON):
    check(f"cannon {i}", img, 16, 8)
for i, img in enumerate(SAUCER):
    check(f"saucer {i}", img, 24, 8)
check("shot boom", SHOT_BOOM, 8, 8)
check("bomb boom", BOMB_BOOM, 8, 8)
for k, fr in BOMBS.items():
    for i, img in enumerate(fr):
        check(f"bomb {k}.{i}", img, 3, 8)
check("shield", SHIELD, 22, 16)
WIDTHS = {0: 12, 1: 11, 2: 8}
for k, fr in INVADERS.items():
    lo, hi = extent(fr)
    assert hi - lo + 1 == WIDTHS[k], f"invader {k} is {hi - lo + 1} wide, the arcade's is {WIDTHS[k]}"
assert extent(CANNON[:1]) == (2, 14) and CANNON[0][0][8] == "#", "the cannon: 13 wide, gun at column 8"
assert extent(SAUCER[:1]) == (4, 19), "the saucer: 16 wide at columns 4..19"
assert extent([BOMB_BOOM])[1] <= 5, "a bomb's explosion is 6 wide"


# ---------------------------------------------------------------- Verilog
def case_lines(entries, sel_bits, width):
    """entries: [(index, row string)] -> case items, the picture row as a comment."""
    digits = (width + 3) // 4
    return "\n".join(f"\t\t{sel_bits}'d{i}: bits = {width}'h{bits(r):0{digits}X};\t// {r}" for i, r in entries)


def module(name, ports, sel, sel_bits, width, entries, comment):
    return f"""// {comment}
module {name} (
{ports}
\toutput\tlogic\t[{width - 1}:0]\tbits
\t);
always_comb
\tcase ({sel})
{case_lines(entries, sel_bits, width)}
\t\tdefault: bits = '0;
\tendcase
endmodule
"""


def build_sv():
    inv = [((k << 4) | (f << 3) | r, img[r]) for k, fr in INVADERS.items() for f, img in enumerate(fr) for r in range(8)]
    inv += [((3 << 4) | (f << 3) | r, INVADER_BOOM[r]) for f in (0, 1) for r in range(8)]
    can = [((i << 3) | r, img[r]) for i, img in enumerate(CANNON) for r in range(8)]
    sau = [((i << 3) | r, img[r]) for i, img in enumerate(SAUCER) for r in range(8)]
    bom = [((k << 5) | (f << 3) | r, img[r]) for k, fr in BOMBS.items() for f, img in enumerate(fr) for r in range(8)]
    bst = [((i << 3) | r, img[r]) for i, img in enumerate((SHOT_BOOM, BOMB_BOOM)) for r in range(8)]
    # the shield by columns (the shield memory keeps one 16-bit word per column; bit r = row r)
    shc = [(c, "".join(SHIELD[r][c] for r in range(16))) for c in range(22)]
    ext = {k: extent(fr) for k, fr in INVADERS.items()}
    out = ["// GENERATED by assets/make_sprites.py: do not edit (edit the art there and run it again).",
           "// Our own pictures at the arcade's sizes. Every table: bit 0 = the leftmost column of the picture.",
           "// ***********************************************", ""]
    out.append(module("inv_invader_rom",
                      "\tinput\twire\t[1:0]\t\tkind,\t\t// 0 = 10 points (bottom rows), 1 = 20, 2 = 30 (top row), 3 = explosion\n"
                      "\tinput\twire\t\t\t\tframe,\n\tinput\twire\t[2:0]\t\trow,",
                      "{kind, frame, row}", 6, 16, inv, "The invaders, 16 x 8 cells: two frames each, and the explosion."))
    out.append(module("inv_cannon_rom",
                      "\tinput\twire\t[1:0]\t\timg,\t\t// 0 = the cannon, 1 and 2 = its explosion\n\tinput\twire\t[2:0]\t\trow,",
                      "{img, row}", 5, 16, can, "The player's cannon, 16 x 8 (13 wide, the gun at column 8), and its explosion."))
    out.append(module("inv_saucer_rom",
                      "\tinput\twire\t\t\t\timg,\t\t// 0 = the saucer, 1 = its explosion\n\tinput\twire\t[2:0]\t\trow,",
                      "{img, row}", 4, 24, sau, "The mystery saucer, 24 x 8 (16 wide at columns 4..19), and its explosion."))
    out.append(module("inv_bomb_rom",
                      "\tinput\twire\t[1:0]\t\tkind,\t\t// 0 twister, 1 plunger, 2 zigzag\n"
                      "\tinput\twire\t[1:0]\t\tframe,\n\tinput\twire\t[2:0]\t\trow,",
                      "{kind, frame, row}", 7, 3, bom, "The invaders' bombs, 3 x 8, four frames each."))
    out.append(module("inv_burst_rom",
                      "\tinput\twire\t\t\t\timg,\t\t// 0 = the shot's explosion (8 wide), 1 = a bomb's explosion (6 wide)\n"
                      "\tinput\twire\t[2:0]\t\trow,",
                      "{img, row}", 4, 8, bst, "Small explosions, 8 x 8: where they show, the shield and the ground lose those pixels."))
    out.append(module("inv_shield_rom", "\tinput\twire\t[4:0]\t\tcol,\t\t// 0..21",
                      "col", 5, 16, shc, "The shield, 22 x 16, by columns: bit r = row r (the comment shows row 0 first)."))
    out.append("""// Where each invader's picture starts and ends in its 16-pixel cell (both frames): the march turns when the
// outermost live invader's picture reaches the edge.
module inv_invader_extent (
\tinput\twire\t[1:0]\t\tkind,
\toutput\tlogic\t[3:0]\t\tfirst,
\toutput\tlogic\t[3:0]\t\tlast
\t);
always_comb
\tcase (kind)
""" + "".join(f"\t\t2'd{k}: begin first = 4'd{lo}; last = 4'd{hi}; end\n" for k, (lo, hi) in ext.items())
               + "\t\tdefault: begin first = 4'd0; last = 4'd15; end\n\tendcase\nendmodule\n")
    return "\n".join(out)


def preview(path):
    from PIL import Image, ImageDraw
    groups = [("invaders", [img for k in (2, 1, 0) for img in INVADERS[k]] + [INVADER_BOOM]),
              ("cannon", CANNON), ("saucer", SAUCER),
              ("bombs", [img for k in (0, 1, 2) for img in BOMBS[k]]), ("bursts", [SHOT_BOOM, BOMB_BOOM]),
              ("shield", [SHIELD])]
    s, gap = 6, 4
    rows = []
    for name, imgs in groups:
        w = sum(len(i[0]) * s + gap * s for i in imgs)
        h = max(len(i) for i in imgs) * s
        rows.append((name, imgs, w, h))
    W = max(r[2] for r in rows) + 100
    H = sum(r[3] + 3 * s for r in rows) + 10
    im = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(im)
    y = 6
    for name, imgs, w, h in rows:
        d.text((4, y), name, fill=(150, 150, 150))
        x = 90
        for img in imgs:
            for r, line in enumerate(img):
                for c, ch in enumerate(line):
                    col = (255, 255, 255) if ch == "#" else (28, 28, 40)
                    d.rectangle([x + c * s, y + r * s, x + c * s + s - 2, y + r * s + s - 2], fill=col)
            x += len(img[0]) * s + gap * s
        y += h + 3 * s
    im.save(path)


if __name__ == "__main__":
    (HERE / "src").mkdir(exist_ok=True)
    (HERE / "src" / "inv_sprites.sv").write_text(build_sv(), encoding="utf-8", newline="\n")
    preview(HERE / "assets" / "sprites_preview.png")
    print("wrote src/inv_sprites.sv and assets/sprites_preview.png")
