# Gotchas: traps we actually hit, numbered

Skills point at these numbers: add new ones at the end, never renumber. Only traps that really happened go here.

1. **`python` opens the Microsoft Store, or prints nothing.** That is Windows' "App execution alias", not Python.
   Install real Python (setup-my-computer) and open a **new** terminal; or call it by full path.
2. **Altera's site answers 403 / downloads stop at "Unconfirmed .crdownload".** Downloads need a MyAltera account
   (email + one-time code) in a normal browser; Edge holds .exe files as "Unconfirmed": check the SHA-1 and rename.
3. **The Quartus installer wants admin rights.** Run it as the user with `__COMPAT_LAYER=RunAsInvoker` and
   `--mode unattended --accept_eula 1` (the USB-Blaster driver must already be installed).
4. **Quartus Pro cannot compile for MAX 10.** Use Quartus Prime Lite 17.1; `QUARTUS_ROOTDIR` may point at Pro, so
   the scripts try `C:\intelFPGA_lite\17.1` first.
5. **The template's game-pad ADC ran at 12.5 MHz (spec 10) and timing showed -868 ns.** A typo in the generated IP,
   a wrong declared input clock and a missing Altera .sdc. Fixed in `lib/rtl/adc`; clock `gamepad` with 50 MHz.
6. **Simulation passes, the board shows an empty memory.** Block RAM was written before the PLL locked. Wait for
   `locked` (synchronized) before writing (examples/03).
7. **A register starts at 0 although the code says `= 80`.** Quartus 17.1 ignores initial values on output ports.
   Set start values in a reset branch (examples/03).
8. **Text sent to the PC is zero bytes.** An unsized number (`m / 10`) inside `{ ... }` made the term 32 bits wide.
   Size every operand inside a concatenation (examples/11).
9. **A name used before its declaration silently became a 1-bit wire.** Start files with `` `default_nettype none ``
   (end with `` `default_nettype wire ``) so it is a compile error (examples/06).
10. **An SPI chip answers 00 / FF.** Data changed on the clock where SCLK rose, and CS rose with the last edge.
    Change MOSI on the falling edge, hold CS half a period (lib/rtl/spi_master.sv, lib/sim/tb_spi_master.sv).
11. **The SDRAM test hung / every write landed one address late.** A one-clock request swallowed by a refresh, and an
    address register that moved on in the request's clock. Latch requests; use a separate request-address register.
12. **Signal Tap "acquired successfully" but the export crashes (`m_trigger_pos`).** The .stp lacks `jtag_chain` /
    `jtag_device` (not `jtag_device_0`); `scripts/make_stp.py` writes them.
13. **A design with an Altera MegaCore (FFT) makes no .sof.** Lite builds `<rev>_time_limited.sof` (OpenCore Plus):
    it runs while `quartus_pgm` stays connected or for a limited time.
14. **`multstyle` ignored.** On a wire inside `generate` it was; put it on a module (examples/12).
15. **Capture looks garbled on Windows.** Pipes from the JTAG terminal turn `\r\n` into `\r\r\n`; parsers skip empty
    lines. Pillow scales PPM (max 15) to 0..255 itself: do not multiply again.
16. **61,000 warnings from one ROM.** A 2-bit ROM filled by `$readmemh`: every hex digit is 4 bits, one warning
    (10230) per line. Write binary and use `$readmemb` (`build-rom`).
17. **Syntax error on a plain wire name.** `inside` is a SystemVerilog keyword (set membership). So are `type`,
    `bit`, `byte`, `int`, `final`, `ref`, `do` and `break`: never use them as signal names in a `.sv` file.
18. **A comparison of two products is wrong for big values.** `(a * b) > (c * d)` is computed at the operands'
    width; assign each product to a wide wire first (`build-arcade-game`).
19. **White bars at the sides of the LCD.** The panel is 800 x 480; the 640 x 480 picture fills the middle and
    the side strips are never written. Not a design bug (`read-screen`).
20. **`>>>` shifted logically.** `alt ? $signed(x) >>> n : x >> n`: the unsigned branch makes the whole `?:` unsigned
    and that context reaches the `>>>`. Put the arithmetic shift on its own `wire signed` (`build-soft-cpu`).
21. **Syntax error on `cell`.** Reserved in Verilog (config blocks), with `design`, `instance`, `library`, `use`.
    Icarus also rejects a declaration inside an unnamed `begin ... end` of a loop: declare at module scope.
22. **Parallel shell calls share the working directory.** Two commands run at once, one `cd` moved the other:
    absolute paths in every command (`make-project`).
23. **ModelSim's window stops with "Are you sure you want to finish?"** at a `$finish`. End a testbench meant for the
    window with `$stop` (it pauses; batch runs still quit), or start vsim with `-onfinish stop` (`scripts/sim.py --gui`
    does). Commands typed in its Transcript are Tcl: forward slashes in paths.
