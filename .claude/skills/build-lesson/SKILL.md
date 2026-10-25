---
name: build-lesson
description: >
  (Maintainer) Build the next lesson of the stage-2 course in lessons/NN_name/: agree it with Avi first, then the slide
  page (reusing the previous lesson's style and script), coach.md, lesson.json, the student's starter files, a checker
  that grades the student's work (including mutation tests that grade a student's TESTBENCH), real screenshots of
  Quartus / ModelSim, and the tests. Proven with lessons 2 and 3. Coaching a student is lesson-coach, not this.
  TRIGGER: "build lesson", "next lesson to build", "write lesson", "new lesson", "develop the lessons", "lesson 4",
  "course content", "slides for the lesson", "lesson checker", "screenshot ModelSim", "screenshot Quartus".
---

# Build a lesson (maintainer)

The course plan, the agreed rules and each lesson's status: [docs/stage2_lessons.md](../../../docs/stage2_lessons.md).
Read it first. Lessons follow nand2tetris; each one is **agreed with Avi before it is built** (its design, what the
student does by hand, what they write), one at a time. Ask 2-3 concrete questions with a recommended option each.

## The files (tests/test_lessons.py checks them)

```text
lessons/NN_slug/
  lesson.json      {"id", "slug" (= folder), "title", "work": [folders copied to the student], "checks": {name: what passes}}
  coach.md         the chat's script: goal, the answer it must not give away, numbered steps that open slides
                   (lesson.py open N slide), run checkers, record each check with "python scripts/lesson.py check N <name>"
                   (the test greps for every check name), the quiz table, Traps seen
  index.html       the slides; CODE_HASH from "python scripts/lesson.py code-hash N"; localStorage only inside try {}
  <work>/          the student's starter files, laid out like every project: src/ (into the chip), sim/ (testbench)
  check_*.py       the checker: plain-language OK / FAIL lines a student can act on, exit 0 only when all OK
  checker/         the checker's own reference designs, mutants and testbenches (never copied to the student)
  media/           real screenshots (PNG), referenced as media/x.png
```

## The page: reuse, don't redesign

Assemble `index.html` from the previous lesson's page: keep its `<head>` (style), the last "completion code" slide and
the script; replace the title, description, bar text, slide count, `LESSON`, `CODE_HASH`, the "what you learned"
list and every "Lesson N" string; put the new `<section class="slide" data-title=...>` blocks in between. Lesson 3
was built this way by a short Python script (find `<main class="deck" id="deck">` and the last slide's comment);
check for leftover "Lesson N-1" strings. Classes available: `.cols`, `.term` (dark terminal box with `.ok` /
`.dim`), `.box` / `.box.warm` / `.box.ok`, `.say` (the big statement), `.shot` (click-to-zoom screenshot),
`.grid3` + `.card`, `.steps-table`, `.quiz`, SVG classes `s-line s-acc s-box s-soft s-txt s-small`.
Render a few slides with headless Edge (`msedge --headless=new --screenshot=x.png --window-size=1280,860 file:///...#N`)
and look at them before committing.

## Checkers that grade a testbench: mutants

To check that a student's testbench is good enough, run it (in a scratch copy) on the right design (must PASS), on
their own design (must PASS) and on wrong designs that differ only in the cases the starter testbench leaves out
(must FAIL). Lesson 3: the starter has 6 of 8 truth-table rows; `mutant_xor.sv` differs only at (1,1,1),
`mutant_both_open.sv` only at (0,1,1), so both added rows are needed. Grade the design with the checker's own
exhaustive testbench, never with the student's.

## Real screenshots of ModelSim / Quartus

`scripts/gui_shot.ps1` starts the tool, waits, and captures one window by title with PrintWindow (works when covered).
* ModelSim: drive it with a do-file (`cd {path}`, `vlib`, `vlog`, `vsim`, `config wave -signalnamewidth 1`,
  `add wave ...`, `run -all`). For a clean wave picture: `view -undock wave`, `update`,
  `wm geometry [winfo toplevel [view wave]] 1300x430+0+0`, `update`, then `wave zoom range 0ns 70ns` and
  `wave cursor add -time 15ns -name {wrong}`, and capture with `-Title "Wave*" -W 0`. Resizing the window AFTER the
  zoom keeps the time-per-pixel and ruins the range; `after <ms> {...}` callbacks never ran in a do-file.
* The first ModelSim start shows a "Welcome to version 10.5b" notice: that is a slide too (students see it).
* Quartus GUI shots are not used any more (no Quartus window in the course); the old lesson 2 had them, see git history.
* Real tool text for `.term` boxes: run the same commands in batch (`vlog ...`, `vsim -c ... -do "run -all; quit -f"`)
  and paste the output.

## Before committing

`python -m pytest -q tests/test_lessons.py`, the checker run on the starter (expected FAILs) and on a solved copy
(ALL OK) in a temp folder, the board design built with `scripts/new_project.py` + `de10.py build` (and programmed
when the board is connected). Update docs/stage2_lessons.md (status line), the start page's lesson buttons, the
lessons log; pull before committing (Avi works on projects from another PC).
