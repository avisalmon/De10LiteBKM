---
name: use-dsp-multipliers
description: >
  Use the MAX 10's embedded 18x18 / 9x9 hardware multipliers (DSP) for multiply, multiply-accumulate, filters and
  math; force a multiply into DSP or logic; compare area and Fmax; check results against a Python model.
  Measured: one 18x18 = 2 DSP elements and 0 LEs at ~180 MHz vs 368 LEs at ~90 MHz in logic.
  Worked example: examples/12_dsp_multipliers.
  TRIGGER: "multiplier", "multiply", "DSP", "MAC", "multiply accumulate", "embedded multiplier", "multstyle",
  "FIR", "filter math", "fixed point", "Fmax", "how fast can it run".
---

# Use the DSP multipliers

Proven on the board: `examples/12_dsp_multipliers`.

* `a * b` in Verilog goes to the embedded multipliers by default (10M50: 288 9-bit elements = 144 of 18x18).
* Force a style with an attribute **on a module** (on a wire inside generate it was ignored):
  ```verilog
  (* multstyle = "logic" *) module mult18_logic(input signed [17:0] a, b, output signed [35:0] p); assign p = a * b; endmodule
  ```
* Pipeline: `p <= a * b; acc <= acc + p;` gives one multiply-add per clock at 100+ MHz in DSP.
* Signed math: declare `signed` on every operand and result; mixing signed and unsigned makes the whole
  expression unsigned.

## Measure

* Where a multiply went: `output_files/<rev>.fit.rpt`, "Fitter Resource Utilization by Entity", column "DSP Elements".
* Speed: `<rev>.sta.rpt`, "Slow 1200mV 85C Model Fmax Summary" (give each engine its own PLL clock to get its own Fmax).
* `python scripts/de10.py report <dir>` prints "Embedded Multiplier 9-bit elements".

## Verify

Write the same math in Python (see `sim/mac_reference.py`) and compare the hardware result (printed over USB with
`line_printer`) and the simulation (`sim/tb_mac.sv`) with it. Pseudo-random inputs from an LFSR make the model easy.

## Results crossing clocks

Values read in another clock domain after a synchronized "done" are static: add
`set_false_path -from [get_registers {*engine:*|result[*]}] -to [get_clocks <reader clock>]` in `src/timing.sdc`
(it replaces the default .sdc; keep `create_clock`, `derive_pll_clocks`, `derive_clock_uncertainty`).
