"""The Space Invaders project: the sprite tables in src/ are what the art in assets/make_sprites.py makes, and (when
Icarus Verilog is installed) the QUICK system testbench passes: the attract mode, coins, a game played by its bot, the
game's rules checked after every step, and presets 0 to 2 rendered."""

import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "projects" / "invaders"
ICARUS = shutil.which("iverilog") is not None or Path(r"C:\oss-cad-suite-20261009").exists()


def test_sprite_tables_are_what_the_art_makes():
    # src/inv_sprites.sv is generated: edit the art in assets/make_sprites.py and run it, never the .sv by hand
    spec = importlib.util.spec_from_file_location("invaders_make_sprites", PROJECT / "assets" / "make_sprites.py")
    art = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(art)
    assert (PROJECT / "src" / "inv_sprites.sv").read_text(encoding="utf-8") == art.build_sv()


@pytest.mark.skipif(not ICARUS, reason="Icarus Verilog not installed")
def test_quick_system_testbench_passes():
    # about 3 minutes: 10,093 game steps of the whole design with real video timing
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "sim.py"), str(PROJECT / "sim" / "tb_invaders.sv"),
                        "-D", "QUICK"], cwd=ROOT, capture_output=True, text=True, timeout=1800)
    assert r.returncode == 0 and "PASS (" in r.stdout, r.stdout[-3000:]
