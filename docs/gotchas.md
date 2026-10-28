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
    it runs while `quartus_pgm` stays connected or for a limited time (Intel: one hour; fft_lab still ran 32 minutes
    after the disconnect). It makes no `.pof` at all, so it cannot be flashed: `de10.py program` loads the
    time-limited one and `de10.py flash` says why (`use-ip-library`).
14. **`multstyle` ignored.** On a wire inside `generate` it was; put it on a module (examples/12).
15. **Capture looks garbled on Windows.** Pipes from the JTAG terminal turn `\r\n` into `\r\r\n`; parsers skip empty
    lines. Pillow scales PPM (max 15) to 0..255 itself: do not multiply again.
16. **61,000 warnings from one ROM.** A 2-bit ROM filled by `$readmemh`: every hex digit is 4 bits, one warning
    (10230) per line. Any width that is not a multiple of 4 does it (fft_lab's 7-bit ROM: 4,172 lines). Write binary
    and use `$readmemb` (`build-rom`).
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
24. **ModelSim's window opens and does nothing.** A "Welcome to version 10.5b" notice blocks it until someone clicks
    Close (it hides behind other windows). Its "Don't show again" box writes `noWelcomeVersion = 10.5b` under
    `HKCU\Software\Model Technology Incorporated\ModelSim`; `scripts/sim.py --gui` sets it first.
25. **A design 2.7 times bigger than it should be, and no message.** With the MAX 10 default, synthesis builds inferred
    RAMs and ROMs from flip-flops when it guesses M9K blocks are short (resource-aware inference): fft_lab took 19,381
    logic elements instead of 7,183. `scripts/new_project.py` turns it off; the sign in `de10.py report` is a module
    with many registers and 0 memory bits (`make-project`).
26. **A log line that never ends.** `line_printer` counts in 7 bits: after a 127-character line and its CR the count
    wraps to 0, so the line feed never comes and the line repeats forever. Keep log lines to 126 characters
    (`read-screen`).
27. **A board test failed when someone touched the shield.** The turned wheel set the frequency between the USB letters
    and the screen capture. Let the wheel take over only when it really moves, and read the state before and after a
    capture, retrying when they differ (`read-gamepad`).
28. **An overnight board watch saw nothing.** The PC went to sleep and its USB port stopped powering the board. Keep
    the PC awake (never sleep while plugged in) for long watches, or watch by day.
29. **The `.qar` held files the project no longer uses.** Quartus archives every file the last build read, and a
    build that reuses `db/` still lists the old ones after the `.qsf` changed: fft_lab's archive held 32 files from
    examples/11. Delete `db/` and `incremental_db/` (for a OneDrive project, in the local copy) and build again.
    `de10.py build` warns and `de10.py pack` refuses such an archive (`make-project`).
30. **An expected file written with PowerShell's `>` made every line "differ".** PowerShell's `>` writes UTF-16 with
    a byte-order mark (bytes `FF FE`, two bytes per character); a testbench reading it with `$fgets` matches nothing.
    Let the script write its own file (Python, ASCII, LF); never make a data file through a PowerShell redirect.
31. **The frame hash passed, the numbers did not.** The model clamped a bounding box on one side and the RTL on both
    (10-bit unsigned, so it never wraps); both boxes were empty, no pixel changed, and only an arrow that left its
    region showed it. Compare the engine's numbers line by line (`model.py dump` against the testbench's dump) as well
    as the picture: a pixel hash is blind to a difference that is off screen (`make-project`).
32. **`-16'sd32768` gives "constant value overflow" in Quartus 17.1**: write `16'sh8000`. An index made of a
    concatenation (`pm[{2'b00, fax}]`) gives "index expression is not wide enough" even when it covers the array:
    declare the index as a wire of the right width first.
33. **35 lines of blanking after the sync tick, not 45.** `lib/rtl/vga_controller.v` puts the horizontal blanking at
    the end of each line (`column` holds 639 for 161 clocks) and its vertical sync falls 10 lines into the 45-line
    vertical blanking: from the falling edge of `VGA_VS` to the first visible pixel there are 28,000 clocks at
    25 MHz, not 36,000. A per-frame engine started at the sync must finish in that (`build-arcade-game`).
34. **A filter that stops 7 counts short.** The EMA `f += (x - f) >>> 3` (8 fraction bits) rounds every step toward
    minus infinity: coming from below it settles up to 7 LSB under the target, one count low once shifted to the
    display's scale. Round the output (`(f + 8) >>> 4`) and do the same in the model (`read-accelerometer`).
35. **`pip install -r requirements.txt` failed at numpy on Python 3.15.** The pinned numpy had no wheel for that
    Python yet and pip tried to build it from source ("Encountered error while generating package metadata").
    `pip download numpy==<pin> --only-binary=:all:` shows which versions have one; pin a version that covers
    every Python the setup skill installs (`setup-my-computer`).
36. **Icarus 12 rejects SystemVerilog it should take.** Unpacked `localparam` arrays with `'{...}` ("localparam must
    have a value": use a `case` function), `$fgets` into anything but a `reg`, a `string` variable cast to a vector
    at run time (literals are fine), and a part-select after a variable index into a packed 2-D array (copy the
    element to a temporary first).
37. **The LCD shield covers KEY0 and KEY1.** A design that takes its controls from the push keys cannot be operated
    with the shield on; the first Accelerometer Cube image needed KEY1 to calibrate and nobody could press it. A shield
    design takes its buttons from the game pad (`read-gamepad`) and keeps the keys as the bare-board fallback. The same
    hand check found the LED bubble sliding the wrong way: the LEDs are outside the model and the testbenches, so a
    person must watch them once (`read-accelerometer`).
