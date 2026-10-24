---
name: use-ip-library
description: >
  Bring Altera/Intel IP into a DE10-Lite project without the GUI: megafunctions instantiated directly (altpll,
  altsyncram, dcfifo, lpm_divide, altsqrt, lpm_mult...), and parameterized cores generated with ip-generate
  (FFT II, FIR, CORDIC, NCO...); find parameter names; licensing (OpenCore Plus time-limited .sof in Lite).
  Worked examples: examples/11_fft (ip-generate), examples/01_pll_clocks and 02_rom (direct megafunctions).
  TRIGGER: "IP", "IP core", "IP catalog", "megafunction", "MegaWizard", "Platform Designer", "Qsys", "ip-generate",
  "qsys-generate", "FIFO IP", "divider IP", "FFT IP", "FIR IP", "OpenCore Plus", "time limited", "license IP".
---

# Use IP from the library

## 1. Megafunctions: instantiate directly (no generation, no license)

They are built into Quartus (`altera_mf`, `lpm`). Instantiate the module with `defparam`/`#()` exactly as the wizard
would write it. Ready wrappers in `lib/rtl`: `pll_de10.v` (altpll), `rom_ip.v` (altsyncram ROM).
Find a megafunction's ports and parameters: `C:\intelFPGA_lite\17.1\quartus\eda\sim_lib\altera_mf.v` (search
`module dcfifo`, `module altsqrt` ...) or the Quartus help ("Intel FPGA Integer Arithmetic IP Cores User Guide").
ModelSim simulates them with `-L altera_mf_ver -L lpm_ver` (`scripts/sim.py --modelsim` adds these).

## 2. Parameterized cores: ip-generate

```
set QUARTUS_ROOTDIR=C:/intelFPGA_lite/17.1/quartus
ip-generate --remove-qsys-generate-warning --project-directory=. --output-directory=<name> --file-set=QUARTUS_SYNTH
  --report-file=qip:<name>/<name>.qip --component-name=<core> --output-name=<name>
  --system-info=DEVICE_FAMILY="MAX 10" --system-info=DEVICE=10M50DAF484C7G --component-parameter=<p>=<v> ...
```
(`C:\intelFPGA_lite\17.1\quartus\sopc_builder\bin\ip-generate.exe`). Core names = folder names under
`C:\intelFPGA_lite\17.1\ip\altera\...` (e.g. `dsp\altera_fft_ii` -> `altera_fft_ii`); parameter names = the
`add_parameter` lines in `<core>_hw.tcl`. Save the command as a script next to the IP (see
`examples/11_fft/ip/generate_fft_ip.py`) so the IP can be regenerated. Add it: `src/extra.qsf` with
`set_global_assignment -name QIP_FILE ip/<name>/<name>.qip`, re-run `scripts/new_project.py`.
Read the Error lines: they say which parameter combination is not allowed.

## 3. Licensing in Quartus Prime Lite

* Megafunctions and basic IP: free.
* MegaCore IP (FFT, FIR II, NCO, ...): **OpenCore Plus evaluation**. The build makes `<rev>_time_limited.sof` (no
  `<rev>.sof`), and `quartus_pgm` keeps running after programming: the design works while it stays connected
  ("tethered"), or for a limited time untethered. `scripts/de10.py program <dir>` finds the time-limited .sof.
* Check before choosing an IP: if the result must run stand-alone or from flash, write your own or use a free core.

## 4. Measure what you got

Per-module area: `output_files/<rev>.fit.rpt`, "Fitter Resource Utilization by Entity" (Logic Cells, Memory Bits,
M9Ks, DSP Elements). Speed: Fmax summary in `<rev>.sta.rpt`. Correctness: compare with a Python model over USB
(examples/11_fft: `sim/fft_data.py check`).
