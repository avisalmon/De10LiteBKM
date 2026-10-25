# Lesson 3 coach: your first simulation

You coach lesson 3 from VS Code; the slides (`lessons/03_first_simulation/index.html`) teach. Follow the
`lesson-coach` skill for how to behave. This file is what is specific to lesson 3.

**Goal:** the student runs a testbench **by hand in the ModelSim window once** (like lesson 2 did Quartus by hand),
reads the waveform, finds the bug in `door_alarm.sv` themselves, fixes it, then makes the testbench better by adding
the two missing test cases, and proves the design on the board. After this lesson the chat runs simulations with
`scripts/sim.py`. Five checks: `gui`, `fixed`, `tests`, `board`, `quiz`.

**The bug** (do not tell it): `assign alarm = armed & door | window;` is `(armed & door) | window` because `&` binds
tighter than `|`, so the window alone sets off the alarm even when disarmed. The fix: `armed & (door | window)`.
The given testbench has 6 of the 8 truth-table rows; the missing ones are (1,1,1 -> 1) and (0,1,1 -> 0). The checker
has two wrong designs that only those rows catch.

## Steps

1. **Start.** `python scripts/lesson.py start 3` (copies `alarm/` with `src/door_alarm.sv`, `src/alarm_top.sv`,
   `sim/tb_door_alarm.sv` to `my_designs/lessons/03_first_simulation/alarm/`). Open slide 1:
   `python scripts/lesson.py open 3 1`. "Read slides 1 to 5, then tell me."
2. **Ask about the design** (slide 4): "Does the assign line look right to you?" Accept any answer; do not confirm or
   deny. The simulator will answer.
3. **Open ModelSim for them** (slide 6): `Start-Process "C:\intelFPGA_lite\17.1\modelsim_ase\win32aloem\vsim.exe"`
   (PowerShell). First time: the welcome notice -> **Close**.
4. **The four commands** (slide 7). Give them the exact first line with **forward slashes**, built from the repo's
   real path, e.g. `cd C:/Users/<them>/De10LiteBKM/my_designs/lessons/03_first_simulation/alarm/sim`. Then
   `vlib work`, `vlog ../src/door_alarm.sv tb_door_alarm.sv`, `vsim tb_door_alarm`. Expect "Errors: 0, Warnings: 0"
   after vlog. ModelSim's Transcript accepts copy-paste (right-click > Paste).
5. **Run** (slide 8): `add wave *` and `run -all`. The Transcript shows one WRONG line (armed=0 door=0 window=1,
   alarm=1) and `FAIL: 1 test case(s) wrong`; ModelSim brings the source to the front at the `$stop` line.
   Ask: "What does the WRONG line tell you, in plain words?" (the alarm sounds with the system off).
6. **The waveform** (slides 9-10): they click the **Wave** tab, **Zoom Full**, click to place the cursor. Ask them
   to find the time where alarm is 1 while armed is 0 and tell you. Expected: **10 to 20 ns** (any time in it, e.g.
   15 ns). When they found it themselves in the waveform: `python scripts/lesson.py check 3 gui`.
7. **Why** (slide 11): let them answer the slide's question. Hints, in this order, one at a time: "In math, what does
   2 x 3 + 4 give, and why?" -> "Which goes first in Verilog, & or |?" -> "How do you make something happen first in
   math?" Never type the fix.
8. **Fix and re-run** (slide 12): they edit `src/door_alarm.sv` in VS Code, then in ModelSim
   `vlog ../src/door_alarm.sv`, `restart -f`, `run -all` -> six ok lines and PASS. Then you run the checker:
   `python lessons/03_first_simulation/check_alarm.py my_designs/lessons/03_first_simulation/alarm --design`.
   A FAIL line lists the wrong combinations: read it to them, point at the truth table (slide 3). All OK:
   `python scripts/lesson.py check 3 fixed`.
9. **The fast way** (slide 13): run it once for them so they see it:
   `python scripts/sim.py my_designs/lessons/03_first_simulation/alarm/sim/tb_door_alarm.sv --modelsim`.
   Point at the `// sim-sources:` line in their testbench.
10. **Is the test good?** (slide 14). Run `check_alarm.py ... --tests` now, before they add anything: it shows their
    testbench says PASS on both wrong designs. That is the lesson's twist: let it land. Then: "Which rows of the
    truth table are not in your list?" Hint only: "count: 8 rows, 6 lines."
11. **Two more cases** (slide 15): they add two `check(...)` lines at the `// (two more cases go here)` comment.
    Then: `python lessons/03_first_simulation/check_alarm.py my_designs/lessons/03_first_simulation/alarm --tests`.
    A FAIL on "the right door alarm" means a wrong expected value in one of their lines (the checker prints the
    WRONG line); a PASS on a wrong design means a row is still missing. All OK:
    `python scripts/lesson.py check 3 tests`.
12. **On the board** (slide 16): you build and program it (one sentence each on what the commands do):
    `python scripts/new_project.py my_designs/lessons/03_first_simulation/alarm alarm_top`
    `python scripts/de10.py build my_designs/lessons/03_first_simulation/alarm` (about 30 s)
    `python scripts/de10.py program my_designs/lessons/03_first_simulation/alarm`.
    They flip SW2 (armed), SW1 (door), SW0 (window); LEDR0 is the alarm. Ask for the bug case first: SW2 down, SW0
    up -> LEDR0 must stay off. When they confirm it follows the truth table: `python scripts/lesson.py check 3 board`.
    (If the board holds a flashed design, program overrides it until power-off; that is fine.)
13. **Quiz** (slide 17), one question at a time, their own words, a hint before any answer:

    | Question | The idea a good answer has |
    |---|---|
    | We have a real board. Why simulate at all? | The simulator tries every input combination automatically and checks the answers, shows every signal at every moment (not just one LED), and is fast: no compile and program for each try. You find bugs before building. |
    | Your first testbench said PASS on designs that were wrong. How can that happen, and what did you do? | A testbench only checks the cases in its list; a mistake in an untested case passes. I added the missing rows of the truth table, so now every combination is checked. |

    Both answered: `python scripts/lesson.py check 3 quiz`.
14. **Done.** `python scripts/lesson.py done 3`. Open slide 18 (`python scripts/lesson.py open 3 18`) and tell them to
    type the code. Write "Lesson 3 done" in `my_designs/PROGRESS.md`. Close with what made it work (the testbench tried
    every case the board never would) and one thing to try: change one expected value in their testbench to a wrong one
    and watch the FAIL; or break the design a new way and see which test catches it.

## Traps seen

* `$finish` in ModelSim's window pops "Are you sure you want to finish?"; the testbench uses `$stop` instead (pause),
  and `scripts/sim.py --gui` passes `-onfinish stop`.
* Backslashes in the ModelSim `cd` line: Tcl eats them. Use forward slashes (or braces: `cd {C:\path}`).
* `vsim` says "Error loading design": the `vlog` step failed or ran in another folder; check the `cd`.
* After editing the design, `run -all` alone re-runs the old one: `vlog` the file again and `restart -f` first.
* The waveform's errors row looks late: `errors` goes up at the end of a 10 ns case, when the check runs.
