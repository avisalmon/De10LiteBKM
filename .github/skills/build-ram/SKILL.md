---
name: build-ram
description: >
  Build RAM in the DE10-Lite's block memory (M9K): single-port, simple dual-port with two clocks (frame buffers,
  clock crossing), true dual-port; size it, read it with the right latency, test it on the board with a self-test,
  and avoid the start-up traps. Worked example: examples/03_ram (self-test + 160x120 paint frame buffer).
  TRIGGER: "RAM", "memory", "block RAM", "M9K", "dual port", "frame buffer", "framebuffer", "scratch memory",
  "store data", "memory test", "BIST", "two clocks memory", "FIFO memory".
---

# Build RAM

Proven on the board: `examples/03_ram`.

## Pick a template (lib/rtl, add `--lib ram` to scripts/new_project.py)

| Module | Ports | For |
|---|---|---|
| `ram_sp` | one address, write+read, one clock | scratch RAM, CPU data memory |
| `ram_dp` | write port (wr_clk) + read port (rd_clk) | frame buffer, FIFO, clock crossing |
| `ram_tdp` | two read/write ports, two clocks | memory shared by two engines |

Parameters: `WIDTH`, `AW` (address bits), `DEPTH` (words actually needed; saves M9K), `INIT_FILE` (optional
$readmemh file). All reads answer one clock after the address. For pictures, fetch the next pixel (`x + 1`).
Capacity: 1,677,312 bits on the 10M50 (182 M9K blocks of 9 Kbit). Check with `scripts/de10.py report`.

## Rules that cost a build each to learn

1. **Do not write block RAM before the PLL is locked.** Gate the writer with `locked`, synchronized into the
   writer's clock (`reg [1:0] s; always @(posedge clk) s <= {s[0], locked};`). Symptom without it: simulation
   passes, the board shows an empty memory.
2. **Quartus 17.1 silently ignores initial values on output ports** (`output reg [7:0] cx = 80` starts at 0).
   Set start values in a reset / not-ready branch. Internal `reg x = value;` initial values work.
3. A dual-clock RAM read of an address being written at that moment returns old or new data; design for it.
4. Quartus warns "Inferred dual-clock RAM ... read-during-write behavior undefined" (276027): expected for ram_dp.

## Test RAM

* On the board: a self-test like `examples/03_ram/src/ram_bist.sv` (LFSR pattern, write all, read back, count),
  with an inject switch to prove the checker sees errors. ~3,000 passes/s for 8K x 16 at 50 MHz.
* Without the board: `python scripts/sim.py examples/03_ram/sim/tb_ram_bist.sv` and `.../tb_paint_fb.sv`.
* Look inside a running design: name it for the In-System Memory Content Editor (use `lib/rtl/rom_ip.v`-style
  altsyncram with `ENABLE_RUNTIME_MOD=YES`) or tap its ports with Signal Tap (`scripts/make_stp.py`).

## Clocks

Writer and reader may run on different clocks (example 03: paint at 50 MHz, screen at 25 MHz, same PLL).
Control signals crossing between them (buttons, cursor) need 2-flop synchronizers; the picture itself crosses
through the RAM.
