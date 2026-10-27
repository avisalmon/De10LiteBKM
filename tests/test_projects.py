"""Every project under projects/ follows the standard folder (make-project skill): the three pages and the optional
tutorial, the .qar, the sources, no bitstreams, and the portal links it. The template folder is exempt from the content
checks but must stay complete."""

import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PROJECTS = ROOT / "projects"
TEMPLATE = PROJECTS / "_template"
PAGES = ("index.html", "spec.html", "guide.html")
TUTORIAL = "tutorial.html"  # the optional fourth page
TUTORIAL_PARTS = ('class="do"', "You should see", "<b>Why")  # every experiment: Do, You should see, Why
PROJECT_DIRS = sorted(p for p in PROJECTS.iterdir() if p.is_dir() and not p.name.startswith("_"))
# Made before the "Resources first" rule; adding their section needs a rebuild each (follow-up in docs/backlog.md).
RESOURCES_LATER = {"pacman", "riscv_tetris"}
RESOURCE_WORDS = ("Logic elements", "Memory bits", "M9K", "PLLs", "Fmax", "Timing")
CODE_TYPES = {".sv", ".v", ".svh", ".vh", ".py", ".tcl", ".qsf", ".qip", ".sdc", ".c", ".h", ".s"}


def first_section(html):
    """(title, body) of the page's first <h2>: the text up to the next <h2>."""
    m = re.search(r"<h2[^>]*>(.*?)</h2>(.*?)(?=<h2|\Z)", html, re.S)
    return (m.group(1).strip(), m.group(2)) if m else ("", "")


def test_the_template_has_every_standard_file():
    for page in PAGES:
        assert (TEMPLATE / page).exists(), page
    assert (TEMPLATE / "README.md").exists()


def test_the_template_starts_with_resources():
    title, body = first_section((TEMPLATE / "index.html").read_text(encoding="utf-8"))
    assert title == "Resources", "projects/_template/index.html: the first section is Resources"
    for word in RESOURCE_WORDS:
        assert word in body, f"the template's Resources section lacks '{word}'"


@pytest.mark.parametrize("project", [p.name for p in PROJECT_DIRS])
def test_project_overview_starts_with_resources(project):
    """Every project page opens with what it uses: area, memory, multipliers, PLLs, clocks with Fmax, timing."""
    if project in RESOURCES_LATER:
        pytest.skip(f"{project} was made before the Resources rule (follow-up)")
    title, body = first_section((PROJECTS / project / "index.html").read_text(encoding="utf-8"))
    assert title == "Resources", (f"{project}/index.html: the first section must be Resources "
                                  f"(python scripts/de10.py report projects/{project} --html)")
    for word in RESOURCE_WORDS:
        assert word in body, f"{project}/index.html: the Resources section lacks '{word}'"


@pytest.mark.parametrize("project", [p.name for p in PROJECT_DIRS])
def test_project_stands_on_its_own(project):
    """A project builds and simulates from its own folder and lib/ only: never from examples/ or another project
    (copy what you reuse), so work on one project never changes another."""
    folder = PROJECTS / project
    homes = (folder.resolve(), (ROOT / "lib").resolve())
    inside = lambda p: any(p == h or h in p.parents for h in homes)
    qsf = (folder / f"{project}.qsf").read_text(encoding="utf-8")
    for path in re.findall(r"-name \w+_FILE\s+\"?([^\"\s]+)", qsf):
        assert inside((folder / path).resolve()), f"{project}.qsf uses {path}: outside the project and lib/"
    for tb in (folder / "sim").glob("*.sv"):
        for line in tb.read_text(encoding="utf-8", errors="replace").splitlines():
            if "sim-sources:" in line:
                for path in line.split("sim-sources:", 1)[1].split():
                    p = ((tb.parent if path.startswith(".") else ROOT) / path).resolve()
                    assert inside(p), f"{tb.relative_to(ROOT)} simulates {path}: outside the project and lib/"
    others = "|".join(re.escape(p.name) for p in PROJECT_DIRS if p.name != project) or "(?!)"
    reach = re.compile(r"\bexamples[/\\]|[\"']examples[\"']|\bprojects[/\\](?:" + others + r")\b")
    for f in folder.rglob("*"):
        if f.suffix.lower() in CODE_TYPES and f.is_file():
            m = reach.search(f.read_text(encoding="utf-8", errors="replace"))
            assert not m, f"{f.relative_to(ROOT)} reaches outside the project: '{m.group(0)}'"


def test_pack_sees_files_the_build_read_from_outside_the_project(tmp_path):
    """de10.py pack refuses (build warns) when Quartus read repo files from outside the project and lib/: a .qar holds
    every file the last build read, also the ones an older .qsf listed that db/ still remembers (docs/gotchas.md)."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import de10
    proj = tmp_path / "demo"
    (proj / "output_files").mkdir(parents=True)
    (proj / "demo.qpf").write_text("")
    # Quartus' own library file: absolute on this OS (CI runs on Linux, where "C:/..." would be a relative path)
    read = [proj / "src" / "top.sv", ROOT / "lib" / "rtl" / "pll25.v", ROOT / "examples" / "11_fft" / "src" / "fft_r2.sv",
            Path(ROOT.anchor, "intelFPGA_lite", "17.1", "quartus", "libraries", "megafunctions", "altpll.tdf")]
    (proj / "output_files" / "demo.map.rpt").write_text(
        "; Analysis & Synthesis Source Files Read ;\n+--+\n"
        "; File Name with User-Entered Path ; Used in Netlist ; File Type ; File Name with Absolute Path ; Library ;\n"
        "+--+\n" + "".join(f"; {p.name} ; yes ; User File ; {p.as_posix()} ; ;\n" for p in read) + "+--+\n")
    assert de10.outside_files(str(proj)) == ["fft_r2.sv"]


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


def test_the_template_has_the_optional_tutorial():
    """The fourth page, for a design with things to try: a tour of the screen, experiments, a quiz, the pictures' story."""
    text = (TEMPLATE / TUTORIAL).read_text(encoding="utf-8")
    for part in TUTORIAL_PARTS + ('class="tour"', "<details>", 'id="pictures"', 'class="here" href="tutorial.html"'):
        assert part in text, f"projects/_template/tutorial.html lacks {part}"


@pytest.mark.parametrize("project", [p.name for p in PROJECT_DIRS if (p / TUTORIAL).exists()])
def test_project_tutorial_is_linked_and_complete(project):
    """A project's tutorial is one of its pages: the shared style, crumbs, linked with the other three both ways, no
    template text, the experiments' three parts, and every picture, file and anchor it points at exists."""
    folder = PROJECTS / project
    text = (folder / TUTORIAL).read_text(encoding="utf-8")
    assert '<html lang="en">' in text and "../project.css" in text, f"{project}/{TUTORIAL}: the shared style"
    assert '<nav class="crumbs">' in text and 'href="../index.html"' in text, f"{project}/{TUTORIAL}: crumbs to the portal"
    assert "FILL IN" not in text and "{{" not in text, f"{project}/{TUTORIAL}: template text left"
    for part in TUTORIAL_PARTS:
        assert part in text, f"{project}/{TUTORIAL}: each experiment has Do, You should see and Why (no '{part}')"
    for page in PAGES:
        assert f'href="{page}"' in text, f"{project}/{TUTORIAL} does not link {page}"
        other = (folder / page).read_text(encoding="utf-8")
        assert f'href="{TUTORIAL}"' in other, f"{project}/{page} does not link the tutorial"
    for target in re.findall(r'\b(?:src|href)="([^"]+)"', text):
        if re.match(r"[a-z]+:", target):  # https:, mailto:
            continue
        path, _, anchor = target.partition("#")
        page = (folder / path).resolve() if path else folder / TUTORIAL
        assert page.exists(), f"{project}/{TUTORIAL} points at a missing file: {target}"
        if anchor:
            assert f'id="{anchor}"' in page.read_text(encoding="utf-8"), f"{project}/{TUTORIAL}: no id '{anchor}' ({target})"


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
