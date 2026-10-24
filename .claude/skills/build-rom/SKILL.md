---
name: build-rom
description: >
  Build a ROM in the DE10-Lite's block memory (M9K): inferred with $readmemh or as the altsyncram IP with a .mif;
  fill it from a picture, text or a table; draw ROM pictures on the screen with the right timing; read and rewrite
  it over JTAG while the design runs (In-System Memory Content Editor). Worked example: examples/02_rom.
  TRIGGER: "ROM", "lookup table", "LUT table", "mif", "hex file", "readmemh", "init file", "bitmap", "sprite",
  "image to ROM", "picture on the screen", "altsyncram", "memory content editor", "change memory live".
---

# Build a ROM

Proven on the board: `examples/02_rom` (three ROMs on one screen; picture B rewritten live over USB).

## Choose

| Need | Use |
|---|---|
| Simple table / picture / text, portable code | Inferred ROM (`$readmemh`) |
| Rewrite it from the PC while running, or exact memory settings | `lib/rtl/rom_ip.v` (altsyncram) with `LPM_HINT` |

## Inferred ROM

```verilog
reg [11:0] rom [0:4095];
initial $readmemh("assets/table.hex", rom);      // path from the Quartus project folder
always @(posedge clk) q <= rom[addr];             // MUST be clocked, or it becomes logic, not M9K
```
In a testbench that runs from `sim/`, pass the path as a parameter (`"../assets/table.hex"`).
**Width not a multiple of 4** (a 2-bit picture): write the file in binary, one entry per line (`01`), and load it
with `$readmemb`. Hex into a 2-bit ROM works but Quartus warns (10230, truncated value) once per line: 61,440
warnings for a 240 x 256 picture, burying the real ones.
Quartus rounds the depth up to a power of two (Critical Warning 127005 about depth: harmless).

## IP ROM (editable live)

```verilog
rom_ip #(.WIDTH(12), .DEPTH(4096), .AW(12), .INIT_FILE("assets/pic.mif"),
         .LPM_HINT("ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=IMG")) r (.clk(clk), .address(addr), .q(q));
```
Add `--lib rom` to `scripts/new_project.py`. Files only the PC uses (other .mif) go in `src/extra.qsf` as
`set_global_assignment -name MISC_FILE assets/x.mif` so the .qar carries them.
Live: `cd <project>; quartus_stp -t ../../scripts/mem_edit.tcl list | write NAME file.mif | read NAME out.mif`.
The change is lost at reprogram / power-off.

## Content

* Picture: `python scripts/img2rom.py pic.png assets/pic --size 64x64` -> .hex, .mif, _preview.png (RGB444,
  0x000 = transparent; real black becomes 0x111).
* Text: one ASCII byte per character cell (see `examples/02_rom/assets/make_images.py`, `text_rom()`).
* Tables (sine, notes, coefficients): write the .hex/.mif from Python; .mif needs WIDTH, DEPTH, radix lines.

## Drawing ROM data on the screen

The ROM answers one clock after the address and the screen moves one pixel per clock: address with the next
pixel (`xn = x + 1`) and decide "inside the picture" from the current `x`. Scale by powers of two (address
`{y[7:2], x[7:2]}` for x4) to avoid dividers.

## Check

* `python scripts/sim.py examples/02_rom/sim/tb_rom_screen.sv --modelsim` (altsyncram needs ModelSim's altera_mf).
* On the board: `python scripts/de10.py screen out.png` reads the screen back; compare with the picture.
* Memory use: `python scripts/de10.py report <dir>` ("Total memory bits"); the 10M50 has 1,677,312 bits.
