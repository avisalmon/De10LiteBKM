---
name: flash-design
description: >
  Make a design stay on the DE10-Lite after power-off: write its .pof into the MAX 10's internal configuration flash
  (and verify), versus loading a .sof that lasts until power-off. Worked example: examples/13_flash.
  TRIGGER: "flash", "keep after power off", "survive power cycle", "boot", "start at power up", ".pof", "permanent",
  "burn the design", "program the flash", "CFM", "UFM", "factory image", "replace the demo".
---

# Keep a design after power-off

Proven: `examples/13_flash` (example 04 flashed and verified; the board reloaded it at once), and the whole road with
`projects/accel_cube` (12,513 LEs, 117 M9K): flashed in 15 s, the board reloaded it at once, a `de10.py screen`
capture of the flashed image matched the model pixel for pixel, and after the user unplugged and plugged the cable
the cube came back by itself.

* Every build makes `output_files/<rev>.pof` next to the `.sof` (projects use
  `INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"`, so memory contents are included).
* Write it: `python scripts/de10.py flash <project_dir>` (= `quartus_pgm -m jtag -o "pv;<rev>.pof"`, ~15 s).
  It replaces what the board started with before: say so and ask before flashing someone's board.
* Prove it: ask the person to unplug and replug the USB cable, then check (camera, `de10.py log`, `de10.py screen`).
* `.sof` loads afterwards do not change the flash; the flashed design returns at the next power-up.
* Not built yet: dual images (CONFIG_SEL / Dual Configuration IP), user data in the UFM (On-Chip Flash IP).
