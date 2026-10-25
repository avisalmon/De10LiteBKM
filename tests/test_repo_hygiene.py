"""Things that must never land in a public repo people clone, and a BKM that still has blanks in it."""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def tracked_files():
    done = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, capture_output=True, text=True)
    return [ROOT / line for line in done.stdout.splitlines() if line]


def text_files():
    for path in tracked_files():
        if path.exists() and path.suffix not in (".bin", ".png", ".jpg", ".pdf", ".zip"):
            yield path, path.read_text(encoding="utf-8", errors="ignore")


def test_virtualenv_secrets_and_user_work_are_ignored():
    ignore = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    for must in ("env/", ".env", "my_designs/*", "!my_designs/README.md"):
        assert must in ignore, must
    files = {p.relative_to(ROOT).as_posix() for p in tracked_files()}
    assert not any(f.startswith("env/") for f in files)
    assert {f for f in files if f.startswith("my_designs/")} <= {"my_designs/README.md"}


def test_no_passwords_or_keys_in_code_or_docs():
    pattern = re.compile(r"""(password|passwd|pswd|api_key|apikey|secret|token)\s*=\s*["'][^"'.{}<>]{6,}["']""", re.I)
    for path, text in text_files():
        assert not pattern.search(text), f"looks like a secret in {path.relative_to(ROOT)}"


def test_relative_links_in_docs_point_at_real_files():
    link = re.compile(r"\]\((?!https?:|mailto:|#)([^)#\s]+)")
    for md in [ROOT / "README.md", ROOT / "CLAUDE.md", *ROOT.glob("docs/*.md"), *ROOT.glob(".claude/skills/*/SKILL.md")]:
        for target in link.findall(md.read_text(encoding="utf-8")):
            assert (md.parent / target).resolve().exists(), f"{md.relative_to(ROOT)} -> {target}"


def test_no_template_blanks_left():
    """The scaffold marks every place that needs the domain's content with "BKM-TODO:" or {{ }}. A BKM is not ready
    to publish while any are left: this test lists them all, as a to-do list."""
    blanks = []
    for path, text in text_files():
        if path.name == "test_repo_hygiene.py":
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if "BKM-TODO:" in line or re.search(r"\{\{[A-Z_]+\}\}", line):
                blanks.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()[:90]}")
    assert not blanks, "fill these in:\n" + "\n".join(blanks)


def test_what_a_student_or_a_test_run_leaves_behind_is_ignored():
    """Trying the course (as a student, or the maintainer testing it) must never show up in git status."""
    leftovers = [
        "my_designs/lessons/progress.json", "my_designs/lessons/notes.md", "my_designs/lessons/show.json",
        "my_designs/lessons/02_first_simulation/alarm/src/door_alarm.sv", "my_designs/PROGRESS.md",
        "lessons/00_setup/ready/db/x", "lessons/00_setup/ready/output_files/ready.sof", "lessons/00_setup/ready/logs/build.log",
        "lessons/02_first_simulation/alarm/sim/work/_info", "lessons/02_first_simulation/alarm/sim/transcript",
        "lessons/02_first_simulation/alarm/sim/vsim.wlf", "lessons/02_first_simulation/alarm/sim/wlft3x8a2b",
        "lessons/00_setup/ready/ready.qws", "lessons/00_setup/ready/ready.cdf", "logs/de10-course.vsix",
    ]
    done = subprocess.run(["git", "check-ignore", "--no-index", *leftovers], cwd=ROOT, capture_output=True, text=True)
    ignored = set(done.stdout.split())
    assert ignored == set(leftovers), f"not ignored: {sorted(set(leftovers) - ignored)}"
