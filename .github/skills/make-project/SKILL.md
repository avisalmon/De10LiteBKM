---
name: make-project
description: >
  Build a complete design for the DE10-Lite as a public BKM project in the standard folder (projects/<name>/):
  the workflow from idea to a reviewed, tested, documented project with an overview page (block diagram, flow, tests,
  review log, status), an architecture spec, a user guide, the Quartus archive (.qar, no bitstreams) and a card on the
  projects portal; then the learning goes back into the skills. Proven with Pac-Man.
  TRIGGER: "new project", "build a project", "make a project", "project folder", "document the project", "project page",
  "architecture spec", "user guide", "project review", "add it to the portal", "publish the project", "standard folder".
---

# Make a project

A project is a whole design (a game, an instrument, a controller), as opposed to an example (one capability). It is
public: sources, tests, pictures and the `.qar`, **never a `.sof` or `.pof`** (3 MB each; git-ignored). The user's private
scratch work stays in `my_designs/`; a project is meant to be read, rebuilt and learned from by others.

Proven: `projects/pacman` (build, review, three pages, portal card, skill, test) in one session.

## The standard folder

```text
projects/<name>/
  index.html          overview: lead, badges, downloads, contents, what you will see (2 pictures), block diagram
                      (inline SVG), how it flows, numbers, how it was tested, review log, status, files, footer
  spec.html           architecture spec: requirements, modules and ports, clock domains and crossings, memories,
                      state machines and encodings, board I/O and protocols, budgets, design decisions
  guide.html          user guide: need, build and load, use, test over USB, flash, simulate, change, troubleshoot
  <name>.qar          python scripts/de10.py pack projects/<name>   (Quartus' own archiver; carries src/extra.qsf MISC_FILEs)
  <name>.qpf/.qsf/.sdc   python scripts/new_project.py projects/<name> <top> --lib ...
  src/ sim/ assets/ media/        sources, testbench(es), generated data + generators, pictures (< 600 kB each)
projects/index.html   the portal: one card per project (picture, one line, status tag)
projects/project.css  the shared style; projects/_template/ the three pages with FILL IN marks
```
`tests/test_projects.py` checks all of it (files, sections, links, no bitstreams, portal card, start-page link).
The name is lower-case, no digits prefix (`pacman`, `snake`, `oscilloscope`); the top module is `<name>_top`.

## The workflow

1. **Agree the scope** in a few lines: what it does, what proves it, what only a person can check. Which skills apply
   (`build-arcade-game`, `build-rom`, `read-screen`, ...): open them first.
2. **Build it in `projects/<name>/`** with the toolkit: `scripts/new_project.py`, `--lib` parts, a `sim/tb_<name>.sv`
   that exercises the design and prints PASS, `scripts/de10.py build` / `program`, then prove it on the board
   (`de10.py send` / `log` / `screen` / `cam`). Keep `logs/` for captures (ignored).
3. **Review** before documenting. Read every source once, whole, and fix: width truncations (sized constants, sums
   through wires), double non-blocking writes to one register in a path, dead or unconnected signals (name them `_nc`),
   reserved words as names, every warning that comes from your files (`grep Warning logs/build.log | grep <file>`;
   the library's and "pin stuck at" ones are known). Re-simulate and rebuild after the review; keep the numbers.
4. **Pictures**: `media/screen_*.png` from `de10.py screen`, `media/board.jpg` from `de10.py cam` (crop if it helps),
   a preview or waveform if it explains something. Under 600 kB each.
5. **Pages**: copy `projects/_template/*.html`, replace every `FILL IN`. The overview answers "what will I see and why
   does it work"; the spec answers "where does every bit live and what are the budgets"; the guide answers "what do I type
   and what do I do when it looks wrong". Numbers from `de10.py report`; the review log from step 3; the status table
   says what was verified by the machine, what only a person can check, and what was left out on purpose.
6. **Pack and link**: `de10.py pack projects/<name>` (the `.qar`), a card on `projects/index.html`, the start page's
   projects chip if the project is a headline, `README.md` if it changes the pitch.
7. **Learning back into the repo**: every trap met becomes a gotcha; every reusable technique goes into the skill that
   owns it (or a new skill); `docs/lessons_log.md` gets a line. `python scripts/sync_skills.py`, then `pytest`.
8. **Commit and push** when the user says so (rule 5). Then hand over the human checks, one at a time.

## Writing the pages (what good looks like)

* Plain words first, the code name in `<code>` after. One idea per sentence. Numbers, not adjectives.
* The block diagram: `.pin` for the board / outside world, `.ip` for library and Altera IP, `.blk` for your modules;
  group by clock domain, name the signals on the arrows, dashed lines for debug paths. `aria-label` tells it in one
  sentence. The flow section walks one event (a frame, a sample, a request) through the diagram in order.
* The spec's tables are the contract: port table of the main module, state tables with encodings, memory table with
  ports and what addresses mean, budgets with headroom.
* The guide is for the person at the board: exact commands, what they should see after each, and a trouble table
  of "you see / likely / do".
* Honest status: "verified: simulation and board", "to do by a person", "not built". Never "works" without a check.

## Process notes

* On Windows `mv` of a folder fails with "Device or resource busy" while any shell has it as its working directory:
  run the move from the repo root.
* `de10.py program <dir>` finds `output_files/<rev>.sof` (or `_time_limited`); the pages say "build, then program the
  folder", never a path to a `.sof`.
* A template page must not contain `{{` or `BKM-TODO` (the hygiene test): the marks are `FILL IN`.
