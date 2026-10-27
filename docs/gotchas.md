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
    with a "board free" message, kept them apart (`load-sdram-usb`).
35. **An arbiter failed timing by 8 ns at 100 MHz.** Three things in one clock: a credit subtraction chain
    (`DEPTH - wlevel - inflight >= len`), the round-robin search, and `addr[win*25 +: 25]` with a variable `win`,
    which Quartus built as a multiplier plus a 290-node barrel mux. Register each requester's "ready" bit and its
    credit the clock before, choose with a registered round-robin, and select the winner's fields with an N-way
    equality loop (`if (sel_id == k) sel_addr = ch_addr[k]`) so every part-select is constant (`stream_fabric`).
36. **A simulation deadlocked with X on a register that had `= 0` written on it.** An `always @(*)` block only runs when
    an input changes; its inputs (`rr_req`, `sel_id`) stayed 0 from time 0, so its outputs (`win_v`, `sel_addr`) stayed X
    forever and the first clock after start copied X into `sel_v`, then into every request register. Write
    combinational blocks as `always_comb` (it runs once at time 0) and expect this whenever a combinational output is X
    while all its inputs are known. Also: `scripts/sim.py` captures output, so a hung testbench shows nothing until its
    timeout (40 ms of simulated time was 30 minutes of CPU). To watch a run, call `vvp -n x.vvp` yourself.
37. **Closing 100 MHz on the MAX 10 is a list of six shapes, not a mystery.** The stream fabric went from -8.4 ns to
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