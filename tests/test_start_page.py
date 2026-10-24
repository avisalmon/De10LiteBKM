"""The start page is the link that goes to people. This BKM is English only (Avi, 2026-10-24), so the template's
Hebrew/English pairing checks became: English, no leftover Hebrew, and the three stages all present."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HTML = (ROOT / "index.html").read_text(encoding="utf-8")


def test_the_page_is_english():
    assert '<html lang="en">' in HTML
    assert not re.search(r"[֐-׿]", HTML), "Hebrew text left on an English-only page"


def test_the_page_shows_the_three_stages():
    for must in ('id="stage1"', 'id="stage2"', 'id="stage3"', "lessons/00_setup/index.html", "examples/index.html"):
        assert must in HTML, must


def test_the_page_hands_over_to_the_ai():
    for must in ("git clone https://github.com/avisalmon/De10LiteBKM.git", "Git: Clone", "Tell me what to do",
                 "code.visualstudio.com", "git-scm.com"):  # fmt: skip
        assert must in HTML, must


def test_the_terminal_is_explained_before_it_is_used():
    """Most people have never seen a command line: clone with clicks first, and explain the terminal before any command."""
    assert HTML.index("What is a terminal?") < HTML.index("git clone https://")
    for must in ("New Terminal", "prompt", "Ctrl</kbd>+<kbd>V", "Red text"):
        assert must in HTML, must


def test_local_images_exist():
    visible = re.sub(r"<!--.*?-->", "", HTML, flags=re.S)  # a commented-out example is not an image to load
    for src in re.findall(r'src="(assets/[^"]+)"', visible):
        assert (ROOT / src).exists(), src


def test_storage_use_survives_blocked_storage():
    """Private windows and some school browsers throw on localStorage: any use must be guarded."""
    calls = re.findall(r"localStorage\.\w+", HTML)
    guarded = re.findall(r"try \{[^}]*localStorage\.\w+", HTML)
    assert len(guarded) == len(calls)
