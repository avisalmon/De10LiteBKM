---
name: read-gamepad
description: >
  Read the LCD shield's game pad (joystick, A, B, Select, Start) and wheel through the MAX 10 ADC, debounce it,
  drive the shield's buzzer and status LED, and report controls to the PC. Includes the verified ADC channel map
  and the fixes the template's ADC needed. Worked example: examples/04_gamepad.
  TRIGGER: "game pad", "gamepad", "joystick", "buttons", "A button", "B button", "select", "start", "wheel", "dial",
  "knob", "potentiometer", "ADC", "analog input", "buzzer", "beep", "status LED", "debounce".
---

# Read the game pad and wheel

Proven on the board: `examples/04_gamepad` (every control on screen + USB event lines with raw ADC values).

## Use it

```verilog
gamepad pad(.clk(clk_50),                      // 50 MHz! the ADC IP makes its 10 MHz ADC clock from it
  .a0(a0), .a1(a1), .a2(a2), .a3(a3), .a4(a4), .wheel(wheel),     // raw 12-bit readings
  .A(A), .B(B), .Select(Select), .Start(Start), .Right(Right), .Left(Left), .Up(Up), .Down(Down));
debounce #(.N(8), .STEADY(500_000)) d(.clk(clk_50), .in({Left,Right,Up,Down,Start,Select,B,A}), .out(btn));
```
`scripts/new_project.py ... --lib gamepad debounce`. Everything that uses the outputs should run at 50 MHz, or
pass them through a synchronizer (debounce does).

## The map (from lib/rtl/gamepad.sv; see examples/04_gamepad/index.html for the board check)

| ADC channel | Controls | Decode (12-bit) | Idle reading on the board |
|---|---|---|---|
| a0 | Left / Right | Left > 0xCFF; Right 0x5FF..0xCFF | 0x002 |
| a1 | Up / Down | Up > 0xCFF; Down 0x5FF..0xCFF | 0x001-0x002 |
| a2 | Select / Start | Select > 0xCFF; Start 0x5FF..0xCFF | 0x007-0x008 |
| a3 | A | pressed < 0x800 | ~0xE47-0xE6E |
| a4 | B | pressed < 0x800 | ~0xE3E-0xE63 |
| a5 | wheel | 0..4095 | jitters ~33 steps at rest |

Two buttons share one channel (different resistor values), so Left+Right (or Up+Down, Select+Start) pressed
together read as one of them. The wheel jitters: compare against a threshold (64) or average.
When the wheel and other controls set the same value, let the wheel take over only when it is really turned: smooth
it, quantize it with hysteresis, and follow it once it is 2 steps from where it was when another control last set the
value; that control takes it back (`projects/fft_lab/src/lab_ctrl.sv`). Without this, a touch on the shield changed a
board test's setting between the USB command and the screen capture (gotcha 27).

## Buzzer and status LED (shield, Arduino header)

`ARDUINO_IO[12]` = buzzer (drive a square wave, e.g. 2 kHz: toggle every 12,500 clocks at 50 MHz).
`ARDUINO_IO[13]` = status LED. The rest of `ARDUINO_IO[11:0]` is the LCD; keep the lib display's assignment.

## The template's ADC needed fixing (done in lib/rtl/adc)

1. `adc_adc_0.v` set `MULTIPLY_BY` twice (typo): the divide never applied, so the ADC ran at clk x 5/10
   (12.5 MHz from 25 MHz), above the MAX 10's 10 MHz ADC clock spec.
2. Its PLL was declared for a 100 MHz input; it is now 50 MHz in, x1/5 = 10 MHz.
3. Altera's `altera_modular_adc_control.sdc` was missing: without it timing showed -868 ns on the ADC data paths.
Symptoms if you use the original template's ADC: Critical Warning 15042 and failing timing on `wire_from_adc_dout`.

## Check

* `python scripts/de10.py log 60` while pressing each control: `PRESS A ch3=02F` / `RELEASE A ch3=E47`.
* `python scripts/de10.py screen` shows every box and raw value.
* Fitter Critical Warning 16248 (VGA_HS / VGA_VS near ADC pins) is the board's layout: nothing to fix.
