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
      failed). Flashed and proven after a power cycle (2026-10-27); since 2026-10-29 the flash holds Space Invaders, so
      program the cube first.
- [ ] FFT Lab, by a person: the wheel, joystick, A / B / Start / Select and the keys by hand, the buzzer, the LEDs and the
      7-segment. On the board: how long the evaluation IP runs once the programmer disconnects (Intel says one hour; it
      still ran after 32 minutes), and whether KEY0 or `D` brings an expired IP back.
- [ ] Space Invaders, by a person: the game pad (joystick feel, A / B fire, Select coin, Start), the buzzer's
      sounds, a wave played by hand, the LEDs and the 7-segment, KEY0 / KEY1 on a board without the shield, the
      DIP switches (SW0..SW2) other than all down, a photo of the board (the webcam failed), and that it starts by
      itself after a power cycle (written to the flash and read back pixel for pixel on 2026-10-29).
- [ ] Space Invaders, not built by choice: two players (the arcade's cocktail mode), the high score kept in the
      user flash.
- [ ] RISC-V Tetris, not built by choice: interrupts and a timer, the M extension on the MAX 10 multipliers, structs /
      typedef in the compiler, a bigger RAM without the debug capture.
- [ ] Pac-Man and RISC-V Tetris, made before resource-aware RAM inference was turned off (gotcha 25): the USB link's
      512-byte buffer is built from flip-flops (4,820 and 5,419 logic elements instead of about 130; their Resources
      sections say so). Regenerate their project files (`scripts/new_project.py`), rebuild, update the Resources
      section (`de10.py report --html`), pack, re-check on the board.
- [ ] Example 07 / 10 in 3-wire SPI mode (the driver supports it, not tested).
- [ ] Example 14 beyond the cable: a USB 2.0 high-speed FIFO (FT232H / FT2232H, 245 synchronous mode) on the GPIO
      header with the same `sdram_loader` behind a byte port, for 20-30 MB/s. Also: the direct route is Windows-only
      (D2XX DLL shipped with Quartus); the quartus_stp route is untested on macOS / Linux.
- [ ] Extras proposed, not built: Nios II with C (the RISC-V project is the free alternative), sound / melodies, sprites
      from images, the MAX 10 temperature sensor, UART / I2C masters, a fundamentals page (reset, clock crossing, timing).
- [ ] The course: lessons after lesson 0 (see stage2_lessons.md).
