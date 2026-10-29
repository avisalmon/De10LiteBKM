# The journey: from a fresh clone to your own FPGA design running

Who does what in each phase. The chat (the `de10-lite-guide` skill) leads you and records your progress in
`my_designs/PROGRESS.md`, so you can stop any time and say "continue" tomorrow.

## Phase 0 - Get to a working chat (you, once per computer)

The start page and [get_started.md](get_started.md). No terminal experience needed:

- [ ] VS Code installed
- [ ] Git installed
- [ ] An AI chat in VS Code: Claude Code or GitHub Copilot (Agent mode), signed in, answers "hello"
- [ ] This repo copied with **Git: Clone** (clicks only) and opened in VS Code
- [ ] Typed "תגיד לי מה לעשות" / "Tell me what to do"

## Phase 1 - The computer is ready (the chat)

- [ ] Python 3.12, the `env` folder, the tools in requirements.txt (`setup-my-computer`). You click "Yes" on installers.
- [ ] `scripts/doctor.py` shows no FAIL

## Phase 2 - The board answers (you plug it in, the chat checks)

- [ ] Quartus Prime Lite 17.1 + ModelSim + MAX 10 support installed (you: MyAltera sign-in and code; the chat: the rest)
- [ ] `scripts/doctor.py`: the USB-Blaster sees the MAX 10
- [ ] Lesson 0's ready design runs on the board and the chat reads it back (lessons/00_setup)

## Phase 3 - Learn (the course, `lesson-coach`)

- [ ] Lessons one at a time from lessons/: your module passes its ModelSim test, then works on the board

## Phase 4 - Build anything (the chat with you, the domain skills)

The pieces are in [../examples/index.html](../examples/index.html), one verified example per board capability. The
whole designs in [../projects/index.html](../projects/index.html) (Pac-Man, RISC-V Tetris, FFT Lab, the Accelerometer
Cube, Space Invaders) show the road from an idea to a reviewed, tested, documented design (`make-project`).

- [ ] Your own idea runs on the board, built from the examples' pieces, proven with the screen read-back or the log
- [ ] (optional) It is in the flash and starts by itself (`flash-design`)

## You graduated when

- A design of yours runs on the board and the chat proved it (log, screen read-back or camera).
- You changed something in it yourself and it still passed its simulation test.
- You can explain its key part: the clock, the state machine or the memory, in your own words.

## Always

- Every session starts by pulling updates to this guide (automatic).
- Your work is in `my_designs/`, which updates never touch.
