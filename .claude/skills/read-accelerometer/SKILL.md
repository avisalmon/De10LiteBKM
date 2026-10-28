---
name: read-accelerometer
description: >
  Read the DE10-Lite's on-board ADXL345 accelerometer (G-sensor) over SPI: X, Y, Z in g, tilt, a bubble level;
  plus the reusable SPI master for other SPI chips. Verified: DEVID E5, |g| = 1.00 at rest.
  Worked example: examples/07_accelerometer; a whole design on it (tilting 3D cube, two vectors, calibration,
  filter, angles): projects/accel_cube.
  TRIGGER: "accelerometer", "G-sensor", "gsensor", "ADXL345", "tilt", "gravity", "bubble level", "orientation",
  "SPI", "SPI master", "sensor over SPI", "pitch", "roll", "calibrate the sensor", "3D cube".
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

## Showing the reading: what worked in projects/accel_cube

A tilting 3D cube, the live acceleration as text, bars and an arrow, all from this sensor; proven pixel by pixel
against a bit-exact Python model. The parts worth reusing:

* **Two vectors from one sensor.** Orientation wants a steady gravity vector; the live number wants the real,
  unfiltered acceleration. Filter one copy for the cube (`g`), show the raw copy as the numbers (`a`); a shake
  then moves the arrow and the bars, not the cube.
* **The filter.** An EMA with 8 fraction bits, `f += ((raw << 8) - f) >>> 3` in 24 bits, settles in about 90
  samples (0.9 s at 100 Hz). Round the output (`(f + 8) >>> 4`): the shift alone stops 7 LSB short (gotcha 39).
* **Calibration = offsets in the sensor frame.** On the A button (KEY1 on a bare board), store `ox, oy, oz <- fx, fy, fz - 1 g` (the filtered
  values, after the filter and before any axis remap) and subtract them from both vectors from then on; a second
  letter clears them. Offsets taken after a remap would turn with the board's heading.
* **Which way is X on the board.** The sensor's axes are fixed on the PCB; a `HEADING` parameter (0, 90, 180, 270)
  remaps `(x, y)` once, on the live data only, so presets and tests never depend on it. Decide it by tilting the
  board while a `de10.py send r` loop prints the vector. Checked by hand with the LCD readable (the shield's screen
  towards you): **x runs left to right, y near to far; lifting the right edge gives +x, lifting the near edge gives
  −y**, and HEADING 0 makes the cube rise on the same side as the board. The bubble LED: +x is the LEDR0 end, so a
  bubble that slides toward the lifted edge needs an index that runs *against* x (`(4096 − gx) * 5 >> 12`); the
  LEDs are outside the model, so only a person catches a reversed one.
* **The shield hides KEY0 and KEY1.** With the LCD shield on, the two push keys cannot be pressed: take the controls
  from the shield's game pad (`read-gamepad`: `gamepad` at 50 MHz, `debounce` 5 ms, two flops into the pixel clock)
  and keep the keys only as the bare-board fallback (`key = {Start, Select, KEY1 | A, KEY0 | B}`). The pad costs about
  600 LEs, a second PLL and the ADC block; VGA_HS / VGA_VS next to the ADC pins give the expected Critical Warning 16248.
* **Angles from g, no yaw.** Pitch and roll come from `atan2` of the gravity components (one CORDIC, Q14 trig,
  16-bit binary angles); hold the last angles when |g| < 0.25 g or the roll's divisor is small (free fall, a shake).
  An accelerometer cannot give the heading: do not put a YAW row on the screen.
* **Clock crossing.** The reader runs at 50 MHz, the display at 25 MHz: cross `valid` as a toggle and sample the
  three values after it (they are held until the next sample, 10 ms later).
* **Testing without hands.** The testbench feeds samples straight into the filter (120 of them), presses the keys,
  reads the report line; the board check sends test vectors over USB (`0`..`7`) so the picture does not depend on
  how the board lies. Only the directions (does the cube tilt like the board, does the bubble slide the right way)
  and the buttons under a finger need a person: with the shield on, that person has the game pad, not the keys.
