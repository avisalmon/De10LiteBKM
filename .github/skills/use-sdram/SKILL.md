---
name: use-sdram
description: >
  Use the DE10-Lite's 64 MB SDRAM (IS42S16320, 32M x 16): the lib/rtl/sdram_ctrl.sv controller (50 MHz, DRAM_CLK
  shifted 180 deg, refresh, auto-precharge, read delay 4), its pins and constraints, a full memory test, and the
  bugs to avoid. Verified: all 32M words checked, only the 1 injected error found. Worked example: examples/06_sdram.
  TRIGGER: "SDRAM", "DRAM", "64 MB", "external memory", "big memory", "frame buffer in SDRAM", "store a lot of data",
  "memory controller", "DRAM_CLK", "refresh", "memory test".
---

# Use the SDRAM

Proven on the board: `examples/06_sdram` (all 33,554,432 words; only the deliberately injected error found; 16.3 s per pass).

## Wire it

```verilog
pll_de10 #(.C0_MUL(1), .C0_DIV(1), .C1_MUL(1), .C1_DIV(1), .C1_PHASE("10000")) pll(...);   // c1 = c0 + 180 deg
assign DRAM_CLK = pclk[1];
sdram_ctrl #(.CLK_MHZ(50)) ctrl(.clk(pclk[0]), .reset_n(locked_synced), .rd_delay(3'd4),
  .req(req), .we(we), .addr(q_addr), .wdata(wdata), .ready(ready), .rvalid(rvalid), .rdata(rdata), .init_done(init_done),
  .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CS_N(DRAM_CS_N),
  .DRAM_DQ(DRAM_DQ), .DRAM_LDQM(DRAM_LDQM), .DRAM_RAS_N(DRAM_RAS_N), .DRAM_UDQM(DRAM_UDQM), .DRAM_WE_N(DRAM_WE_N));
```
Top ports: `DRAM_ADDR[12:0] DRAM_BA[1:0] DRAM_CAS_N DRAM_CKE DRAM_CLK DRAM_CS_N DRAM_DQ[15:0] (inout) DRAM_LDQM
DRAM_RAS_N DRAM_UDQM DRAM_WE_N`. `--lib pll sdram`. Copy `examples/06_sdram/src/extra.qsf` (FAST_OUTPUT_REGISTER,
FAST_OUTPUT_ENABLE_REGISTER, FAST_INPUT_REGISTER on the DRAM pins).

## Use it

* `addr` = {bank[1:0], row[12:0], col[9:0]}; one 16-bit word per request; ~9 clocks write, ~13 read at 50 MHz.
* When `ready`: raise `req` one clock with we/addr/wdata **in registers that do not change in that same clock**
  (set a request-address register together with req). Reads return `rvalid` + `rdata`; one request at a time.
* Hold `reset_n` low until the PLL is locked (synchronized).

## Lessons (each was a real failure on the board)

1. A request raised in the clock where a refresh becomes due was swallowed: the controller now latches requests.
2. Request address changing in the same clock as req: every write landed one address late. Use a separate register.
3. Read delay: measured 3 = first that works, use 4. 5-7 also "pass" because the bus keeps its last value: do not
   trust a delay sweep's upper end. The sim model (`lib/sim/sdram_model.sv`) drives data only in its valid window.
4. Start files with `` `default_nettype none `` (end with `` `default_nettype wire ``): a name used before its
   declaration otherwise becomes a silent 1-bit wire.

## Check

`python scripts/sim.py lib/sim/tb_sdram_ctrl.sv` (fails with read delay 3 or 5); on the board, `examples/06_sdram`
(SW0 injects one bad word per pass to prove the checker). Debug with Signal Tap on DRAM_* pins and the controller
state (`scripts/make_stp.py`, `scripts/vcd_dump.py`).

## Faster

Bursts (burst length 8, keep the row open, read pipelining) give 10-20x; or Altera's SDRAM controller IP in Platform
Designer (with a Nios II system).
