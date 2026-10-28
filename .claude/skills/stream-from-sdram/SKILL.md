---
name: stream-from-sdram
description: >
  Stream data out of the DE10-Lite's 64 MB SDRAM at full speed into several compute units at once, and write
  their results back: lib/rtl/sdram_burst_ctrl.sv (100 MHz, bursts of 1..1024 words, 98 % of the bus),
  lib/rtl/stream_fabric.sv (N credit-based FIFO read channels, N write-back lanes, round-robin arbiter,
  example 14's loader), lib/rtl/matvec_unit.sv (int8 y = W.x, group scales, T vectors at once)
  and scripts/fabric_ctl.py (bench, jobs) over lib/rtl/jtag_regs.sv. Measured: 196 MB/s over 64 MB,
  195 MB/s into six units, bit-exact jobs up to 512x1024. The data-flow layer for an LLM on the board.
  Worked example: examples/15_sdram_stream_fabric.
  TRIGGER: "stream from SDRAM", "stream the weights", "burst SDRAM", "SDRAM bandwidth", "100 MHz SDRAM",
  "fan-out FIFO", "multi FIFO", "feed compute units", "systolic", "matvec", "matrix vector", "int8",
  "quantized weights", "LLM on the FPGA", "transformer", "write back results", "jtag_regs",
  "register map over JTAG", "memtest", "read window", "phase sweep", "rd_delay".
---

# Stream from the SDRAM

Proven on the board: `examples/15_sdram_stream_fabric`. The SDRAM (IS42S16320, 16 bits wide) at 100 MHz moves one
word per clock = 200 MB/s at most; this stack gets **196 MB/s** in the memory test (0 errors over 64 MB), **195 MB/s**
into six units streaming at once (98 % of the bus), and runs int8 matrix-vector jobs bit-exact against numpy
(ten random jobs up to 512 x 1024; `job --model` runs every matrix of a llama2.c model the same way). The
single-word controller (`use-sdram`, example 06) does
10 MB/s; the loader (`load-sdram-usb`, example 14) fills the memory at 0.58 MB/s and rides along unchanged.

## The parts (lib/rtl)

| Module | What it is | Size (final build) |
|---|---|---|
| `sdram_burst_ctrl` | one command = one burst of 1..1024 words at one address (BL 1, a column command every clock, CL 3, auto-precharge at the end, refresh pauses a burst and resumes it); `rd_delay` register for the read capture | 326 LEs |
| `async_fifo` | dual-clock show-ahead FIFO in M9K, Gray pointers, `level`; Icarus simulates it (no `dcfifo`) | 1 M9K per 1024 x 16 |
| `stream_fabric` | N read channels (BASE, LEN, BURST, loop, abort; a DEPTH-word FIFO each, credit rule: ask only when the whole burst fits), N write-back lanes (32-bit results -> 16-bit words from WB_BASE on, flushed by the unit or the host), the legacy single-word port served first, a 3-step registered round-robin arbiter, the counters (BUSY, TOTAL, REFRESHES, BURSTS, per channel FETCHED / WAITED) | 5,795 LEs, 18 M9K for N = 6 |
| `matvec_unit` | y = W.x for int8 W in groups of 32 with an int16 scale (the 17th word), T vectors of x at once (weight reuse), 48-bit accumulate, SHIFT, saturate to int32; a register block per unit + a broadcast block | 3,370 LEs, 8 M9K, 20 mults each |
| `jtag_regs` | a virtual JTAG node that is a 16-bit-address / 32-bit-data register bus: ADDR, WRITE (auto-increment), READ, ID; `scripts/jtag_regs.py` drives it (batched scans, ~2 ms a transaction) | 197 LEs |
| `pll_phase_step` | moves one PLL output's phase at run time (MAX 10 dynamic phase shift): the read-window sweep without rebuilding | 157 LEs |
| `sdram_memtest` | pattern writer / checker on the burst controller: the board proof and the window sweep (`memtest/` sub-project) | |

`scripts/new_project.py <dir> <top> --lib dps fabric matvec jtagregs usbloader` pulls them in; `src/extra.qsf` of
example 15 has the SDRAM pins. Everything runs on one 100 MHz clock from `pll_de10_dps` (c0 logic, c1 `DRAM_CLK`
at phase 6875 ps); `AUTO_SHIFT_REGISTER_RECOGNITION OFF` is in every generated `.qsf` (gotcha 38).

## Wire it

```verilog
sdram_burst_ctrl #(.CLK_MHZ(100)) ctrl(.clk(clk), .rst_n(rst_n), .rd_delay(rd_delay),
  .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
  .wdata(wd), .wvalid(wvalid), .wready(wready), .rdata(rd), .rvalid(rvalid), .done(done),
  .init_done(init_done), .stat_busy(stat_busy), .stat_refresh(stat_refresh), .DRAM_*(DRAM_*));
stream_fabric #(.N(6), .DEPTH(1024), .LANE_DEPTH(64), .MAX_BURST(1024)) fabric(
  .clk(clk), .rst_n(rst_n), .uclk(clk), .urst_n(rst_n),          // uclk: the units' clock, any clock later
  /* the controller's ports above */ .rd_delay(rd_delay),
  .lg_req(lg_req), ... .lg_rdata(lg_rdata),                       // sdram_ctrl's contract: the loader plugs in
  .ch_dout(ch_dout), .ch_valid(ch_valid), .ch_rd_en(ch_rd_en),    // N x 16 bits, show-ahead, to the units
  .wb_data(wb_data), .wb_valid(wb_valid), .wb_ready(wb_ready), .wb_flush(wb_flush),   // N x 32 bits back
  .reg_addr(addr), .reg_wdata(wdata), .reg_we(we), .reg_rdata(fab_rdata), .unit_ctrl(unit_ctrl),
  .any_running(), .lanes_busy(), .legacy_busy(), .idle(idle), .fault(fault));
matvec_unit #(.T_MAX(8), .REG_BASE(16'h0100 + 16 * u), .REG_BCAST(16'h01F0)) mv(.clk(clk), .rst_n(rst_n),
  .s_data(ch_dout[u*16 +: 16]), .s_valid(ch_valid[u]), .s_rd_en(ch_rd_en[u]),
  .wb_data(wb_data[u*32 +: 32]), .wb_valid(wb_valid[u]), .wb_ready(wb_ready[u]), .wb_flush(wb_flush[u]),
  .g_ctrl(unit_ctrl), .reg_addr(addr), .reg_wdata(wdata), .reg_we(we), .reg_rdata(unit_rdata[u]), .busy(), .rows_out());
jtag_regs #(.INSTANCE(1), .ID(32'h5F15_0001)) regs(.clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata), .we(we),
  .rdata(top_rdata | fab_rdata | unit_rdata[0] | ...), .busy());  // every block answers 0 when not addressed
```
Your own consumer instead of `matvec_unit`: pop `ch_dout` with `ch_rd_en` while `ch_valid` (the next word is already
there), push 32-bit results with `wb_valid`/`wb_ready`, pulse `wb_flush` after the last one. Register map:
`examples/15_sdram_stream_fabric/spec.html` section 5 and the comment at the top of `scripts/fabric_ctl.py`.

## Use it (the PC side)

```
python scripts/fabric_ctl.py info                       ID 5F150001, units, clock, phase, every block's state
python scripts/fabric_ctl.py bench                      units streaming at once: MB/s, bus %, per unit and burst size
python scripts/fabric_ctl.py job --random 512x1024 --t 8 --units 6     load a random int8 W, run, compare bit-exact
python scripts/fabric_ctl.py job --model stories15M --load             every matrix of a model (tools/export_q8.py)
python scripts/fabric_ctl.py job --model stories15M --matrix cls --t 8  one matrix, 8 vectors (prefill)
python scripts/fabric_ctl.py stats [--clear] / phase [+N|-N|goto P|reset] / delay [D] / reset / load FILE
python scripts/sdram_memtest.py sweep | run             the memtest/ build: the read-window map; 64 MB at --pattern P --burst N
```
`tools/export_q8.py stories15M` downloads a llama2.c checkpoint and writes `logs/models/stories15M.q8.bin` (every
matrix on a row boundary, 17 words per group of 32) plus a JSON map; `tools/ref_matvec.py` is the bit-exact reference
and the quantizer. From Python: `with fabric_ctl.Board() as b: r = b.job(fabric_ctl.JobSpec(...))`.

## Lessons (each cost real time; gotchas 35-40)

1. **Credits, not backpressure.** A channel asks for a burst only when its FIFO can take all of it; a granted burst
   never stalls, the controller needs no `rready`, and the bus stays 98 % busy with six consumers of any speed.
   Continuity needs `DEPTH >= 2 x BURST`.
2. **One 16-bit SDRAM is 200 MB/s whatever N is.** More units add independence (each starves or stalls on its own)
   and places for compute, not bandwidth. The throughput lever is weight reuse: T vectors per pass (T = 8 makes a
   32-token prefill 8 x cheaper than one token at a time).
3. **100 MHz on the MAX 10 is a list of path shapes** (gotchas 35, 37): registered credits and round-robin, M9K outputs
   registered, a register after every DSP multiply and before every dynamic array select, one-hot selects, a head
   register on a show-ahead FIFO that feeds a bus. -8.4 ns -> +0.4 ns in three builds; `report_timing -npaths 200`
   grouped by shape, not by path.
4. **The read window: sweep it, read it circularly, centre it** (gotcha 40). `pll_phase_step` moves `DRAM_CLK` in 208 ps
   steps while the memtest runs; `rd_delay` 4 passes over 33 of 48 steps, 3 over the 8 next to them; the compiled phase
   is the centre of the 4-window (6875 ps, +-3.3 ns). The JEDEC-exact model wants 3 for the bare chip: the testbenches
   use 3, the RTL defaults to 4.
5. **Quartus puts shift registers in M9Ks** (gotcha 38): synchronizers and flag pipelines became `altshift_taps`
   blocks, merged across six instances. The sign: a module with "N bits (1 M9K)" and no memory. Off globally now.
6. **Counters measure the window, not the job** (gotcha 39): read them first after the idle poll, compute rates from
   the units' own busy counters; on a job of a few thousand clocks the bus is busy longer than the units.
7. **`always @(*)` with constant inputs never runs in Icarus** (gotcha 36): X forever. `always_comb`.
8. **The refresh is 1.6 % of the bus** (every 7.5 us, 12 clocks each), pausing bursts: a 1024-word burst is longer
   than the interval, so forbidding refresh inside bursts would cost more than pausing.

## Check

`python -m pytest tests/test_stream_fabric.py` (seven testbenches: `tb_sdram_burst_ctrl`, `tb_async_fifo`,
`tb_stream_fabric` N = 1/2/6/14, `tb_matvec_unit`, `tb_sdram_memtest`, `tb_pll_phase_step`, `tb_jtag_regs`; the
exporter / reference round trip; the tools; the packaging). On the board: `fabric_ctl.py info`, then
`job --random 64x64 --t 2 --units 2` (bit-exact in a second), then `bench`.

## Faster, bigger

The memory is the limit: 200 MB/s, 98 % used. Next steps when a design needs more: bank pipelining in the controller
(ACT the next burst's bank during the current one: ~99 % at every length, gains 1-2 %); 133 MHz (the -7 part's CL 3
limit is 143 MHz; the PLL gives 50 x 8/3; the window shrinks); weight reuse (T); keeping the KV cache or the small
matrices in M9K (182 blocks, 1.6 Mbit); and a second memory on the GPIO header. Softmax, RMSNorm, attention and the
tokenizer are the LLM project's work, on top of this layer.
