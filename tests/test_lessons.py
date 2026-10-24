"""The course's lessons (lessons/NN_name/): each one is a slide page, a coach file and a lesson.json, and the page
accepts exactly the completion code that scripts/lesson.py hands out."""

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
def test_the_page_accepts_the_code_the_chat_gives(folder):
    meta = course.lesson(json.loads((folder / "lesson.json").read_text(encoding="utf-8"))["id"])
    html = (folder / "index.html").read_text(encoding="utf-8")
    embedded = int(re.search(r"var CODE_HASH = (\d+);", html).group(1))
    assert embedded == course.fnv1a(course.code(meta)), "run: python scripts/lesson.py code-hash N, paste into the page"


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
