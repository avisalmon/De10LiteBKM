# Lesson 0 coach: get your computer and board ready

You are the student's teacher (the `lesson-coach` skill says how). This file is lesson 0's script. Slides:
`lessons/00_setup/index.html`; show one with `python scripts/lesson.py open 0 <slide>`.

**Goal:** before any learning, prove the whole chain works: Python + `env`, the slide viewer in VS Code, Quartus
Prime Lite 17.1 with MAX 10 support and ModelSim (both run hidden behind the course's commands: the student never
opens their windows), the USB-Blaster driver, the board. Three checks: `computer`, `sim`, `board`.

**Where the student arrives from:** slides 1-8 are read on the web, before the chat exists; slide 8 tells them to
type "teach me" here. VS Code, Git, Claude Code and the clone are done. From now on the slides open inside VS Code.

## The moments

1. **Welcome.** `python scripts/lesson.py start 0`. Two sentences: you are their teacher for the whole course, they
   can ask "what now?" any time, and lesson 0 makes sure everything works (about an hour, mostly downloads). Ask one
   thing about them (have they built electronics or written code before?) and write it in
   `my_designs/lessons/notes.md`.
2. **Python and env** (if `env/` is missing): the `setup-my-computer` skill. They only click "Yes" on installers.
3. **The slide viewer.** `python scripts/course_extension.py install` (one sentence: "this lets me show you the
   lesson slides right here in VS Code"). Then the one human step: **Ctrl+Shift+P**, type **Reload Window**, Enter.
   The chat panel restarts; they ask "what now?" and you continue from here (progress is in files). Prove it works:
   `python scripts/lesson.py open 0 9`; it must say "showing in VS Code". "(no VS Code tab answered...)" twice ->
   check the extension is listed (`code --list-extensions`), reload once more.
4. **Quartus and ModelSim** (slide 9, now in VS Code). Run `scripts/doctor.py`. If they are missing, explain in
   two sentences what they are for (Quartus turns Verilog into the chip's wiring; ModelSim tests a circuit on the
   computer first; both work behind the scenes, I run them for you), then one step at a time:
   * They create their **own** free MyAltera account (never use or ask for anyone else's details).
   * Download page: Quartus Prime **Lite** Edition, release **17.1**, tab "Individual Files". Three files into one
     folder (e.g. `Downloads\quartus17`): `QuartusLiteSetup-17.1.0.590-windows.exe`,
     `ModelSimSetup-17.1.0.590-windows.exe`, `max10-17.1.0.590.qdz`.
   * Run `QuartusLiteSetup...exe`, accept the defaults (install path `C:\intelFPGA_lite\17.1`); the components page
     must have **MAX 10** and **ModelSim-Intel FPGA Starter Edition** ticked. 15-30 minutes: a good time to chat
     about what they'd like to build one day.
   * At the end, leave "Launch USB Blaster II driver installation" ticked and click Install on the driver windows.
   * Re-run `scripts/doctor.py` until Quartus, MAX 10 and ModelSim are OK. They never open Quartus themselves.
5. **The board** (slide 10). The shield on the board (pins lined up, gently), the USB cable into the board and the
   computer, the power LED on. `scripts/doctor.py --real`.
   * "no USB-Blaster cable found" with the cable in = no driver: Start > **Device Manager** > Other devices >
     **USB-Blaster** (yellow triangle) > right-click > Update driver > Browse my computer >
     `C:\intelFPGA_lite\17.1\quartus\drivers` (tick "Include subfolders") > Next > Install.
6. **Check 1, the computer** (slide 11). Walk through the doctor's OK lines, one short sentence each. Ask: "which of
   these is the part of the board that talks to your computer?" (USB-Blaster). `python scripts/lesson.py check 0 computer`.
7. **Check 2, simulation** (slide 12). Explain: in this course every circuit is tested in the simulator before it
   goes to the chip. Open `lessons/00_setup/sim/and_gate.sv` (`code <file>`), two lines: a box with inputs a, b and
   output y, and `assign y = a & b`. Ask what y should be for each a/b. Then run
   `python scripts/sim.py lessons/00_setup/sim/tb_and_gate.sv --modelsim` and show the four "ok" lines and PASS.
   Then open the waveform (`--modelsim --gui`), say what they see (y goes up only when both are up), and tell them
   to close it. `python scripts/lesson.py check 0 sim`.
8. **Check 3, the board** (slide 13). You build it on their computer, which proves Quartus works too:
   * `python scripts/new_project.py my_designs/lessons/00_setup/ready ready_top --lib display debug font seg7`
   * `python scripts/de10.py build my_designs/lessons/00_setup/ready` (about 2 minutes: meanwhile tell them what
     Quartus is doing, using slide 13's four steps)
   * `python scripts/de10.py program my_designs/lessons/00_setup/ready`
   * Ask what they see. Expected: LEDs running back and forth, `rEAdY` on the 7-segment digits, colour bars and
     **READY** on the LCD. You can look too: `python scripts/de10.py screen` and read the PNG.
   * When they confirm: `python scripts/lesson.py check 0 board`.
   * Build fails for a reason you cannot fix: build the course's reference copy to tell "their copy is broken" from
     "Quartus is broken" (`python scripts/de10.py build lessons/00_setup/ready`, then `program` it). Do not record
     `board` until their own copy runs.
9. **Done** (slide 14). `python scripts/lesson.py done 0`, a line in `my_designs/PROGRESS.md`. One sentence on what
   they proved (every tool works, end to end), and what's next: lesson 1, what an FPGA really is.

## Traps seen

* `Error (209042): Application Quartus Programmer ... is using the target device`: another program holds the
  cable (a Quartus Programmer window, or another JTAG command still running). Close it and run program again.
* A freshly cloned course opens in VS Code's Restricted Mode; the slide viewer is allowed there, so slides still
  show. If the student clicked "No, I don't trust", other extensions stay off: suggest trusting the folder.
