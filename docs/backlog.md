# Backlog

- [ ] Walk the newcomer's road end to end on a clean Windows computer (no Python, no Git): record every snag.
- [ ] Test the GitHub Copilot path (Agent mode) end to end, not only Claude Code.
- [ ] macOS: someone with a Mac runs the journey and reports.
- [ ] Example 09: the 40-pin GPIO header, with a loopback wire.
- [ ] Example 04: press every game-pad control once and confirm the ADC map (`scripts/de10.py log 60`).
- [ ] Examples 03 and 06 with SW0 down: errors must stay 0 on the board.
- [ ] Example 13: unplug and replug the USB cable; the flashed game-pad tester must start by itself.
- [ ] Example 08 count mode (SW9 down, KEY0 / KEY1) by hand.
- [ ] Projects, by a person: Pac-Man and RISC-V Tetris with the joystick (feel, auto-repeat), the sounds, the pace.
- [ ] Accelerometer Cube, by a person: press B, Select and Start on the game pad (A and the tilt directions were checked
      on 2026-10-28), watch the LED bubble slide toward the lifted edge after the fix, a photo of the board (the webcam
      failed). It is in the flash now, in place of Pac-Man; the power cycle brought it back (2026-10-27).
- [ ] FFT Lab, by a person: the wheel, joystick, A / B / Start / Select and the keys by hand, the buzzer, the LEDs and the
      7-segment. On the board: how long the evaluation IP runs once the programmer disconnects (Intel says one hour; it
      still ran after 32 minutes), and whether KEY0 or `D` brings an expired IP back.
- [ ] RISC-V Tetris, not built by choice: interrupts and a timer, the M extension on the MAX 10 multipliers, structs /
      typedef in the compiler, a bigger RAM without the debug capture.
- [ ] Pac-Man and RISC-V Tetris, made before two rules: regenerate their project files (`scripts/new_project.py` turns
      resource-aware RAM inference off, gotcha 25), rebuild, put the Resources section first on each overview
      (`de10.py report --html`), pack, re-check on the board, then take them off `RESOURCES_LATER` in
      `tests/test_projects.py`.
- [ ] Example 07 / 10 in 3-wire SPI mode (the driver supports it, not tested).
- [ ] Extras proposed, not built: Nios II with C (the RISC-V project is the free alternative), sound / melodies, sprites
      from images, the MAX 10 temperature sensor, UART / I2C masters, a fundamentals page (reset, clock crossing, timing).
- [ ] The course: lessons after lesson 0 (see stage2_lessons.md).
