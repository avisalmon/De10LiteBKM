"""Every project under projects/ follows the standard folder (make-project skill): the three pages, the .qar, the sources,
no bitstreams, and the portal links it. The template folder is exempt from the content checks but must stay complete."""

import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PROJECTS = ROOT / "projects"
TEMPLATE = PROJECTS / "_template"
PAGES = ("index.html", "spec.html", "guide.html")
PROJECT_DIRS = sorted(p for p in PROJECTS.iterdir() if p.is_dir() and not p.name.startswith("_"))


def test_the_template_has_every_standard_file():
    for page in PAGES:
        assert (TEMPLATE / page).exists(), page
    assert (TEMPLATE / "README.md").exists()


@pytest.mark.parametrize("project", [p.name for p in PROJECT_DIRS])
def test_project_has_the_standard_folder(project):
    folder = PROJECTS / project
    for page in PAGES:
        assert (folder / page).exists(), f"{project}/{page} missing"
    assert list(folder.glob("*.qar")), f"{project}: no .qar (python scripts/de10.py pack projects/{project})"
    assert (folder / "src").is_dir() and list((folder / "src").glob("*.sv")) + list((folder / "src").glob("*.v"))
    assert (folder / "sim").is_dir() and list((folder / "sim").glob("tb_*.sv")), f"{project}: no testbench in sim/"
    assert (folder / "media").is_dir() and list((folder / "media").glob("*.png")) + list((folder / "media").glob("*.jpg"))
    tracked = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", f"projects/{project}"], cwd=ROOT,
                             capture_output=True, text=True).stdout.splitlines()
    assert not [f for f in tracked if f.endswith((".sof", ".pof"))], f"{project}: bitstreams are not committed"
    assert (folder / f"{project}.qpf").exists(), f"{project}: project files (scripts/new_project.py)"


@pytest.mark.parametrize("project", [p.name for p in PROJECT_DIRS])
def test_project_pages_are_linked_and_complete(project):
    folder = PROJECTS / project
    for page in PAGES:
        text = (folder / page).read_text(encoding="utf-8")
        assert '<html lang="en">' in text and "../project.css" in text, f"{project}/{page}: the shared style"
        for other in PAGES:
            assert f'href="{other}"' in text, f"{project}/{page} does not link {other}"
        assert '<nav class="crumbs">' in text and 'href="../index.html"' in text, f"{project}/{page}: crumbs to the portal"
        assert "FILL IN" not in text and "{{" not in text, f"{project}/{page}: template text left"
    index = (folder / "index.html").read_text(encoding="utf-8")
    for section in ("Block diagram", "How", "tested", "Review", "Status", "Files"):
        assert section in index, f"{project}/index.html lacks a '{section}' section"
    assert "<svg" in index, f"{project}/index.html: the block diagram is an inline SVG"
    assert f'href="{project}.qar"' in index, f"{project}/index.html: the .qar download"
    spec = (folder / "spec.html").read_text(encoding="utf-8")
    for section in ("Requirements", "Modules", "Clock", "Memor", "Budget", "decisions"):
        assert section in spec, f"{project}/spec.html lacks a '{section}' section"
    guide = (folder / "guide.html").read_text(encoding="utf-8")
    for must in ("de10.py build", "de10.py program", "scripts/sim.py"):
        assert must in guide, f"{project}/guide.html: '{must}'"


def test_the_portal_lists_every_project_and_the_start_page_links_the_portal():
    portal = (PROJECTS / "index.html").read_text(encoding="utf-8")
    for p in PROJECT_DIRS:
        assert f'href="{p.name}/index.html"' in portal, f"projects/index.html does not list {p.name}"
    for card in re.findall(r'href="([^"]+)/index.html"', portal):
        assert (PROJECTS / card / "index.html").exists(), f"portal links a missing project: {card}"
    start = (ROOT / "index.html").read_text(encoding="utf-8")
    assert 'href="projects/index.html"' in start, "the start page links the projects portal"
    assert "projects/" in (ROOT / "README.md").read_text(encoding="utf-8")


def test_media_is_small():
    """Pictures on the pages, not archives of them: keeps the repo quick to clone."""
    for p in PROJECT_DIRS:
        for f in (p / "media").iterdir():
            assert f.stat().st_size < 600_000, f"{f.relative_to(ROOT)} is over 600 kB: resize it"
