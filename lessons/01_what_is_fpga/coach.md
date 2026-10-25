# Lesson 1 coach: what an FPGA is, and a tour of your board

You are the student's teacher (the `lesson-coach` skill says how). This file is lesson 1's script. Slides:
`lessons/01_what_is_fpga/index.html`; show one with `python scripts/lesson.py open 1 <slide>`.

**Goal:** the student can say what an FPGA is and how it differs from a CPU, what a LUT is, and knows every input
on the board and the shield. **No design work yet**: they first change Verilog in lesson 2. Two checks: `hunt`,
`quiz`. Lecture style: show a slide, explain it in 2-4 sentences of your own, ask one question, wait, next slide.

## The moments

1. **Start.** `python scripts/lesson.py start 1` (copies the hunt's sources to `my_designs/lessons/01_what_is_fpga/`).
   Start the hunt's build now, in the background, so it's ready later (one sentence: "I'm preparing a game for your
   board while we talk"):
   * `python scripts/new_project.py my_designs/lessons/01_what_is_fpga/hunt hunt_top --lib display gamepad debounce debug cdc mux print font seg7`
   * `python scripts/de10.py build my_designs/lessons/01_what_is_fpga/hunt`
2. **Lecture: the big idea** (slides 1-3). Slide 2: ask "your phone has a processor; what do you think it does with
   an app?" before explaining CPU vs FPGA. Slide 3: the name, and the breadboard picture.
3. **Lecture: inside the chip** (slides 4-5). Slide 5: the LUT as a tiny memory holding a truth table. Ask: "if the
   stored bits are 0 0 0 1, which gate is it?"
4. **Try a LUT** (slide 6). Let them click on the slide. Challenge: "make it an OR gate, then tell me the four bits";
   then "make a gate that just copies b". Talk about what they found.
5. **Lecture: our chip and the build flow** (slides 7-8). Slide 7: the hunt they're about to play uses a tenth of
   the chip. Slide 8: ask "what do you think happens to the design when you unplug the board?" before the answer.
6. **Board and shield tour** (slides 9-10). Let them click the parts; ask which one they think will be the most fun.
7. **The hunt** (slide 11). `python scripts/de10.py program my_designs/lessons/01_what_is_fpga/hunt`, then listen in
   the background: `python scripts/de10.py log 900` (a line per step: `HUNT STEP 05 OK`, and `HUNT COMPLETE` at the
   end). "Follow the screen; tell me if you get stuck."
   * Stuck: the hint for that step from the table below, one at a time. Never do it for them.
   * `HUNT COMPLETE` in the log (or the screen says ALL DONE, `donE` on the digits): `python scripts/lesson.py check 1 hunt`.
     Ask what surprised them (often: the joystick and buttons share wires, read through the ADC: slide 10's last part).
8. **Check understanding** (slide 12), as a conversation, one question at a time; their own words; a hint (point at
   the slide) before any answer:

   | Question | The idea a good answer has |
   |---|---|
   | What is the difference between a CPU and an FPGA? | A CPU runs instructions one after another; an FPGA becomes the circuit itself, everything working at the same time. |
   | What is a LUT, and how can one LUT be an AND gate or an XOR gate? | A tiny memory holding a truth table: the inputs choose a row, the stored bit is the output. Change the stored bits and the same LUT is a different gate. |
   | Why is your design gone when the board loses power, and what does that mean for you? | The FPGA keeps its configuration in memory that needs power (SRAM), so it is loaded again after power-up; we program it again with one command (a design can also be stored in the chip's flash, later in the course). |

   All three answered well: `python scripts/lesson.py check 1 quiz`. Note in `my_designs/lessons/notes.md` anything
   they found hard.
9. **Done** (slide 13). `python scripts/lesson.py done 1`, a line in `my_designs/PROGRESS.md`. One sentence on what
   made it work (the board read every input they touched, the chip did it all at once); next: lesson 2, their first
   simulation, where they find and fix a real bug.

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
