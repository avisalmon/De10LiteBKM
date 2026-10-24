#!/usr/bin/env python
"""The course's progress file and lesson helpers (stage 2 lessons in lessons/NN_name/). Standard library only.

  python scripts/lesson.py status                 where the student is: current lesson, checks passed
  python scripts/lesson.py open  <N> [slide]      open lesson N's slides in the browser (at a slide)
  python scripts/lesson.py start <N>              copy the lesson's work files to my_designs/lessons/NN_name/
  python scripts/lesson.py check <N> <name>       record that check <name> passed (only after you verified it)
  python scripts/lesson.py done  <N>              all checks passed -> mark the lesson done, print the completion code
  python scripts/lesson.py code-hash <N>          (maintainer) the hash the lesson page embeds to accept the code

Progress lives in my_designs/lessons/progress.json (git-ignored, the student's own). Each lesson's checks are
listed in lessons/NN_name/lesson.json; its coaching script is lessons/NN_name/coach.md.
"""

import datetime
import json
import os
import shutil
import sys
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LESSONS = ROOT / "lessons"
WORK = ROOT / "my_designs" / "lessons"
PROGRESS = WORK / "progress.json"
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I: easy to read off the screen
# Never copied to the student: build output and generated project files (the coach regenerates those)
SKIP = {"db", "incremental_db", "output_files", "logs", "work", "transcript", "greybox_tmp"}


def lesson(n):
    for d in sorted(LESSONS.glob(f"{int(n):02d}_*")):
        if (d / "lesson.json").exists():
            meta = json.loads((d / "lesson.json").read_text(encoding="utf-8"))
            meta["dir"] = d
            return meta
    sys.exit(f"FAIL: no lesson {n} in {LESSONS}")


def load():
    if PROGRESS.exists():
        return json.loads(PROGRESS.read_text(encoding="utf-8"))
    return {"current": 0, "lessons": {}}


def save(progress):
    WORK.mkdir(parents=True, exist_ok=True)
    PROGRESS.write_text(json.dumps(progress, indent=2) + "\n", encoding="utf-8")


def entry(progress, n):
    return progress["lessons"].setdefault(str(int(n)), {"started": None, "checks": [], "done": None})


def fnv1a(text):
    """32-bit FNV-1a: the same few lines run in the lesson page's JavaScript."""
    h = 0x811C9DC5
    for byte in text.encode("utf-8"):
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    return h


def code(meta):
    h = fnv1a(f"de10lite/{meta['slug']}")
    chars = "".join(ALPHABET[(h >> (5 * i)) & 31] for i in range(5))
    return f"L{meta['id']:02d}-{chars}"


def today():
    return datetime.date.today().isoformat()


def cmd_status():
    progress = load()
    print(f"Current lesson: {progress['current']}")
    for n, e in sorted(progress["lessons"].items(), key=lambda kv: int(kv[0])):
        meta = lesson(n)
        state = f"done {e['done']}" if e["done"] else f"checks {len(e['checks'])}/{len(meta['checks'])}"
        print(f"  {int(n):2d} {meta['title']}: {state}")
        if not e["done"]:
            for name in meta["checks"]:
                print(f"       [{'x' if name in e['checks'] else ' '}] {name}")
    return 0


def cmd_open(n, slide=None):
    """Windows drops '#slide' from a file URL it opens, so open a one-line redirect page instead."""
    meta = lesson(n)
    page = (meta["dir"] / "index.html").relative_to(ROOT).as_posix()
    WORK.mkdir(parents=True, exist_ok=True)
    jump = WORK / "open.html"
    target = "../../" + page + (f"#{int(slide)}" if slide else "")
    jump.write_text(f'<!doctype html><meta charset="utf-8"><title>Opening lesson {meta["id"]}</title>'
                    f'<script>location.replace("{target}")</script><a href="{target}">Open the lesson</a>\n',
                    encoding="utf-8")
    webbrowser.open(jump.as_uri())
    print(f"OK: opened lesson {meta['id']} ({page}{'#' + str(slide) if slide else ''})")
    return 0


def cmd_start(n):
    meta = lesson(n)
    dest = WORK / meta["slug"]
    for rel in meta.get("work", []):
        src = meta["dir"] / rel
        out = dest / rel
        if out.exists():
            print(f"kept: {out.relative_to(ROOT)} already exists (the student's work is never overwritten)")
            continue
        if src.is_dir():
            shutil.copytree(src, out, ignore=shutil.ignore_patterns(*SKIP))
        else:
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, out)
        print(f"copied: {out.relative_to(ROOT)}")
    progress = load()
    progress["current"] = meta["id"]
    e = entry(progress, n)
    e["started"] = e["started"] or today()
    save(progress)
    print(f"OK: lesson {meta['id']} started, work folder {dest.relative_to(ROOT)}")
    return 0


def cmd_check(n, name):
    meta = lesson(n)
    if name not in meta["checks"]:
        sys.exit(f"FAIL: lesson {meta['id']} has no check '{name}' (it has: {', '.join(meta['checks'])})")
    progress = load()
    e = entry(progress, n)
    if name not in e["checks"]:
        e["checks"].append(name)
    save(progress)
    left = [c for c in meta["checks"] if c not in e["checks"]]
    print(f"OK: {name} passed. " + (f"Left: {', '.join(left)}" if left else "All checks passed: run done."))
    return 0


def cmd_done(n):
    meta = lesson(n)
    progress = load()
    e = entry(progress, n)
    left = [c for c in meta["checks"] if c not in e["checks"]]
    if left:
        print(f"FAIL: not yet, still to pass: {', '.join(left)}")
        return 1
    e["done"] = e["done"] or today()
    progress["current"] = max(progress["current"], meta["id"] + 1)
    save(progress)
    print(f"OK: lesson {meta['id']} done. Completion code: {code(meta)}")
    return 0


def cmd_code_hash(n):
    meta = lesson(n)
    print(f"code {code(meta)}  page hash {fnv1a(code(meta))}")
    return 0


def main(argv):
    commands = {"status": cmd_status, "open": cmd_open, "start": cmd_start, "check": cmd_check, "done": cmd_done,
                "code-hash": cmd_code_hash}
    if not argv or argv[0] not in commands:
        print(__doc__)
        return 2
    try:
        return commands[argv[0]](*argv[1:])
    except TypeError:
        print(__doc__)
        return 2


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main(sys.argv[1:]))
