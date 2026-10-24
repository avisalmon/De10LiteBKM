# Stage 2: lesson list (draft, agreed topics)

Stage 2 is the teaching track: nand2tetris on the DE10-Lite, from gates up to a CPU and a screen, in real
Verilog with the AI as a mentor. Every lesson gets its own HTML tutorial page and a practice of some kind (the
nature of the practice differs per lesson). The DE10-Lite and its shield are assumed throughout. Lessons marked
`+` are board-specific additions to the nand2tetris projects.

Status: lesson 0 built (`lessons/00_setup/`, verified on the board 2026-10-24). The rest is the agreed topic list;
each lesson is discussed with Avi before it is built.

## How a lesson works (agreed 2026-10-24)

- **Two windows side by side.** The HTML page teaches: it has illustrations, explanations, what to do in VS Code,
  and how to tell that you succeeded. VS Code, with Claude Code on this same repo, coaches: it runs the tasks with
  the FPGA, checks the work and gives hints.
- **Self-contained.** Each lesson holds everything it needs: the HTML page with all the explanation, plus all code,
  checkers and prompt instructions used in VS Code.
- **Progress is tracked in localStorage.** The site is static, so it has no server or accounts.
- **No shared template.** Lessons differ in shape and in task. Each lesson is agreed in chat first (its nature,
  its task, how success is checked) and only then built. One lesson at a time.
- **Lesson 0 comes first:** set up the system (Quartus etc.) and confirm everything is ready for learning.
  Stage 1 (the install guide) *is* lesson 0: the full install lives in lesson 0, and the start page's stage 1
  links to it.
- **The chat drives the whole experience.** The student says "teach me" or "what's next" in VS Code. The chat
  knows where they are, opens the lesson page in the browser when it is relevant, and coaches the task.
- **Every lesson page is a slide presentation for self-study.** The slides hold all the information (no speaker
  notes, no video for now). If Avi later records a lesson, it goes on YouTube and gets embedded then.
- **Files:** `lessons/NN_name/` holds `index.html` (the slides), `coach.md` (Claude's instructions for the lesson),
  and the lesson's code and checkers. The student's own work goes in `my_designs/lessons/NN_name/` (git-ignored).
- **Coaching:** one `lesson-coach` skill. "start lesson N" makes it read that lesson's `coach.md`.
- **Progress, two sides:** in VS Code, Claude tracks progress in a file under `my_designs/`. On the page,
  localStorage; the checker prints a short completion code that the student types into the page to mark the step
  done.
- **Simulator: ModelSim** (ModelSim-Intel Starter, installed with Quartus 17.1) for all lesson tests.

## Two paths, one trunk

```
Parts 0-3 (shared trunk: tools, gates, arithmetic, sequential logic, RAM)
        |
        +-- Path A: the CPU (Parts 4-6, nand2tetris projects 4-6)
        |
        +-- Path B: retro game development with sprites (Parts G1-G5)
```

Everyone takes the trunk. After Part 3 the student picks a path (or does both). The split comes just before
the CPU.

# Shared trunk

## Part 0: Tools and the board
Several small lessons, slow pace for high school.
- 0.1 What an FPGA is, and a tour of the DE10-Lite and the shield
- 0.2 First project in Quartus: a switch drives an LED (pins, compile, flash)
- 0.3 First ModelSim simulation: testbench, waveform, pass/fail
- 0.4 Verilog basics: module, ports, wire, assign, instantiation
- 0.5 The AI as a mentor: how to ask for hints, how it checks your work

## Part 1: Boolean logic (nand2tetris project 1)
- 1.1 Boolean algebra and truth tables; Nand as the universal gate
- 1.2 Not, And, Or from Nand (structural Verilog) → switches and LEDs
- 1.3 Xor
- 1.4 Mux and DMux
- 1.5 Buses and multi-bit gates: Not16, And16, Or16, Mux16
- 1.6 Multi-way gates: Or8Way, Mux4Way16, Mux8Way16, DMux4Way, DMux8Way
- 1.7+ The 7-segment display: a decoder module, used from here on to show values

## Part 2: Boolean arithmetic (project 2)
- 2.1 Binary numbers and two's complement
- 2.2 HalfAdder and FullAdder
- 2.3 Add16 and Inc16 → switches in, sum on the 7-segment display
- 2.4+ Counters
- 2.5+ State machines
- 2.6 The Hack ALU: control bits and flags → choose the operation on switches, result on the 7-segment display
- 2.7+ From structural to behavioral Verilog: the same ALU written with + and case

## Part 3: Sequential logic (project 3)
- 3.1 Clocks, time and the DFF; always @(posedge clk)
- 3.2+ The real clock: 50 MHz, clock dividers, and button debouncing → a blinking LED and a step button
- 3.3 Bit and Register → load with a button, show on LEDs
- 3.4 RAM8 and RAM64 from registers
- 3.5 RAM512 to RAM16K, and why real FPGAs use block RAM (M9K)
- 3.6 The program counter (PC) → counting on the 7-segment display

# Path A: the CPU

## Part 4: Machine language (project 4)
- 4.1 The Hack machine: A-, C- and D-registers, memory map
- 4.2 Hack assembly: Mult.asm (runs in the CPU emulator)
- 4.3 Memory-mapped I/O: screen and keyboard; Fill.asm
- 4.4+ How Hack's screen and keyboard map onto the shield's LCD and game pad

## Part 5: Computer architecture (project 5)
- 5.1+ The display controller: a video signal from a memory buffer. Focus on VGA; the screen mirror (to the
  LCD) is given as a ready module.
- 5.2 Memory: RAM, screen and keyboard in one address space → pixels drawn by switches
- 5.3 The CPU: decoding and running instructions
- 5.4+ Debugging the CPU on hardware: single-stepping, registers on the 7-segment display
- 5.5 The computer: CPU + ROM + memory → Fill.asm running on the board, game pad fills the screen
- 5.6+ Loading programs: ROM .mif files, and swapping programs without recompiling

## Part 6: The assembler (project 6)
Software, recommended in Python. Needs a link to a Python course, or assumes prior Python knowledge.
- 6.1 Symbols, parsing, and a two-pass assembler (in Python)
- 6.2 Writing your own program end-to-end: assembly → your assembler → your CPU on the board

## Beyond the course: further investigation (projects 7–12)
The course stops at Part 6 and demos with the assembler. The rest is pointers for the student to explore on
their own; no lessons are planned.
- 7 VM I: stack arithmetic
- 8 VM II: program control
- 9 The Jack language: write a small game
- 10 Compiler I: syntax analysis
- 11 Compiler II: code generation
- 12 The operating system
- Stretch idea: a Jack game running on your own CPU, played with the game pad

# Path B: retro game development (sprites)

Pure hardware games: no CPU, the game is state machines, counters and memories drawing straight to VGA (mirrored
to the LCD by a given module). Builds on the trunk's counters, state machines and block RAM.

## Part G1: Pixels on the screen
- G1.1+ VGA timing: pixel clock, hsync, vsync, x/y counters (the LCD mirror is given as a module)
- G1.2+ Drawing with logic: color bars, a rectangle, a grid from x/y comparisons
- G1.3+ Motion: a frame tick, position registers, a bouncing box

## Part G2: Input and game state
- G2.1+ The game pad: reading buttons, debouncing, edge detection
- G2.2+ Moving a player with the game pad; screen bounds
- G2.3+ The game as a state machine: title, play, game over

## Part G3: Sprites
- G3.1+ Sprites in ROM: picture to .mif, drawing a sprite at (x, y)
- G3.2+ Transparency and color palettes
- G3.3+ Animation: frame sequences, flipping
- G3.4+ Many sprites: priority and layers
- G3.5+ Collision detection: bounding boxes and pixel overlap

## Part G4: The game world
- G4.1+ Tile maps and backgrounds (tile ROM + map RAM)
- G4.2+ Scrolling
- G4.3+ Text and score: font ROM, a BCD score on screen and on the 7-segment display
- G4.4+ Randomness: an LFSR for enemies and surprises

## Part G5: Final project
- G5.1+ Designing a game: rules, state machine, sprite list, memory budget
- G5.2+ Building it (Pong, Breakout or Space Invaders style)
- G5.3+ Polish and showcase: timing and resource reports, playtesting
