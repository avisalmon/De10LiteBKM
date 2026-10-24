---
name: read-accelerometer
description: >
  Read the DE10-Lite's on-board ADXL345 accelerometer (G-sensor) over SPI: X, Y, Z in g, tilt, a bubble level;
  plus the reusable SPI master for other SPI chips. Verified: DEVID E5, |g| = 1.00 at rest.
  Worked example: examples/07_accelerometer.
  TRIGGER: "accelerometer", "G-sensor", "gsensor", "ADXL345", "tilt", "gravity", "bubble level", "orientation",
  "SPI", "SPI master", "sensor over SPI".
---

# Read the accelerometer

Proven on the board: `examples/07_accelerometer`.

```verilog
wire sdio_out, sdio_oe; wire signed [15:0] x, y, z; wire [7:0] devid; wire valid;
assign GSENSOR_SDI = sdio_oe ? sdio_out : 1'bz;
assign GSENSOR_SDO = 1'bz;
adxl345 #(.THREE_WIRE(0)) a(.clk(clk_50), .cs_n(GSENSOR_CS_N), .sclk(GSENSOR_SCLK), .sdio_out(sdio_out),
  .sdio_oe(sdio_oe), .sdio_in(GSENSOR_SDI), .miso(GSENSOR_SDO), .devid(devid), .x(x), .y(y), .z(z), .valid(valid));
```
Ports in the top module: `output GSENSOR_CS_N, GSENSOR_SCLK; inout GSENSOR_SDI, GSENSOR_SDO; input [2:1] GSENSOR_INT`.
`scripts/new_project.py ... --lib accel`.

* Values: signed counts, 3.9 mg each (full resolution, +-2 g): 1 g ~ 256. milli-g = count * 125 / 32.
* 100 samples/s; `valid` pulses with each set. `devid` must be 0xE5: if not, the SPI is wrong.
* Check at rest: sqrt(x^2 + y^2 + z^2) ~ 256.

## SPI for other chips: lib/rtl/spi_master.sv

Mode 3, byte by byte, CS held across bytes with `cs_hold`, 3-wire reads with `rd`. Test:
`python scripts/sim.py lib/sim/tb_spi_master.sv`. Rules it encodes (each was a real bug here):
1. Change MOSI only on the falling edge (mode 3); never on the clock where SCLK rises.
2. Keep CS low half a period after the last rising edge (CS hold time).

## Debug recipe (worked here)

1. `ID=00` / `FF`: Signal Tap the pins: `python scripts/make_stp.py debug.stp MAX10_CLK1_50 "GSENSOR_CS_N:falling" 4096
   GSENSOR_CS_N GSENSOR_SCLK GSENSOR_SDI GSENSOR_SDO`, enable, rebuild, capture, `python scripts/vcd_dump.py`.
2. Read the bits at each rising edge; check MOSI is stable there and CS stays low after the 8th edge.
3. The chip keeps its registers across FPGA reprogramming: write every register you rely on at start.
4. Results go to the PC through `bin2bcd_seq` (a `/ 1000` in logic failed timing by 15 ns at 50 MHz).
