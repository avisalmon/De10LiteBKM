# De10LiteBKM

### Design real hardware on an FPGA, with an AI beside you

<!-- last-updated:start -->
**Last updated 29 October 2026** · 5 new lessons · [See what's new](docs/lessons_log.md)
<!-- last-updated:end -->

**Start page (Hebrew / English): https://avisalmon.github.io/De10LiteBKM/**

---

A BKM (best known method) for the Terasic DE10-Lite FPGA board with its LCD and game-pad shield. Your own Verilog designs running on the DE10-Lite and its LCD / game-pad shield, built, debugged and verified with an AI beside you.

Open this repo in VS Code with **Claude Code** or **GitHub Copilot** (Agent mode), type **"Tell me what to do"**
(or **"תגיד לי מה לעשות"**), and the chat:

* installs what is missing on your computer,
* does the work with you, one step at a time, and stops only for what needs a human,
* teaches as it goes, in Hebrew or English, and resumes where you stopped next time,
* pulls the newest version of this guide at the start of every session.

- **Stage 1: the tools, proven.** Quartus Prime Lite 17.1, ModelSim, the board talking to the PC (lesson 0).
- **Stage 2: the course.** nand2tetris on the FPGA in real Verilog: gates, arithmetic, memory, then a CPU or retro games
  (being written; lesson 0 is ready, the full list is in [docs/stage2_lessons.md](docs/stage2_lessons.md)).
- **Stage 3: build anything.** Twelve verified examples (clocks, ROM, RAM, game pad, screen read-back, SDRAM,
  accelerometer, switches and 7-segment, IP cores, FFT, DSP multipliers, flash) with pages and projects:
  [examples/](examples/index.html). Whole designs built from them, each with an overview, an architecture spec, a user
  guide and the Quartus archive: [projects/](projects/index.html): [Pac-Man](projects/pacman/index.html),
  [RISC-V Tetris](projects/riscv_tetris/index.html) (a soft CPU with its own assembler, C compiler and simulator, Tetris
  in C on it), [FFT Lab](projects/fft_lab/index.html) (our own FFT beside Altera's FFT IP, live on the screen), the
  [Accelerometer Cube](projects/accel_cube/index.html) (the board's tilt as a shaded 3D cube, with the live acceleration as numbers,
  bars and an arrow; no frame buffer, proven pixel by pixel against a bit-exact model) and
  [Space Invaders](projects/invaders/index.html) (the 1978
  arcade game in pure Verilog: no CPU, no frame buffer, the board's screen matched to the simulation pixel for pixel).
- **A toolkit the AI uses every time:** tested Verilog in `lib/`, one-command scripts in `scripts/` (build, program,
  simulate, Signal Tap, read the screen back over USB).

## Start here

1. Install [VS Code](https://code.visualstudio.com), [Git](https://git-scm.com/downloads), and an AI chat in VS Code
   (Claude Code, or GitHub Copilot in Agent mode).
2. In VS Code: **Ctrl+Shift+P** -> **Git: Clone** -> paste `https://github.com/avisalmon/De10LiteBKM.git` -> pick a folder -> **Open**.
3. In the chat, type: `Tell me what to do` / `תגיד לי מה לעשות`

Every click, and what a terminal is if you want one, is in [docs/get_started.md](docs/get_started.md).
The whole road is [docs/journey.md](docs/journey.md).

## What's in the box

```text
index.html             The start page (GitHub Pages), Hebrew + English
CLAUDE.md              The AI's standing rules for this repo
.claude/skills/        The playbooks (source); .github/skills/ is the generated copy for GitHub Copilot
scripts/               doctor (read-only checks), check_updates, sync_skills
projects/              Whole designs (Pac-Man...): index / spec / guide pages, sources, tests, .qar
my_designs/            YOUR work (git-ignored, so updates never touch it)
docs/                  journey, gotchas, what's new, spec, backlog
```

## Honest status

Verified on one DE10-Lite (10M50DAF484C7G) with the LCD / game-pad shield, Windows 11, Quartus Prime Lite 17.1 (October 2026):
examples 01-08 and 10-13 and the Pac-Man, RISC-V Tetris, FFT Lab, Accelerometer Cube and Space Invaders projects run on
the board, each page says exactly what was checked; the Accelerometer Cube, written to the flash, came back by itself
after a power cycle, and its tilt directions and A-button calibration were checked by hand; Space Invaders' ten test
presets matched the simulation pixel for pixel on the board, and again when read back from the flash. Not yet verified:
example 09 (GPIO), the game-pad press map, the games' joystick feel and sound (Space Invaders not yet played by hand,
nor watched starting by itself after a power cycle), FFT Lab's controls by hand, the cube's B / Select / Start and its
LED bubble after the fix, a clean-computer install by a newcomer, macOS / Linux.
Lessons after lesson 0 are being written. Details: [docs/backlog.md](docs/backlog.md).

## License

[MIT](LICENSE).
