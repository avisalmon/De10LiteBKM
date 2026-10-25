"""The course's lessons (lessons/NN_name/): each one is a slide page, a coach file and a lesson.json, and the page
carries no completion code any more: the chat tracks progress."""

import json
import re
from pathlib import Path

import lesson as course
import pytest

ROOT = Path(__file__).resolve().parent.parent
LESSONS = sorted(p for p in (ROOT / "lessons").iterdir() if p.is_dir())


def test_there_is_a_lesson_zero():
    assert LESSONS and LESSONS[0].name == "00_setup"


@pytest.mark.parametrize("folder", LESSONS, ids=lambda p: p.name)
def test_a_lesson_has_its_three_parts(folder):
    meta = json.loads((folder / "lesson.json").read_text(encoding="utf-8"))
    assert folder.name == meta["slug"] and folder.name.startswith(f"{meta['id']:02d}_")
    assert meta["checks"], "a lesson with nothing to check proves nothing"
    for rel in meta.get("work", []):
        assert (folder / rel).exists(), rel
    coach = (folder / "coach.md").read_text(encoding="utf-8")
    for name in meta["checks"]:
        assert f"lesson.py check {meta['id']} {name}" in coach, f"coach.md never records the check '{name}'"



@pytest.mark.parametrize("folder", LESSONS, ids=lambda p: p.name)
def test_no_completion_code_left(folder):
    html = (folder / "index.html").read_text(encoding="utf-8")
    assert "CODE_HASH" not in html and "code-form" not in html

@pytest.mark.parametrize("folder", LESSONS, ids=lambda p: p.name)
def test_the_page_works_with_blocked_storage(folder):
    html = (folder / "index.html").read_text(encoding="utf-8")
    calls = re.findall(r"localStorage\.\w+", html)
    guarded = re.findall(r"try \{[^}]*localStorage\.\w+", html)
    assert calls and len(guarded) == len(calls)


@pytest.mark.parametrize("folder", LESSONS, ids=lambda p: p.name)
def test_local_images_exist(folder):
    html = (folder / "index.html").read_text(encoding="utf-8")
    for src in re.findall(r'src="(?!https?:)([^"]+)"', html):
        assert (folder / src).exists(), src


@pytest.mark.parametrize("folder", LESSONS, ids=lambda p: p.name)
def test_the_student_works_only_in_their_copy(folder):
    """lessons/ is the course itself. A coach.md may show slides and run checkers from it, but every file the student
    opens, edits, simulates or builds must be their copy under my_designs/ (or they would change the course)."""
    coach = (folder / "coach.md").read_text(encoding="utf-8")
    for path in re.findall(r"(?<![\w/])lessons/[\w./-]+", coach):
        allowed = path.endswith("index.html") or re.fullmatch(r"lessons/\w+/check_\w+\.py", path) \
            or re.fullmatch(r"lessons/\w+/[\w/]*src", path) or path.rstrip("/") == "lessons"
        assert allowed, f"{folder.name}/coach.md sends the student into the course itself: {path}"
