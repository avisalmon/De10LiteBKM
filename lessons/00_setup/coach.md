# Lesson 0 coach: get your computer and board ready

You coach lesson 0 from VS Code; the slides (`lessons/00_setup/index.html`) teach. Follow the `lesson-coach` skill
for how to behave. This file is what is specific to lesson 0.

**Goal:** prove the whole chain works before any learning: Python + `env`, Quartus Prime Lite 17.1, MAX 10 support,
ModelSim, the USB-Blaster driver, the board. Three checks: `computer`, `sim`, `board`.

**Where the student arrives from:** slides 1-8 are read on the web, before the chat exists. Slide 8 tells them to type
"teach me" here. So when lesson 0 starts, VS Code, Git, Claude Code and the clone are already done.

## Steps

1. **Start.** `python scripts/lesson.py start 0` (copies `ready/src` to `my_designs/lessons/00_setup/ready/src`).
   Welcome them in two sentences: what lesson 0 proves, about how long it takes (an hour, mostly downloads).
2. **Python and env** (if `env/` is missing): run the `setup-my-computer` skill. They only click "Yes" on installers.
3. **Quartus, ModelSim, MAX 10.** Run `scripts/doctor.py`. If Quartus or ModelSim is missing, open slide 9
   (`python scripts/lesson.py open 0 9`) and walk them through it one step at a time:
   * They create their **own** free MyAltera account (never use or ask for anyone else's details).
   * Download page: Quartus Prime **Lite** Edition, release **17.1**, tab "Individual Files". Three files into one
     folder (e.g. `Downloads\quartus17`): `QuartusLiteSetup-17.1.0.590-windows.exe`,
     `ModelSimSetup-17.1.0.590-windows.exe`, `max10-17.1.0.590.qdz`.
   * Run `QuartusLiteSetup...exe`, accept the defaults (install path `C:\intelFPGA_lite\17.1`); the components page
     must have **MAX 10** and **ModelSim-Intel FPGA Starter Edition** ticked. 15-30 minutes.
   * At the end, leave "Launch USB Blaster II driver installation" ticked and click Install on the driver windows.
     If it was skipped, step 4 installs the driver by hand.
   * Re-run `scripts/doctor.py` until Quartus, MAX 10 and ModelSim are OK.
4. **The board and the driver.** Open slide 10. They plug the shield onto the board (if not already), the USB cable
   into the board's **USB-Blaster** port and the computer. Blue power LED on. Run `scripts/doctor.py --real`.
   * "no USB-Blaster cable found" with the cable plugged in = no driver. Guide them: Start menu > type
     **Device Manager** > Other devices > **USB-Blaster** (yellow triangle) > right-click > Update driver > Browse my
     computer > `C:\intelFPGA_lite\17.1\quartus\drivers` (tick "Include subfolders") > Next > Install.
   * When `--real` shows no FAIL: `python scripts/lesson.py check 0 computer`. Open slide 11 and say what each OK line
     means in one short sentence each.
5. **Simulation check.** Open slide 12. Run
   `python scripts/sim.py lessons/00_setup/sim/tb_and_gate.sv --modelsim`. Show them the four "ok" lines and PASS.
   Then open the wave window (`--gui` added) so they see a simulator for the first time; tell them to close it when
   done. On PASS: `python scripts/lesson.py check 0 sim`.
6. **Board check.** Open slide 13. They build it themselves, so Quartus' compiler is proven too:
   * `python scripts/new_project.py my_designs/lessons/00_setup/ready ready_top --lib display debug font seg7`
   * `python scripts/de10.py build my_designs/lessons/00_setup/ready` (about 2 minutes: tell them what Quartus is
     doing meanwhile: synthesis turns Verilog into gates, the fitter places them in the chip, timing checks speed).
   * `python scripts/de10.py program my_designs/lessons/00_setup/ready`
   * Ask what they see. Expected: LEDs running back and forth, `rEAdY` on the 7-segment digits, colour bars and
     **READY** on the LCD. You can also look yourself: `python scripts/de10.py screen` and read the PNG.
   * Only when they confirm (or you saw it and they agree): `python scripts/lesson.py check 0 board`.
   * Build fails for a reason you cannot fix: build the course's reference copy to tell "their copy is broken" from
     "Quartus is broken" (`python scripts/de10.py build lessons/00_setup/ready`, then
     `python scripts/de10.py program lessons/00_setup/ready`). No .sof ships in the repo, so there is always a build
     first. Do not record `board` until their own build runs.
7. **Done.** `python scripts/lesson.py done 0`. Open slide 14 (what they proved, what comes next). Write
   "Lesson 0 done" in `my_designs/PROGRESS.md`. Close with what they proved (every tool works, end to end) and what
   comes next (lesson 0.1: what an FPGA is).

## Traps seen

* `Error (209042): Application Quartus Programmer ... is using the target device`: another program holds the
  cable (a Quartus Programmer window, or another JTAG command still running). Close it and run program again.
