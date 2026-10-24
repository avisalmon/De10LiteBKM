# Spec: De10LiteBKM

## What it is

A BKM for the Terasic DE10-Lite FPGA board with its LCD and game-pad shield. Your own Verilog designs running on the DE10-Lite and its LCD / game-pad shield, built, debugged and verified with an AI beside you. The user sets up an editor with an AI chat, clones this repo and says
"Tell me what to do"; the AI guides them, installs what is needed and does the work with them, teaching as it goes.

## Audience

High-school students and their teachers first (the course, stage 2), and anyone who wants their own designs on the board
(stage 3). No prior knowledge beyond using a computer. **English only** (decided 2026-10-24).

## Decisions

* **Windows first.** Other platforms are adapted by the chat and marked unverified until someone tests them.
* **The user's work never conflicts with updates**: it lives in git-ignored `my_designs/`; every session pulls.
* **Pinned versions**, so what works today works next year.
* **Quartus Prime Lite 17.1 + ModelSim-Intel Starter** (free; the template era; ModelSim Starter needs no license file).
  Users download them from Altera themselves: the license forbids redistribution.
* **The board's own USB link does everything**: programming, a text link (JTAG UART), screen read-back, Signal Tap.
* **Every capability is a verified example + a skill**; shared Verilog in `lib/`, one command per step in `scripts/`.
* **Three stages on one page**: install, learn (nand2tetris order, hints not answers), build anything.

## Not in scope

* Other boards (see the sister BKM for the DE10-Nano), Quartus Pro, VHDL.
* Hosting Altera's installers (not allowed by the license).
* Writing the student's lesson code for them (stage 2 is coaching only).
