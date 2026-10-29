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
30. **Every Quartus tool moves data at the JTAG server's pace, not the cable's.** quartus_stp, the memory content
    editor and the JTAG UART all go through jtagserver: ~525-547 KB/s written and ~350 read however long the scan.
    The USB-Blaster itself does 583 KB/s; only driving its FTDI driver directly (`scripts/usb_blaster.py`) gets
    there, and reads stay USB-bus bound at 470-540 KB/s (`load-sdram-usb`).
31. **quartus_stp said nothing until it quit.** When its stdout is a pipe the tool holds every `puts` back until exit
    (Tcl `flush` changes nothing), while it reads stdin at once. A script that must answer live writes its answers
    to a file opened with `-buffering none` and the PC side tails it (`scripts/sdram_load.tcl`). It also drops a
    `cr_ie_info.json` into the current folder: delete it before committing (`load-sdram-usb`).
32. **A write that "took 0 seconds".** `device_dr_shift -no_captured_dr_value` only queues the scan; nothing has
    reached the board until a captured scan follows. End every timed or ordered sequence with one, such as a
    STATUS read (`load-sdram-usb`).
33. **One lost byte reprogrammed the board.** The USB-Blaster protocol has no framing: when the stream slips, data
    bytes become commands. Once an unguarded sweep stalled the cable's answer FIFO (FT_IO_ERROR) and pulsed the
    FPGA's nCONFIG, which reloaded the flash. Check for unasked-for bytes after every block and at every scan end,
    reset the TAP and stop on the first one, and have the board CRC what it holds (`load-sdram-usb`).
34. **Two chats, one board.** Both programmed the board and each spoiled the other's test. A lock file
    (`%LOCALAPPDATA%\de10lite\board.lock`: who, what, since), checked before every board command, deleted when done
    with a "board free" message, kept them apart (`load-sdram-usb`). It does not protect a hand check: a chat that
    judged an old lock stale, or programmed in the gap between its "board free" and the other's lock, swapped the
    design while the user pressed a button for the other. Program your design and read it back (`de10.py send r`)
    right before asking a person to act, and say which design the FPGA holds in every hand-off.
35. **An expected file written with PowerShell's `>` made every line "differ".** PowerShell's `>` writes UTF-16 with
    a byte-order mark (bytes `FF FE`, two bytes per character); a testbench reading it with `$fgets` matches nothing.
    Let the script write its own file (Python, ASCII, LF); never make a data file through a PowerShell redirect.
36. **The frame hash passed, the numbers did not.** The model clamped a bounding box on one side and the RTL on both
    (10-bit unsigned, so it never wraps); both boxes were empty, no pixel changed, and only an arrow that left its
    region showed it. Compare the engine's numbers line by line (`model.py dump` against the testbench's dump) as well
    as the picture: a pixel hash is blind to a difference that is off screen (`make-project`).
37. **`-16'sd32768` gives "constant value overflow" in Quartus 17.1**: write `16'sh8000`. An index made of a
    concatenation (`pm[{2'b00, fax}]`) gives "index expression is not wide enough" even when it covers the array:
    declare the index as a wire of the right width first.
38. **35 lines of blanking after the sync tick, not 45.** `lib/rtl/vga_controller.v` puts the horizontal blanking at
    the end of each line (`column` holds 639 for 161 clocks) and its vertical sync falls 10 lines into the 45-line
    vertical blanking: from the falling edge of `VGA_VS` to the first visible pixel there are 28,000 clocks at
    25 MHz, not 36,000. A per-frame engine started at the sync must finish in that (`build-arcade-game`).
39. **A filter that stops 7 counts short.** The EMA `f += (x - f) >>> 3` (8 fraction bits) rounds every step toward
    minus infinity: coming from below it settles up to 7 LSB under the target, one count low once shifted to the
    display's scale. Round the output (`(f + 8) >>> 4`) and do the same in the model (`read-accelerometer`).
40. **`pip install -r requirements.txt` failed at numpy on Python 3.15.** The pinned numpy had no wheel for that
    Python yet and pip tried to build it from source ("Encountered error while generating package metadata").
    `pip download numpy==<pin> --only-binary=:all:` shows which versions have one; pin a version that covers
    every Python the setup skill installs (`setup-my-computer`).
41. **Icarus 12 rejects SystemVerilog it should take.** Unpacked `localparam` arrays with `'{...}` ("localparam must
    have a value": use a `case` function), `$fgets` into anything but a `reg`, a `string` variable cast to a vector
    at run time (literals are fine), and a part-select after a variable index into a packed 2-D array (copy the
    element to a temporary first).
42. **An arbiter failed timing by 8 ns at 100 MHz.** Three things in one clock: a credit subtraction chain
    (`DEPTH - wlevel - inflight >= len`), the round-robin search, and `addr[win*25 +: 25]` with a variable `win`,
    which Quartus built as a multiplier plus a 290-node barrel mux. Register each requester's "ready" bit and its
    credit the clock before, choose with a registered round-robin, and select the winner's fields with an N-way
    equality loop (`if (sel_id == k) sel_addr = ch_addr[k]`) so every part-select is constant (`stream_fabric`).
43. **A simulation deadlocked with X on a register that had `= 0` written on it.** An `always @(*)` block only runs when
    an input changes; its inputs (`rr_req`, `sel_id`) stayed 0 from time 0, so its outputs (`win_v`, `sel_addr`) stayed X
    forever and the first clock after start copied X into `sel_v`, then into every request register. Write
    combinational blocks as `always_comb` (it runs once at time 0) and expect this whenever a combinational output is X
    while all its inputs are known. Also: `scripts/sim.py` captures output, so a hung testbench shows nothing until its
    timeout (40 ms of simulated time was 30 minutes of CPU). To watch a run, call `vvp -n x.vvp` yourself.
44. **Closing 100 MHz on the MAX 10 is a list of six shapes, not a mystery.** The stream fabric went from -8.4 ns to
    +0.3 ns by finding each repeated path shape in `report_timing -npaths 200 -detail summary` (strip the `[n]`,
    `__n` and `~n` from the From/To names and count what is left) and fixing the shape, not the path:
    (1) `q <= mem[addr]` with a combinational address is an M9K with its output *unregistered* (data appears 2.5 ns
    after the edge); anything after it in the same clock is expensive: add `q2 <= q` so the M9K's own output
    register is used. (2) A 9x9 DSP multiply costs ~3.5 ns: registered inputs, a register right after. (3) A dynamic
    array select feeding a multiply or a wide add (`ghold[i] * s`, `acc[j] + prod`) must be split: register the
    selected operand first (reading the accumulator one clock ahead is safe when consecutive steps use distinct
    indices). (4) A register-bus decode must not fan out to hundreds of synchronous clears: register the pulse once.
    (5) `for ... if (sel == k) out = in[k]` is N mux levels; a one-hot registered select with AND-OR is 2 LUT levels
    for N <= 8. (6) A show-ahead FIFO's M9K output must not feed a bus: a one-entry head register refills with no
    bubble, because the FIFO shows the next entry the clock after a pop. Each fix cost a pipeline clock, the
    testbenches re-proved the hazards, and the count of path families went 6 -> 0 in three builds (`stream_fabric`,
    `matvec_unit`).
45. **Six synchronizers became one M9K.** Quartus' Auto Shift Register Replacement (on by default) turns any chain of
    three or more equal flip-flops with no taps (a CDC synchronizer, a pipeline's flag delay line) into an
    `altshift_taps` in an M9K, and merges chains of the same shape across module instances into one block: the six
    lanes' flush synchronizers became one M9K, and the six units' 12-bit x 3 flag pipelines another (36 bits in a
    9,216-bit block). The sign in `de10.py report`: a module with "54 bits (1 M9K)" and no memory, or one instance of
    six with 9 M9K where its siblings have 8; the proof is `altshift_taps:<reg>_rtl_0` in the fit report's RAM
    Summary. A synchronizer in a RAM is wrong twice: a block wasted and the M9K's clock-to-output added to a CDC
    path. `scripts/new_project.py` now writes `AUTO_SHIFT_REGISTER_RECOGNITION OFF` into every `.qsf`; for one
    register: `(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)` (`stream_fabric`, `matvec_unit`).
46. **The counter window is not the job.** BUSY / TOTAL / REFRESHES count from CLEAR until the PC reads them, and
    one JTAG register transaction is about 2 ms: reading 23 registers before the counters made a 10 ms job show 62 ms
    of refreshes. Read the counters first, right after the "idle" poll, and compute rates from the units' own busy
    counters, which start and stop with the work. On a job of a few thousand clocks the bus is busy longer than the
    units (the FIFO fill before, the write-back tail after): ratios mean something from a millisecond up
    (`fabric_ctl.py`).
47. **The read window has two edges and wraps around.** Sweeping DRAM_CLK's phase over one period (48 steps of 208 ps
    at 100 MHz) gives a pass window for `rd_delay` 4 that wrapped past the period's end (+17..+49 = -31..+1 for a
    compiled phase of 0), so "first fail .. last fail" read linearly put the centre on the wrong side. Treat the sweep
    as circular (`sdram_memtest.py windows()`), and expect the `rd_delay` 3 window right next to it: the same word
    caught one clock earlier. The compiled phase goes to the centre of the `rd_delay` 4 window (6875 ps): +-16 steps
    = +-3.3 ns of margin on both sides. The JEDEC-exact model says `rd_delay` 3 for the bare chip; the board says 4:
    the pin, trace and I/O register path adds about a clock's worth at 100 MHz (`use-sdram`).
48. **The LCD shield covers KEY0 and KEY1.** A design that takes its controls from the push keys cannot be operated
    with the shield on; the first Accelerometer Cube image needed KEY1 to calibrate and nobody could press it. A shield
    design takes its buttons from the game pad (`read-gamepad`) and keeps the keys as the bare-board fallback. The same
    hand check found the LED bubble sliding the wrong way: the LEDs are outside the model and the testbenches, so a
    person must watch them once (`read-accelerometer`).
49. **Three kinds of syntax error from one name: `dist`.** `dist` is a SystemVerilog keyword (weighted random
    distributions), like `inside` (17). Icarus said "syntax error ... I give up on this function definition" at the
    function that declared it, "Malformed conditional expression" at each use, then a cascade of "Invalid module
    instantiation"; none of it named the word. Hit twice in one session (renamed `dd`), and `cell` (21) once more.
    When sane code turns into a pile of syntax errors, suspect a name first (`build-arcade-game`).
50. **The test read the monitor's counts one step late.** The testbench's monitor (`always @(negedge clk)`) counts a
    game step when `busy` falls, on the same clock edge where the test's `step()` task returns, and Icarus ran the
    test first: "wave: cleared once" failed on a wave that had been cleared, and every count the monitor keeps (waves,
    saucers, points, the longest step) was one step stale. Two processes woken by one edge run in no defined order.
    End `step()` with `#1;` so the monitor has run before the test reads (`build-arcade-game`).
51. **A bot that shoots the nearest invader lets the rack land.** The first wave-clearing bot hit 38 of the 45
    invaders left, with 62 shots in 3,332 steps, but the rack stayed wide, kept reaching the edges and dropping,
    faster as it thinned, and landed with 7 alive. The bot that clears the wave predicts: before every step it plays
    the rack forward exactly as `inv_logic` will (one invader moved per step, the bump, the drop, the 16-step freeze
    while an invader explodes, the shot in flight), finds where a shot fired d steps from now meets the lowest invader
    of each column (through a shield gap, past the bombs), takes the edge columns first (a narrower rack drops less
    often) and fires when d is 0: 45 of 45 hits as predicted, with 45 shots and 1 drop in 1,766 steps
    (`build-arcade-game`).
52. **The red band was 2 lines too tall.** The overlay's red band was guessed (lines 32..63) instead of read from
    MAME's layout file `invaders.lay`: red 32..61, green 184..239, and green under the spare ships (columns 16..133,
    line 240 down). Its numbers are the arcade's own lines: MAME's portrait frame is 224 x 260 because its driver
    (`screen_update_mw8080bw`) shifts each line out 4 pixels late, which leaves the arcade's lines at 0..255 and 4
    blank ones after. Only the cannon's shot crosses lines 62..63, so no screen capture showed the error. Read the
    emulator's layout file and driver source, map them through its frame, and name them on the page
    (`build-arcade-game`).
53. **Invaders vanished when the rack's reference passed line 255.** The arcade's coordinates are bytes and wrap. The
    rack's reference is its bottom row's line even when that row is gone, so with the bottom three rows shot away a
    low rack's reference passes line 255 (wrapping to 0) while rows 3 and 4 are still on the screen. `inv_rack_pixel`
    wrapped x but compared y as signed 10-bit numbers, so rows 3 and 4 vanished from the picture, from the shot's hit
    test and from the edge test, and the rack walked sideways for ever. Fix: y modulo 256 too (`u = ry + 8'd7 - py`),
    and the same in the testbench's models (`lit_at`, `play_rack`, `shot_masks`), or they hide the bug. Preset 7 on
    the board showed it; section 15 of the testbench now plays that case, and with the old comparison 1,631 of its
    checks fail (`build-arcade-game`).
54. **A clock's slack was 3 ns smaller than its Fmax promised.** Invaders' 100 MHz clock (`lcd_ctrl`) has an Fmax of
    332.45 MHz, 7.0 ns to spare in its 10 ns period, yet a setup slack of 4.111 ns. Fmax counts only paths that start
    and end on that clock; slack also counts paths from the PLL's other clocks, which get only the time to the nearest
    edge (25 -> 100 MHz: 10 ns). The worst was in the library: `vga_controller`'s `column` (25 MHz) into `lcd_ctrl`'s
    state (100 MHz), 5.651 ns of data delay. And the slowest 25 MHz paths ended in `debug_link`'s capture RAM, not in
    the game. Before writing about margins, name the worst paths of each clock:
    `report_timing -setup -npaths 8 -detail summary -to_clock [get_clocks {...}]` in a `quartus_sta -t` script
    (`make-project`).
55. **The demo player used 10 of its 12 moves.** The commented disassembly suggests a 12-entry demo table, and the RTL
    first cycled all 12. The code itself (`$1652..$1667`, PlrFireOrDemo) increments the pointer before reading and
    resets it from `$7E` to `$74`, so only the 10 bytes `$1F74..$1F7D` are ever used. Fix: a 10-entry `demo_dir`, the
    pointer wrapping after 9. Read the code, not the comments (`build-arcade-game`).
56. **Four small traps between a program and its log.** (1) A shell redirect opens its file before the program starts:
    `de10.py build ... > logs\build.log` failed at once with a PermissionError, because `de10.py` writes that file
    itself; give the console its own file (`logs\build_console.log`). (2) A redirect also empties its file: a log
    copied aside after the next run had started was saved empty. Copy first, then rerun. (3) A message passed to a
    testbench task as `input [8*72-1:0] what` keeps only its last 72 characters (a string is a number; a narrower port
    keeps the low bytes): two messages lost their start. (4) Counting passed checks with a case-insensitive `ok:` also
    counted `sim.py`'s "OK: testbench passed": count `^ok:` case-sensitively (`make-project`).
57. **A restored `.qar` would not compile: exit code 3 in 2 seconds.** `quartus_sh --restore x.qar -output out` keeps
    the repo's layout (`out\projects\<name>\...`, `out\lib\rtl\...`), so there is no project in `out\` itself. Run
    `quartus_sh --flow compile <name>` in `out\projects\<name>` (`make-project`).
58. **An edit script found no CRLF in a CRLF file.** With `* text=auto` and `core.autocrlf=true`, the working tree's
    text files end their lines with CRLF, but Python's `Path.read_text()` and text-mode `open()` turn them into LF, so
    a script's assert on `"\r\n"` failed. Open with `newline=""` to see and keep the real line ends, and write back
    the same way.
