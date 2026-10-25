# What we learned, by date

The short version of every lesson added to this guide, newest first. Each line points to where the full rule lives.
They come from real sessions; most of them came from something going wrong.

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
