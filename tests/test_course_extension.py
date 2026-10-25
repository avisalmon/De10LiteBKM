"""The VS Code slide viewer (tools/vscode-course) packs into a .vsix VS Code accepts, and keeps its contract with
scripts/lesson.py (show.json in, slides.json out) and with the lesson pages (the #dots buttons)."""

import json
import zipfile
from pathlib import Path

import course_extension

ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / "tools" / "vscode-course"


def test_the_vsix_has_the_manifest_and_the_code():
    assert course_extension.build() == 0
    with zipfile.ZipFile(course_extension.OUT) as z:
        names = set(z.namelist())
        assert {"[Content_Types].xml", "extension.vsixmanifest", "extension/package.json", "extension/extension.js"} <= names
        manifest = z.read("extension.vsixmanifest").decode()
    pkg = json.loads((EXT / "package.json").read_text(encoding="utf-8"))
    assert f'Id="{pkg["name"]}"' in manifest and f'Publisher="{pkg["publisher"]}"' in manifest


def test_it_runs_in_untrusted_folders_and_starts_by_itself():
    """A freshly cloned course opens in Restricted Mode, where extensions without this flag never start."""
    pkg = json.loads((EXT / "package.json").read_text(encoding="utf-8"))
    assert pkg["capabilities"]["untrustedWorkspaces"]["supported"] is True
    assert "onStartupFinished" in pkg["activationEvents"]


def test_the_files_it_shares_with_lesson_py():
    js = (EXT / "extension.js").read_text(encoding="utf-8")
    py = (ROOT / "scripts" / "lesson.py").read_text(encoding="utf-8")
    for name in ("show.json", "slides.json"):
        assert name in js and name in py, name


def test_every_lesson_page_has_the_slide_dots_it_drives():
    for page in (ROOT / "lessons").glob("*/index.html"):
        assert 'id="dots"' in page.read_text(encoding="utf-8"), page
