# Project template

Copy this folder to `projects/<name>/` (the `make-project` skill does it), replace every `FILL IN` in the three pages,
and keep the sections: `tests/test_projects.py` checks them. The pages share `../project.css`.

```text
projects/<name>/
  index.html        overview: what, what you will see, block diagram (inline SVG), how it flows, how it was tested,
                    review log, status, files
  spec.html         architecture spec: requirements, modules and ports, clock domains, memories, state encodings,
                    budgets, design decisions
  guide.html        user guide: need, build and load, use, test over USB, flash, simulate, change, troubleshoot
  <name>.qar        the Quartus archive (python scripts/de10.py pack projects/<name>)
  <name>.qpf/.qsf/.sdc  generated (python scripts/new_project.py projects/<name> <top> --lib ...)
  src/ sim/ assets/ media/
```

No `.sof` / `.pof` in git (ignored); `logs/`, `db/`, `output_files/` are ignored too.
