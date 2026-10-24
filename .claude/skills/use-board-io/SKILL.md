---
name: use-board-io
description: >
  Use the DE10-Lite's own I/O: 10 slide switches, 2 push keys, 10 red LEDs and six 7-segment digits (hex,
  decimal, letters, scrolling text), with debouncing and press detection. Worked example: examples/08_board_io.
  TRIGGER: "switch", "switches", "SW", "KEY", "push button", "LED", "LEDR", "7-segment", "seven segment", "HEX0",
  "display a number", "show text on 7-segment", "counter", "count presses", "debounce".
---

# Switches, keys, LEDs, 7-segment

Proven on the board: `examples/08_board_io`.

| Port | Active | Notes |
|---|---|---|
| `SW[9:0]` | 1 = up | debounce if a flip must count once |
| `KEY[1:0]` | **0 = pressed** | use `~KEY` |
| `LEDR[9:0]` | 1 = on | |
| `HEX0..HEX5 [7:0]` | **0 = lit** | bit 0 = a (top) ... bit 6 = g (middle), bit 7 = dp; HEX0 is the rightmost |

Name the top module's ports exactly like this; `scripts/new_project.py` assigns the pins
(`lib/board/de10_lite_pins.csv`).

## Patterns

* Hex digit: `seven_segment d(.in_hex(v), .out_to_ss(HEX0));` (`--lib sevenseg`).
* Decimal: `bin2bcd #(.BITS(20), .DIGITS(6))` then one `seven_segment` per digit; blank leading zeros
  (`(i > 0 && bcd[23:4*i] == 0) ? 8'hFF : seg`). (`--lib bcd sevenseg`)
* Text: `seg7_char c(.ch("A"), .dp(0), .seg(HEX5));` (`--lib seg7`); scrolling = a message string and a position
  counter (see the example).
* One pulse per press: `debounce` (`--lib debounce`, 10 ms = `STEADY(500_000)` at 50 MHz), then
  `press = down & ~down_d`. Without debounce one press counts 2-5 times.
* Report to the PC: `line_printer` + `jtag_uart` (`--lib print`), `python scripts/de10.py log`.

## Check

* Camera: `python scripts/de10.py cam out.jpg` (the 7-segment reads well even in a dark room).
* Switches and keys need a person: ask for one action at a time ("flip SW0 down") and watch `de10.py log`.
