# What we learned, by date

The short version of every lesson added to this guide, newest first. Each line points to where the full rule lives.
They come from real sessions; most of them came from something going wrong.

## 2026-10-29

- **Space Invaders, remade from the arcade's own program, in pure Verilog.** 55 invaders marching one per frame,
  shields bitten pixel by pixel, three kinds of bomb, the saucer, the attract mode with its demo game and the DIP
  switches; no CPU and no frame buffer, 7,170 LEs (14 %). A self-playing testbench (89 checks over 89,600 game
  steps, the rules checked after every step) and ten board presets equal to the simulation: 0 of 76,800 pixels
  differ. [projects/invaders](../projects/invaders/index.html),
  [build-arcade-game](../.claude/skills/build-arcade-game/SKILL.md)
- **A bot that predicts clears the wave.** Shooting the nearest invader let the rack land with 7 alive; playing
  the rack forward and aiming where each invader will be hit 45 of 45 as predicted. [gotcha 51](gotchas.md)
- **Read the code and the emulator's own files, not the comments or a guess.** The demo table uses 10 of its 12
  bytes; the red band was 2 lines too tall until it came from MAME's `invaders.lay`. [gotchas 52, 55](gotchas.md)
- **Bytes wrap in y too.** A low rack's top rows vanished when its reference passed line 255, and the testbench's
  models had to wrap the same way or they would hide it. Preset 7 on the board showed it; with the old
  comparison 1,631 checks of the new section fail. [gotcha 53](gotchas.md)
- **`dist` is a keyword, a monitor read one step late, slack versus Fmax, log redirects, a restored `.qar`, CRLF
  line ends.** [gotchas 49-58](gotchas.md), [make-project](../.claude/skills/make-project/SKILL.md)

## 2026-10-28

- **The shield covers KEY0 and KEY1: a shield design takes its buttons from the game pad.** The cube's KEY1
  calibration could not be pressed; now A calibrates, B restarts the peak, Select forgets, Start spins (+725 LEs, a
  second PLL, the ADC block). [gotcha 48](gotchas.md), [read-accelerometer](../.claude/skills/read-accelerometer/SKILL.md)
- **What only a hand finds: the tilt directions and the LED bubble.** Right edge up is +x and PITCH, near edge up is
  −y and ROLL, HEADING 0 is right; the bubble slid like a ball because +x is the LEDR0 end, and no test covers the
  LEDs. [read-accelerometer](../.claude/skills/read-accelerometer/SKILL.md)
- **Two chats, one board: a lock file is not enough.** The other chat judged a 12-hour-old lock stale and loaded its
  design while the user pressed A for mine; a second time it programmed in the gap between its "board free" and my
  lock. Reprogram and re-read before trusting any hand check, and say which design the FPGA holds in every hand-off.
  [gotcha 34](gotchas.md)
- **The SDRAM streamed at its own speed into six compute units at once.** A 100 MHz burst controller (98 % of the
  bus, 196 MB/s over 64 MB with 0 errors), a fabric of N credit-based read channels and N write-back lanes behind a
  round-robin burst arbiter, int8 matrix-vector units with T-vector weight reuse, a generic register file over JTAG
  and a PC tool: 195 MB/s into six units, ten random jobs up to 512 × 1024 bit-exact against numpy, and every
  matrix of two llama2.c models (stories260K, stories15M) loaded over USB, CRC-checked and run bit-exact: the 15.4 MB
  of stories15M in 83.6 ms, one token's weights at 12 tokens/s from one 16-bit memory. The data-flow layer for an LLM
  on the board.
  [examples/15_sdram_stream_fabric](../examples/15_sdram_stream_fabric/index.html),
  [stream-from-sdram](../.claude/skills/stream-from-sdram/SKILL.md)
- **An arbiter 8 ns late, `always @(*)` that never ran, the six path shapes of 100 MHz on the MAX 10, synchronizers
  that became M9Ks, counters that measure the window not the job, a read window that wraps around the period.**
  [gotchas 42-47](gotchas.md)
- **The SDRAM model is JEDEC-exact now**: it checks every timing parameter and drives data only in the CAS window;
  the bare chip wants `rd_delay` 3, the board 4, and the testbenches say so instead of the old "fails with 3 or 5".
  [use-sdram](../.claude/skills/use-sdram/SKILL.md)

## 2026-10-27

- **Accelerometer Cube: the board's tilt as a shaded 3D cube, the live acceleration as numbers, bars and an arrow.**
  Pure Verilog, no frame buffer: a sequential math engine in the vertical blank (under 950 clocks) and a pixel
  pipeline that draws from its numbers; 13,238 LEs; proven pixel by pixel on the board (8 settings, 0 pixels
  different) against a bit-exact Python model written before the RTL. [projects/accel_cube](../projects/accel_cube/index.html)
- **Math-heavy graphics: write the bit-exact model first, then prove it three ways** (engine numbers against the
  model's dump in a one-second testbench, frame hashes in a slow one, board captures compared pixel by pixel).
  [make-project](../.claude/skills/make-project/SKILL.md)
- **One sensor, two vectors: filter a copy for the orientation, show the raw copy as the numbers**; calibration offsets
  live in the sensor frame, before any remap; an accelerometer has no heading, so no yaw row.
  [read-accelerometer](../.claude/skills/read-accelerometer/SKILL.md)
- **The frame engine has 28,000 clocks after the sync tick, not 36,000.** [gotcha 38](gotchas.md),
  [build-arcade-game](../.claude/skills/build-arcade-game/SKILL.md)
- **A hash that passed while the numbers differed, PowerShell's UTF-16 `>`, Quartus' `-16'sd32768`, a filter 7 counts
  short, a numpy pin with no wheel for the installed Python, Icarus 12 quirks.** [gotchas 35-41](gotchas.md)
- **`requirements.txt` pins must have wheels for Python 3.12 to 3.15**; make the env with `py -3.12 -m venv env`
  when PATH's Python is another version. [setup-my-computer](../.claude/skills/setup-my-computer/SKILL.md)
- **A project can have a tutorial: what to try, what you should see on a real board picture, and why.** Each
  experiment's picture is taken over USB and compared with the model by a script, and every number on the page is
  checked. The optional fourth page of the standard folder, with a template and a test.
  [projects/fft_lab/tutorial.html](../projects/fft_lab/tutorial.html), [make-project](../.claude/skills/make-project/SKILL.md)
- **A file into the 64 MB SDRAM over the USB-Blaster at the cable's limit.** A virtual JTAG loader with a board-side
  CRC32, and a PC script that drives the cable's FTDI driver directly: 64 MB in 112 s (583 KB/s), proven by the
  board in 9.5 s, read back at 476 KB/s, 0 errors twice; quartus_stp as the portable route (547 / 319 KB/s).
  [examples/14_usb_sdram_loader](../examples/14_usb_sdram_loader/index.html),
  [load-sdram-usb](../.claude/skills/load-sdram-usb/SKILL.md)
- **The JTAG server's ceiling, quartus_stp's silent stdout, queued scans, a cable with no framing (one lost byte
  reloaded the flash), two chats on one board.** [gotchas 30-34](gotchas.md)

## 2026-10-26

- **FFT Lab: our FFT beside Altera's, on the same samples.** A wave generator, a scope and two 256-point FFTs with the
  clocks each takes, live on the LCD; proven on the board pixel by pixel (17 settings, 0 pixels different).
  [projects/fft_lab](../projects/fft_lab/index.html)
- **Every project opens with its Resources and stands on its own.** `de10.py report --html` writes the table (area,
  memory, M9K, multipliers, PLLs, clocks with Fmax and slack, and what uses each); tests check both rules, and
  `de10.py pack` refuses an archive with files from outside the project. [make-project](../.claude/skills/make-project/SKILL.md)
- **Encrypted IP in an Icarus testbench: record its answers once in ModelSim, replay them.**
  [compute-fft](../.claude/skills/compute-fft/SKILL.md)
- **Evaluation IP makes no `.pof`**; `de10.py program` and `flash` say what that means. [gotcha 13](gotchas.md)
- **Resource-aware RAM inference, the 126-character log line, the wheel that took over a test, a sleeping PC, a stale
  `.qar`.** [gotchas 25-29](gotchas.md)
- **CI runs on Ubuntu: a test path written as `C:/...` is relative there** and lands inside the checkout. Build it from
  `ROOT` or `Path(ROOT.anchor, ...)`. [make-project](../.claude/skills/make-project/SKILL.md)

## 2026-10-25

- **Course lesson 2: your first simulation.** A buggy door alarm: the chat simulates, the wave view shows the wrong
  moment, the student fixes it in VS Code, then makes the testbench good enough to catch two hidden mistakes, and the
  board. (Built as lesson 3 with ModelSim by hand, reworked under the no-windows rule.) [lesson 2](../lessons/02_first_simulation/index.html)
- **`sim.py --gui` shows only the wave window** and turns off ModelSim's blocking welcome notice (registry value
  `noWelcomeVersion`, found by diffing the registry). [gotcha 24](gotchas.md)
- **ModelSim's window asks "Are you sure you want to finish?" at `$finish`**: testbenches meant for the window end with
  `$stop`; `scripts/sim.py --gui` passes `-onfinish stop`. [gotchas 23](gotchas.md)

## 2026-10-24

- **A soft RISC-V CPU with its own toolchain: RISC-V Tetris.** An RV32I SoC, a Python assembler, C compiler and
  simulator, programs loaded over JTAG in seconds, the RTL proven in lock-step against the simulator (294,803 identical
  steps). The recipe is a skill. [build-soft-cpu](../.claude/skills/build-soft-cpu/SKILL.md)
- **The signed trap of `>>>` in a `?:`, `cell` is reserved, shells share a cwd.** [gotchas 20-22](gotchas.md)
- **Projects have a standard public folder** (overview with block diagram and review log, architecture spec, user guide,
  .qar, no bitstreams) and a portal; a test keeps every project complete. [make-project](../.claude/skills/make-project/SKILL.md)
- **A whole arcade game from scratch: Pac-Man** (maze, 4 ghosts with the arcade AI, sound, levels), tested in
  simulation and on the board over USB. The recipe is a skill. [build-arcade-game](../.claude/skills/build-arcade-game/SKILL.md)
- **Binary files for narrow ROMs, the LCD's white side strips, `inside` is reserved, wide products.**
  [gotchas 16-19](gotchas.md)
- **The guide is born.** DE10-Lite FPGA BKM: the first version. [journey.md](journey.md)
