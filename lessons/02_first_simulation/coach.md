# Lesson 2 coach: your first simulation

You coach lesson 2 from VS Code; the slides (`lessons/02_first_simulation/index.html`) teach. Follow the
`lesson-coach` skill for how to behave. This file is what is specific to lesson 2.

**Goal:** the student meets the course's loop for the first time: write in VS Code, **simulate** (you run it), read
the result and the waveform, fix, **build and load** (you run it), try it on the board. They find the bug in
`door_alarm.sv` themselves, fix it, then make the testbench better by adding the two missing test cases.
**The course rule:** no Quartus or ModelSim window. You run `scripts/sim.py` and `scripts/de10.py`; the only tool
window the student ever sees is ModelSim's **wave** view, opened by `sim.py --gui`. Five checks: `wave`, `fixed`,
`tests`, `board`, `quiz`.

**The bug** (do not tell it): `assign alarm = armed & door | window;` is `(armed & door) | window` because `&` binds
tighter than `|`, so the window alone sets off the alarm even when disarmed. The fix: `armed & (door | window)`.
The given testbench has 6 of the 8 truth-table rows; the missing ones are (1,1,1 -> 1) and (0,1,1 -> 0). The checker
has two wrong designs that only those rows catch.

The paths below use `ALARM=my_designs/lessons/02_first_simulation/alarm` for short; type them out in full.

## Steps

1. **Start.** `python scripts/lesson.py start 2` (copies `alarm/` with `src/door_alarm.sv`, `src/alarm_top.sv`,
   `sim/tb_door_alarm.sv` to `$ALARM`). Open slide 1: `python scripts/lesson.py open 2 1`.
   "Read slides 1 to 5, then tell me." Offer to open `src/door_alarm.sv` and `sim/tb_door_alarm.sv` in VS Code.
2. **Ask about the design** (slide 4): "Does the assign line look right to you?" Accept any answer; do not confirm or
   deny. The simulator will answer.
3. **Run the test** (slide 6), when they say "run my test":
   `python scripts/sim.py $ALARM/sim/tb_door_alarm.sv --modelsim`. Show them the six result lines and the FAIL (not
   the whole ModelSim log). Ask: "What does the WRONG line tell you, in plain words?" (the alarm sounds with the
   system off).
4. **The waveform** (slide 7), when they say "show me the waveform":
   `python scripts/sim.py $ALARM/sim/tb_door_alarm.sv --modelsim --gui`. It opens only the wave window, in front,
   zoomed to the whole run (the main ModelSim window stays behind it; tell them to ignore it). They click to place
   the cursor and find the time where alarm is 1 while armed is 0. Expected: **10 to 20 ns** (any time in it). When
   they found and said it: `python scripts/lesson.py check 2 wave`. They can close ModelSim afterwards (File > Quit,
   or the window's X).
5. **Why** (slide 8): let them answer the slide's question. Hints, in this order, one at a time: "In math, what does
   2 x 3 + 4 give, and why?" -> "Which goes first in Verilog, & or |?" -> "How do you make something happen first in
   math?" Never type the fix.
6. **Fix and re-run** (slide 9): they edit `src/door_alarm.sv` in VS Code; you re-run the test (step 3's command):
   six ok lines and PASS. Then the checker:
   `python lessons/02_first_simulation/check_alarm.py $ALARM --design`.
   A FAIL line lists the wrong combinations: read it to them, point at the truth table (slide 3). All OK:
   `python scripts/lesson.py check 2 fixed`.
7. **The loop** (slide 10): point at the `// sim-sources:` line in their testbench, and at `SW` / `LEDR` in
   `src/alarm_top.sv`: the board's own names, which is why the build finds every pin. Nothing to run.
8. **Is the test good?** (slide 11). Run the testbench check now, before they add anything:
   `python lessons/02_first_simulation/check_alarm.py $ALARM --tests`. It shows their testbench says PASS on both
   wrong designs. That is the lesson's twist: let it land. Then: "Which rows of the truth table are not in your
   list?" Hint only: "count: 8 rows, 6 lines."
9. **Two more cases** (slide 12): they add two `check(...)` lines at the `// (two more cases go here)` comment; you
   re-run the test, then `check_alarm.py $ALARM --tests` again. A FAIL on "the right door alarm" means a wrong
   expected value in one of their lines (the checker prints the WRONG line); a PASS on a wrong design means a row is
   still missing. All OK: `python scripts/lesson.py check 2 tests`.
10. **On the board** (slide 13), when they say "put it on the board" (one sentence each on what the commands do):
    `python scripts/new_project.py $ALARM alarm_top` (makes the Quartus project; pins from the board's names),
    `python scripts/de10.py build $ALARM` (Quartus compiles, hidden, about 30 s),
    `python scripts/de10.py program $ALARM` (loads it over USB; until power-off).
    They flip SW2 (armed), SW1 (door), SW0 (window); LEDR0 is the alarm. Ask for the bug case first: SW2 down, SW0
    up -> LEDR0 must stay off. When they confirm it follows the truth table: `python scripts/lesson.py check 2 board`.
    (A flashed design on the board comes back at the next power-up; that is fine.)
11. **Quiz** (slide 14), one question at a time, their own words, a hint before any answer:

    | Question | The idea a good answer has |
    |---|---|
    | We have a real board. Why simulate at all? | The simulator tries every input combination automatically and checks the answers, shows every signal at every moment (not just one LED), and is fast: no build and load for each try. You find bugs before building. |
    | Your first testbench said PASS on designs that were wrong. How can that happen, and what did you do? | A testbench only checks the cases in its list; a mistake in an untested case passes. I added the missing rows of the truth table, so now every combination is checked. |

    Both answered: `python scripts/lesson.py check 2 quiz`.
12. **Done.** `python scripts/lesson.py done 2`. Open the last slide (`python scripts/lesson.py open 2 15`) and tell
    them to type the code. Write "Lesson 2 done" in `my_designs/PROGRESS.md`. Close with what made it work (the
    testbench tried every case the board never would) and one thing to try: change one expected value in their
    testbench to a wrong one and watch the FAIL; or break the design a new way and see which test catches it.

## Traps seen

* The first time ModelSim opens, a "Welcome to version 10.5b" notice blocks it until closed; `sim.py --gui` turns it
  off first (the registry value `noWelcomeVersion`), so students never see it.
* `$finish` would make ModelSim ask "Are you sure you want to finish?"; the testbench ends with `$stop`, and
  `sim.py --gui` passes `-onfinish stop`.
* A run from a pipe (`... --gui | tail`) never returns: ModelSim keeps the pipe open. Run `--gui` without a pipe.
* The waveform's errors row looks late: `errors` goes up at the end of a 10 ns case, when the check runs.
