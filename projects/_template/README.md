# Project template

Copy this folder to `projects/<name>/` (the `make-project` skill does it), replace every `FILL IN` in the three pages,
and keep the sections: `tests/test_projects.py` checks them. The pages share `../project.css`. `tutorial.html` is the
optional fourth page: keep it when the design has things to try and ideas to learn from it, or delete it.

```text
projects/<name>/
  index.html        overview: Resources FIRST (area, registers, memory bits and M9K, multipliers, PLLs, pins, every
                    clock with its Fmax and slack: python scripts/de10.py report projects/<name> --html writes it to
                    logs/resources.html), then what you will see, block diagram (inline SVG), how it flows, numbers,
                    how it was tested, review log, status, files
  spec.html         architecture spec: requirements, modules and ports, clock domains, memories, state encodings,
                    budgets, design decisions
  guide.html        user guide: need, build and load, use, test over USB, flash, simulate, change, troubleshoot
  tutorial.html     optional: a tour of the screen, the numbers behind it, experiments (do / you should see, on a real
                    board picture / why), a quiz, the words, about the pictures (sim/tutorial_shots.py takes them)
  <name>.qar        the Quartus archive (python scripts/de10.py pack projects/<name>)
  <name>.qpf/.qsf/.sdc  generated (python scripts/new_project.py projects/<name> <top> --lib ...)
  src/ sim/ assets/ media/   (ip/ for generated Altera IP)
```

No `.sof` / `.pof` in git (ignored); `logs/`, `db/`, `output_files/` are ignored too.

**A project stands on its own.** Everything it builds and simulates from is in its folder or in `lib/`. It never points
into `examples/` or another project: copy what you reuse into `src/` (or `ip/`) and say where it came from on the pages.
Work on one project then never changes another. `tests/test_projects.py` checks the `.qsf`, the `sim-sources:` lines
and the scripts.
