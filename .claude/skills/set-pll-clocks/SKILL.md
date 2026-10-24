---
name: set-pll-clocks
description: >
  Make the clocks a DE10-Lite design needs with the MAX 10 PLL (any f = 50 MHz x MUL / DIV, phase shift, locked,
  reset), constrain them for timing, cross between clock domains safely, and measure every clock on the board to
  prove it. Worked example: examples/01_pll_clocks.
  TRIGGER: "PLL", "clock", "clocks", "frequency", "25 MHz", "100 MHz", "phase shift", "clock domain",
  "derive_pll_clocks", "altpll", "locked", "measure frequency", "clock crossing", "CDC".
---

# Set the PLL and clocks

Proven on the board: `examples/01_pll_clocks` (page `index.html`, `pll_clocks.qar`).

## The board's clocks

| Port | Pin | Frequency |
|---|---|---|
| `MAX10_CLK1_50` | P11 | 50 MHz (use this as the PLL input) |
| `MAX10_CLK2_50` | N14 | 50 MHz, a second oscillator |
| `ADC_CLK_10` | N5 | 10 MHz (meant for the ADC) |

The MAX 10 (10M50) has 4 PLLs, 5 outputs each.

## Make clocks

Use the library PLL `lib/rtl/pll_de10.v` (a direct `altpll` instance; no IP wizard, no .qip):

```verilog
wire [4:0] pll_clk; wire locked;
pll_de10 #(.C0_MUL(1), .C0_DIV(2),                     // 25 MHz
           .C1_MUL(2), .C1_DIV(1),                     // 100 MHz
           .C2_MUL(1), .C2_DIV(1), .C2_PHASE("5000"))  // 50 MHz, 5 ns late
  pll (.areset(1'b0), .inclk0(MAX10_CLK1_50), .clk(pll_clk), .locked(locked));
```

* f_out = 50 MHz x MUL / DIV. Unused outputs: leave their defaults; Quartus removes what nothing uses.
* Phase in picoseconds as a string. The VCO step is VCO-period/8 (208 ps at 600 MHz); the report shows the value used.
* Add `--lib pll` to `scripts/new_project.py`. The generated `.sdc` already has `create_clock` for the oscillator and
  `derive_pll_clocks`, so all PLL outputs are timed.
* Hold logic in reset until `locked` is high (`wire rst_n = locked;` and synchronize it into each clock domain).

## Check what Quartus built

`output_files/<rev>.fit.rpt`, section **PLL Usage**: frequency, phase and counter per output; **PLL Summary**: VCO
(M, N). If a ratio is impossible the build fails with an error naming the clock: pick another MUL/DIV or a second PLL.
Run `python scripts/de10.py report <dir>`: timing must say `OK (no negative slack)`.

## Cross clock domains safely

* 1-bit signal: two flip-flops in the destination clock (`reg [1:0] s; always @(posedge dst) s <= {s[0], x};`).
* Multi-bit value: never sample it while it changes. Either hold it still and pass a 1-bit "ready" through a
  synchronizer (the pattern in `lib/rtl/freq_counter.sv`), or use a dual-clock FIFO (`dcfifo`).
* Never use a clock as data or gate a clock with logic; use the PLL's `clkena` or a clock-enable signal.

## Prove it on the board

`lib/rtl/freq_counter.sv` measures any clock against 50 MHz (1 ms gate, result in kHz). Example 01 prints all clocks:

```
python scripts/de10.py build examples/01_pll_clocks
python scripts/de10.py program examples/01_pll_clocks
python scripts/de10.py log 3      # c0 PLL 50*1/2 = 025000 kHz ...
```

Expected: 25000, 100000, 033333/033334, 10000, 50000, and 50000 / 10000 / 50000 for the oscillators.
Unit test without the board: `python scripts/sim.py examples/01_pll_clocks/sim/tb_freq_counter.sv` -> PASS.

## Gotchas

1. Quartus 17.1 needs a type on array constants: `localparam logic [27:0] X [0:4] = '{...}`, not `localparam [27:0] X [0:4]`.
2. A gate-and-count frequency counter must count the edge that opens the gate (the first version read 24999 for 25000).
3. PLL clocks stop while `areset` is high: anything clocked by them freezes (example 01: hold KEY0).
