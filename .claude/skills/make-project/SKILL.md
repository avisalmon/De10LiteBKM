---
name: make-project
description: >
  Build a complete design for the DE10-Lite as a public BKM project in the standard folder (projects/<name>/):
  the workflow from idea to a reviewed, tested, documented project with an overview page (block diagram, flow, tests,
  review log, status), an architecture spec, a user guide, an optional tutorial (experiments: what to do, what you
  should see on a real board picture, and why), the Quartus archive (.qar, no bitstreams) and a card on the projects
  portal; then the learning goes back into the skills. Proven with Pac-Man and FFT Lab.
  TRIGGER: "new project", "build a project", "make a project", "project folder", "document the project", "project page",
  "architecture spec", "user guide", "tutorial", "add a tutorial", "project review", "add it to the portal",
  "publish the project", "standard folder".
---

# Make a project

A project is a whole design (a game, an instrument, a controller), as opposed to an example (one capability). It is
public: sources, tests, pictures and the `.qar`, **never a `.sof` or `.pof`** (3 MB each; git-ignored). The user's private
scratch work stays in `my_designs/`; a project is meant to be read, rebuilt and learned from by others.

Proven: `projects/pacman` (build, review, three pages, portal card, skill, test) in one session,
`projects/fft_lab` (Resources first, standing on its own, evaluation IP, 17 board settings checked pixel by pixel, and
the tutorial: 10 experiments on 15 pictures from the board),
`projects/accel_cube` (a bit-exact Python model written before the RTL, 3D math, 8 board settings 0 pixels different)
and `projects/invaders` (an arcade original remade from its own program, a testbench that plays a whole game with
a predictive bot, a mutation test, 10 board presets 0 pixels different).

## The standard folder

```text
projects/<name>/
  index.html          overview: the cover (title, the lead's first sentence, badges, downloads, beside the project's one
                      picture), the rest of the lead, RESOURCES (always the first section), contents, what you will
                      see (2 pictures), block diagram (inline SVG), how it flows, numbers, how it was tested, review log,
                      status, files, footer
  spec.html           architecture spec: requirements, modules and ports, clock domains and crossings, memories,
                      state machines and encodings, board I/O and protocols, budgets, design decisions
  guide.html          user guide: need, build and load, use, test over USB, flash, simulate, change, troubleshoot
  tutorial.html       optional: experiments, each "do / you should see (a real board picture) / why", a tour of the
                      screen, the numbers behind it, a quiz, the words; when there is something to try (below)
  <name>.qar          python scripts/de10.py pack projects/<name>   (Quartus' own archiver; carries src/extra.qsf MISC_FILEs)
  <name>.qpf/.qsf/.sdc   python scripts/new_project.py projects/<name> <top> --lib ...
  src/ sim/ assets/ media/        sources, testbench(es), generated data + generators, pictures (< 600 kB each)
  ip/                 generated Altera IP (ip-generate output and its generator script), added with --file ip/<x>/<x>.qip
projects/index.html   the portal: a gallery, one card per project (its picture, what it is, status pills, what is
                      still to check by hand); the newest project gets the wide card
projects/project.css  the shared style: the start page's look (top bar, colours, light and dark); projects/_template/
                      the pages with FILL IN marks (tutorial.html optional)
```
`tests/test_projects.py` checks all of it (files, sections, Resources first, links, no bitstreams, portal card,
start-page link, and that the project stands on its own).
The name is lower-case, no digits prefix (`pacman`, `snake`, `oscilloscope`); the top module is `<name>_top`.

**Resources first.** The overview opens with what the design uses, before anything else: logic elements (area),
registers, memory bits and M9K blocks, multipliers, PLLs and their outputs, pins, and every clock with its frequency,
Fmax and slack, and whether timing is met. `python scripts/de10.py report projects/<name> --html` writes the whole
section to `logs/resources.html` (with a "What uses it" column from the fitter's per-entity table): paste it, then add
a paragraph in plain words: what runs on each clock, what the biggest users are for, and what is only there for
testing (the debug screen buffer is 921,600 bits / 114 M9K and is not needed to run). Regenerate it after every build
that changes the numbers.

**A project stands on its own.** Everything it builds and simulates from is in its folder or in `lib/`. Never point
into `examples/` or another project: copy what you reuse (a module into `src/`, an IP into `ip/`), keep the copy
byte-identical if you can, and say on the pages where it came from. Work on one project then never changes another,
and a fix in an example never silently changes a published project. The test checks the `.qsf` file assignments, the
`// sim-sources:` lines and the scripts.

## The workflow

1. **Agree the scope** in a few lines: what it does, what proves it, what only a person can check. Which skills apply
   (`build-arcade-game`, `build-rom`, `read-screen`, ...): open them first.
2. **Build it in `projects/<name>/`** with the toolkit: `scripts/new_project.py`, `--lib` parts, a `sim/tb_<name>.sv`
   that exercises the design and prints PASS, `scripts/de10.py build` / `program`, then prove it on the board
   (`de10.py send` / `log` / `screen` / `cam`). Keep `logs/` for captures (ignored).
   **Math-heavy graphics (fft_lab, accel_cube): write a bit-exact model first**, `assets/model.py`, with the same
   integer formats, shifts and roundings the RTL will have, a `selftest` against plain floating point, a `constants`
   command that prints the RTL's localparams, `render <case> out.png` and a frame hash. Then the RTL copies the
   model line by line. Prove it three ways: a fast testbench on the engine alone that compares every intermediate
   number with the model's `dump` (one second; catches what no picture shows, gotcha 36), a slow testbench on the
   whole core with real video timing that hashes each frame (minutes to an hour), and the board: `de10.py send N`,
   `de10.py screen`, `model.py compare` (target 0 pixels). Add cases the presets cannot reach (angle corners, a
   held value, an arrow leaving its box); fixed test vectors over USB keep board checks independent of how the
   board lies.
3. **Review** before documenting. Read every source once, whole, and fix: width truncations (sized constants, sums
   through wires), double non-blocking writes to one register in a path, dead or unconnected signals (name them `_nc`),
   reserved words as names, every warning that comes from your files (`grep Warning logs/build.log | grep <file>`;
   the library's and "pin stuck at" ones are known). Re-simulate and rebuild after the review; keep the numbers.
4. **Pictures**: `media/screen_*.png` from `de10.py screen`, `media/board.jpg` from `de10.py cam` (crop if it helps),
   a preview or waveform if it explains something. Under 600 kB each. Choose one of them as the project's picture: the
   overview's cover, the small picture on the other pages, the portal card and the start page's strip all use it. A tutorial's pictures come from a script that
   checks each one against the model (below).
5. **Pages**: copy `projects/_template/*.html`, replace every `FILL IN` (delete `tutorial.html` when there is nothing to
   try). The overview answers "what will I see and why does it work"; the spec answers "where does every bit live and
   what are the budgets"; the guide answers "what do I type and what do I do when it looks wrong"; the tutorial answers
   "what can I try, what will I see, and why". Resources first, from `de10.py report --html` (above); the "Numbers" section
   keeps only what is not a resource (speed, latency, build time, warnings). The review log from step 3; the status table
   says what was verified by the machine, what only a person can check, and what was left out on purpose.
6. **Pack and link**: `de10.py pack projects/<name>` (the `.qar`), a card on `projects/index.html` (it takes over the
   wide card), a tile in the start page's project strip (`#stage3`, `div.projects`; its grid is laid out for five tiles, so a sixth
   means rebalancing it or choosing five), `README.md` if it changes the
   pitch. Quartus archives every file the last build read, so `pack` refuses when that includes files from outside
   the project and `lib/` (`build` warns): after moving sources, delete `db/` and `incremental_db/` in the build
   folder (the local copy, for a OneDrive project) and build again (gotcha 29). Prove the archive once: copy it to a path without spaces,
   `quartus_sh --restore <name>.qar -output out`, compile in `out\projects\<name>` with
   `quartus_sh --flow compile <name>` (the archive keeps the repo's layout, gotcha 57) and compare the Checksum in
   `output_files/<name>.asm.rpt` with your build's.
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
* Code and command lines on the pages: 100 characters at most (the page is 920 px wide; longer lines scroll).
* Evaluation IP (OpenCore Plus) is said on the overview's first screen, with what it means: a time-limited `.sof`,
  no flash, and what the design does when the time runs out (`use-ip-library`).

## The tutorial (optional fourth page)

Write `tutorial.html` when the design has things to try and ideas to learn from it: an instrument, a lab, a game with
rules worth explaining. The overview says what it is and why it works, the guide how to run it; the tutorial says what
to try, what you will see and why. The model is `projects/fft_lab/tutorial.html`, the template
`projects/_template/tutorial.html`; its styles (`.do`, `.tour`, `details`, `td.n`) are in `projects/project.css`.

* **The order**: before you start (load it, the defaults and how to get back to them, setting things over USB, the
  units) · a tour of the screen · the numbers behind the picture (a `table.kv` of rates, sizes, scales, formulas) ·
  the experiments, simplest first, each building on the one before · check yourself (questions, the answers folded in
  `<details>`) · words (a glossary with this design's numbers) · about the pictures · the footer.
* **The tour**: the start-up picture as an `<image>` in an inline SVG, with a dashed box and a numbered circle per zone
  (the `viewBox` reaches past the picture for the circles), then a table: zone, what it shows, an example of its text.
* **Each experiment has three parts.** `<div class="do"><b>Do:</b>`: the controls, and the same as USB letters so the
  chat can set it. `<div class="two">`: the real picture beside a "You should see" list with numbers (heights, counts,
  positions), not adjectives. `<p><b>Why.</b>`: the idea in plain words, the numbers that prove it, the name it goes by.
* **Pictures from the board, checked.** A `sim/tutorial_shots.py` sets each case over USB, takes `de10.py screen`
  between two report lines (again if the settings moved: someone touched the board), compares it with the model and
  copies it to `media/tutorial_<name>.png`; at the end it puts the settings back. "About the pictures" says which
  match the model whole, which except a part the model cannot predict (and why), which not at all (random, sound),
  and the command that takes them again.
* **Every number checked**: from the model, the report line, or measured on the picture; a constant read in the
  source. `de10.py screen` PNGs are 640 × 480, the 320 × 240 frame at twice its size: frame pixel (x, y) is at
  (2x, 2y). A number nobody checked comes off the page. Say what is for a person only (a sound, a feel).
* **Link it**: `nav.pages` on all four pages, a button and a pointer paragraph on the overview (after its pictures),
  the overview's Files table (the page and the script), a pointer in the guide's "Use it" (the tutorial's own footer
  already names the other three pages).
  `tests/test_projects.py` checks the links both ways, the three parts, and that every picture, file and anchor exists.

## Process notes

* Parallel shell calls share one working directory: a `cd` in one moves the other. Absolute paths in every command.
* CI runs on Ubuntu: a project test that needs a tool (Icarus...) must find it on PATH when the Windows install
  folder is absent (`scripts/sim.py` does: `oss_tool()`), and skip cleanly when it is nowhere. A path written as
  `C:/...` is relative on Linux (it lands in the checkout): build test paths from `ROOT` or `Path(ROOT.anchor, ...)`.
* On Windows `mv` of a folder fails with "Device or resource busy" while any shell has it as its working directory:
  run the move from the repo root.
* `de10.py program <dir>` finds `output_files/<rev>.sof` (or `_time_limited`); the pages say "build, then program the
  folder", never a path to a `.sof`.
* A template page must not contain `{{` or `BKM-TODO` (the hygiene test): the marks are `FILL IN`.
* `scripts/new_project.py` writes `SYNTH_RESOURCE_AWARE_INFERENCE_FOR_BLOCK_RAM OFF`. With the MAX 10 default (On),
  synthesis silently builds inferred RAMs and ROMs from flip-flops when it guesses M9K blocks are scarce (the 114-M9K
  debug buffer makes it guess so): fft_lab built at 19,381 LEs instead of 7,183, with no message. The sign in the area table of
  `de10.py report`: a module with many registers and 0 memory bits. Projects made before the fix (pacman,
  riscv_tetris) still have it On: regenerate, rebuild and re-check them on the board when you next work on them.
* One board, two chats: when another session builds and programs the same board, take turns. Stop your own pollers
  (`de10.py log`, watch scripts) before it programs, and never program while it is testing.
* Long board watches (an untethered evaluation IP for an hour): keep the PC awake while plugged in, or its USB port
  stops powering the board (gotcha 28).
* Write a long page in parts of about 8 kB (the fft_lab tutorial is 44 kB, written in seven): one write of the whole
  page can run past the reply's output limit and be lost. Then let `tests/test_projects.py` check its links and pictures.
* Write a long file (a model, a testbench, a page) in parts: `create` the first half, then `edit` the rest in. A
  one-shot `create` of 600 lines was cut short at the output limit and the file ended mid-function.
* Data files come from Python, never from PowerShell `>` (UTF-16 with a BOM; gotcha 35).
* Proving the archive (step 6) takes about 2 minutes: restore, `--flow compile`, compare the Checksum. Do it;
  a `.qar` that misses a `.mif` or a `lib/` file restores fine and only fails at compile.
* Before writing about timing margins, name the worst paths of each clock with `report_timing -to_clock` in a
  `quartus_sta -t` script (the whole command is in gotcha 54). A clock's slack can be set by a path from another
  clock of the same PLL (Fmax ignores those), and the slowest path can be the debug capture's, not the design's.
* Logs: never redirect a command's console into a file the command writes itself (`de10.py build` writes
  `logs/build.log`); copy a log aside before the next run empties it; a testbench task's message port keeps only
  as many characters as it is wide; count passed checks with `^ok:`, case-sensitive (gotcha 56).
* With `core.autocrlf=true` (Windows) the checkout's text files end their lines with CRLF. An edit script opens
  them with `newline=""` and writes back the same way; text mode shows it only LF (gotcha 58).
* `de10.py cam` can fail on a PC ("Error opening input files"): say so in the status table and ask the user for a
  phone photo of the board instead of leaving `media/board.jpg` out silently.
* Checking the 100-character page rule without reading every page: a few lines of Python that pull each `<pre>`
  block, strip the tags, unescape `&gt; &lt; &amp;` and print the lines longer than 100.
