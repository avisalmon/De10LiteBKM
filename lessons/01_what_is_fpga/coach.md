# Lesson 1 coach: what an FPGA is, and a tour of your board

You coach lesson 1 from VS Code; the slides (`lessons/01_what_is_fpga/index.html`) teach. Follow the `lesson-coach`
skill for how to behave. This file is what is specific to lesson 1.

**Goal:** the student can say what an FPGA is (and how it differs from a CPU), what a LUT is, and knows every input
on the board and the shield. **No design work in this lesson**: they write their first Verilog in lesson 4. Two checks:
`hunt`, `quiz`.

## Steps

1. **Start.** `python scripts/lesson.py start 1` (copies the hunt's sources to `my_designs/lessons/01_what_is_fpga/`).
   Open slide 1 (`python scripts/lesson.py open 1 1`): "Read slides 1 to 8, then come back and tell me." Answer
   questions about the slides in short plain words; don't re-teach them in the chat.
2. **Build the hunt while they read.** It takes about 2 minutes, so start it right away:
   * `python scripts/new_project.py my_designs/lessons/01_what_is_fpga/hunt hunt_top --lib display gamepad debounce debug cdc mux print font seg7`
   * `python scripts/de10.py build my_designs/lessons/01_what_is_fpga/hunt`
   This is the course's design, not theirs. If they ask, say: "the 13 challenges are a state machine; you'll build
   one yourself in Part 2."
3. **The hunt.** When they reach slide 9, `python scripts/de10.py program my_designs/lessons/01_what_is_fpga/hunt`,
   then start listening to the board in the background: `python scripts/de10.py log 900` (one line per step:
   `HUNT STEP 05 OK`, and `HUNT COMPLETE` at the end). Tell them: "Follow the screen. Tell me if you get stuck."
   * Stuck on a step: give the hint for that step from the table below, one hint at a time. Never do it for them.
   * When the log shows `HUNT COMPLETE` (and the screen says ALL DONE): `python scripts/lesson.py check 1 hunt`.
     No log line? Read the screen (`python scripts/de10.py screen`) or ask what the 7-segment digits say (`donE`).
4. **The quiz** (slide 12). Ask one question at a time and wait. Accept their own words; what matters is the idea.
   A wrong or empty answer gets a hint (point at the slide), then they try again. Never give the answer first.

   | Question | The idea a good answer has |
   |---|---|
   | What is the difference between a CPU and an FPGA? | A CPU runs instructions one after another; an FPGA becomes the circuit itself, everything working at the same time. |
   | What is a LUT, and how can one LUT be an AND gate or an XOR gate? | A tiny memory holding a truth table: the inputs choose a row, the stored bit is the output. Change the stored bits and the same LUT is a different gate. |
   | Why is your design gone when the board loses power, and what does that mean for you? | The FPGA keeps its configuration in memory that needs power (SRAM), so it is loaded again after power-up; we program it again with one command (a design can also be stored in the chip's flash, later in the course). |

   When all three are answered well: `python scripts/lesson.py check 1 quiz`.
5. **Done.** `python scripts/lesson.py done 1`. Open slide 13, they type the code. Update `my_designs/PROGRESS.md`.
   Close with one sentence on what made it work (the board read every input you touched, and the chip did it all
   at once) and what comes next (lesson 2: their first simulation, a circuit tested before it goes to the board).

## Hints for the hunt (one at a time)

| Step | Hint 1 | Hint 2 |
|---|---|---|
| 1 all down | The switches are the 10 small levers along the board's front edge. | Down = toward you. The red boxes on the screen show which are still up. |
| 2 SW0 | SW0 is the rightmost switch. | Only SW0 up; all the others down. |
| 3 SW9 | SW9 is the leftmost. | Put SW0 back down. |
| 4 five | In binary, 5 = 4 + 1: SW2 is worth 4, SW0 is worth 1. | SW2 and SW0 up, all others down. |
| 5-6 keys | KEY0 and KEY1 are the two push buttons on the board itself (not the shield); the names are printed next to them. | Hold it a moment; a quick tap is ignored on purpose. |
| 7-8 joystick | The joystick is on the shield. | Push and hold for a moment. |
| 9-11 A, B, Start | They are the buttons on the shield. | Hold each for a moment; B also makes the buzzer sound. |
| 12-13 wheel | The wheel is the big metal knob on the shield. | Watch the WHEEL bar on the screen while you turn it. |

## Traps seen

* (none yet)
