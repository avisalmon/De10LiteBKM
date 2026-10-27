# What we learned, by date

The short version of every lesson added to this guide, newest first. Each line points to where the full rule lives.
They come from real sessions; most of them came from something going wrong.

## 2026-10-27

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
