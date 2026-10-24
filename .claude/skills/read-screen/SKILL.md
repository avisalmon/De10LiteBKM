---
name: read-screen
description: >
  Read the DE10-Lite's screen picture (LCD/VGA) back to the PC over the USB-Blaster cable, and test graphics
  automatically: capture, render the expected frame in simulation, compare pixel by pixel. Also the USB text link
  (JTAG UART) for logs and commands. Verified: 0 of 76,800 pixels differ. Worked example: examples/05_screen_readback.
  TRIGGER: "screenshot", "read the screen", "capture the screen", "what is on the screen", "check the display",
  "test the graphics", "screen test", "JTAG UART", "talk to the board", "USB serial", "log from the FPGA", "printf".
---

# Read the screen (and talk over USB)

Proven on the board: `examples/05_screen_readback`.

## Add it to a screen design (lib display chain)

```verilog
debug_link #(.STEP(2)) debug(.clk(clk_25), .resetN(1'b1), .pxl_x(pxl_x), .pxl_y(pxl_y), .rgb({VGA_R, VGA_G, VGA_B}),
  .buttons(8'h00), .key_pressed(2'b00), .SW(10'h000), .wheel(12'h000), .frame(16'h0000),
  .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .rx_data(rx_data), .rx_valid(rx_valid), .beep());
jtag_uart uart(.clk(clk_25), .resetN(1'b1), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
  .rx_data(rx_data), .rx_valid(rx_valid));
```
`--lib display debug`. STEP 2 = 320x240 (56 % of M9K; every dot of 2x/4x text), STEP 4 = 160x120 (14 %).
Other text senders share the link through `tx_mux` (whole lines) and `byte_cdc` (other clock).

## Use it

* `python scripts/de10.py screen out.png` (~6 s). `python scripts/de10.py send "?"` = status line.
* Your own commands: watch `rx_valid`/`rx_data` in the top (debug_link reacts only to ? F B).
* Log lines: `line_printer` (`--lib print`), then `python scripts/de10.py log 10`.

## Test graphics automatically

1. Testbench renders the expected frame at even pixels (example: `sim/tb_frame.sv`, parameters via `-D`).
2. Board: send commands, `de10.screen(png)`.
3. `python scripts/screen_check.py capture.png expected.png --diff diff.png` -> "0 of 76800 pixels differ".
Template: `examples/05_screen_readback/test_screen.py`.

## Notes

* 17.1 has no juart-terminal; scripts fall back to nios2-terminal (Windows pipes give \r\r\n: parsers drop empty lines).
* Pillow scales a PPM (maxval 15) to 0..255 by itself; frame dumps (hex) need x17.
* Read values on screen are latched once per frame (vsync) or digits tear.
