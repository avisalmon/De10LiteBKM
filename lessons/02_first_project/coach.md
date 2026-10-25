# Lesson 2 coach: your first project in Quartus

You coach lesson 2 from VS Code; the slides (`lessons/02_first_project/index.html`) teach. Follow the `lesson-coach`
skill for how to behave. This file is what is specific to lesson 2.

**Goal:** the student does the whole Quartus flow **by hand, in the Quartus window**, once: new project, device,
the Verilog file, pins, compile, program. After this lesson the chat runs these steps with commands, and the
student knows what each command does. **This is the one lesson where you do not run the flow for them**: you open
Quartus, you check, you explain; they click. No simulation in this lesson (ModelSim comes in lesson 3).
Four checks: `project`, `board`, `change`, `quiz`.

## Steps

1. **Start.** `python scripts/lesson.py start 2` (copies `first_led/first_led.sv` to
   `my_designs/lessons/02_first_project/first_led/`). Tell them the **full path** of that folder (they type it in the
   wizard; it depends on where they cloned the course). Open slide 1: "Read slides 1 to 3, then tell me."
2. **Open Quartus for them**: `Start-Process "C:\intelFPGA_lite\17.1\quartus\bin64\quartus.exe"` (PowerShell).
   First time ever: a licensing window asks what to do: **Run the Quartus Prime software**, OK (slide 3).
   It can take half a minute to appear.
3. **The wizard** (slides 4-7), one slide at a time. The traps:
   * Working directory = the folder from step 1. Project name `first_led` (the top-level entity fills in by itself).
   * Add Files: **Add All** picks up `first_led.sv`. Nothing listed = wrong folder in the first page.
   * Device: type `10M50DAF484C7G` in **Name filter**, click the one line. Then Next, Next, Finish.
4. **Read the Verilog together** (slide 8). Ask: "what do you think `assign led0 = sw0;` does?" Let them answer.
5. **Analysis** (slide 9): Processing > Start > Start Analysis & Synthesis (Ctrl+K). Point at **0 logic elements**:
   a wire needs no logic. (After the full compile it says 1: the fitter adds a buffer between the two pins.)
6. **Pins** (slides 10-11): Assignments > Pin Planner. For each row: Location (double-click, type `A8` / `C10`,
   Enter) and I/O Standard **3.3-V LVTTL** (double-click, open the list; typing `3` jumps near it). Close the Pin
   Planner: the settings are saved.
7. **Check their project** (slide 12):
   `python lessons/02_first_project/check_project.py my_designs/lessons/02_first_project/first_led`.
   A FAIL line says what to fix and where; read it to them, they fix it in Quartus, run it again. Never edit their
   `.qsf` for them. All OK: `python scripts/lesson.py check 2 project`.
8. **Compile** (slide 13): Processing > Start Compilation (Ctrl+L), about 30 seconds. Expect "successful, 0 errors"
   and some warnings; the red **TimeQuest** line only means there is no timing file yet (this design has no clock).
9. **Program** (slide 14): Tools > Programmer. "No Hardware" -> Hardware Setup, double-click **USB-Blaster**, Close.
   `output_files/first_led.sof` is already listed with Program/Configure ticked -> **Start** -> 100% (Successful).
   "Application ... is using the target device" = another program holds the cable; close it and Start again.
10. **On the board** (slide 15): flip SW0 up and down, LED0 follows. Tell them about the faint glow of the other
    LEDs and the dark digits (unused pins have a weak pull-up), and that the screen may still show an old picture
    (the LCD keeps its last image; this design does not drive it). When they confirm LED0 follows SW0:
    `python scripts/lesson.py check 2 board`.
11. **Make it yours** (slide 16): SW9 drives LED9 too. They edit `first_led.sv` in VS Code themselves: two more ports
    and one more `assign`. Hints only: "look at how sw0 and led0 are written, and copy the pattern". Then in Quartus:
    Analysis (Ctrl+K) so the Pin Planner shows the new names, pins `F15` (sw9) and `B11` (led9) with 3.3-V LVTTL,
    `check_project.py ... --change`, compile, program, flip SW9. When it works:
    `python scripts/lesson.py check 2 change`.
12. **The fast way** (slide 17): from now on you do these steps with commands. `scripts/new_project.py` writes the
    project and takes every pin from the course's pin list (`lib/board/de10_lite_pins.csv`), which is why later
    lessons name their ports like the board does (`SW`, `LEDR`, `HEX0`...) instead of `sw0`/`led0`;
    `scripts/de10.py build` / `program` compile and program. Same steps, no clicks. Just explain it here; no need to
    run it on their `first_led` project (its names are not in the pin list).
13. **Quiz** (slide 18), one question at a time, their own words, a hint before any answer:

    | Question | The idea a good answer has |
    |---|---|
    | Why did we have to tell Quartus the pins? | The chip has hundreds of pins and the board's makers wired SW0 and LEDR0 to particular ones (C10, A8). Quartus can't know the board's wiring, so we tell it which pin each signal uses (and its voltage standard). |
    | Which file did you load into the chip, and what is in it? | The `.sof` from `output_files/`: the configuration Quartus made, the setting of every LUT, wire switch and pin in the chip. |

    Both answered: `python scripts/lesson.py check 2 quiz`.
14. **Done.** `python scripts/lesson.py done 2`, open slide 19, they type the code. Update `my_designs/PROGRESS.md`.
    Next: lesson 3, the first ModelSim simulation.

## Traps seen

* Quartus' main window can come up hidden right after the first-launch licensing window. If nothing appears within a
  minute, close Quartus (`Stop-Process -Name quartus`) and start it again; the licensing choice is remembered.
* The I/O standard defaults to **2.5 V**: the board's pins are 3.3 V, so it must be changed for every pin
  (check_project.py catches it).
