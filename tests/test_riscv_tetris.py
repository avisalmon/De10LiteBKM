"""The RISC-V Tetris project's toolchain and CPU: the assembler and C compiler against the instruction-set simulator
(always), the RTL CPU in lock-step with the simulator (when Icarus Verilog is installed), and the memory map shared by
the Python tools and the Verilog."""

import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "projects" / "riscv_tetris"
TOOLS = PROJECT / "tools"
BUILD = PROJECT / "build"
PY = sys.executable


def run(*args, cwd=ROOT, timeout=900):
    return subprocess.run([PY, *map(str, args)], cwd=cwd, capture_output=True, text=True, timeout=timeout)


@pytest.fixture(scope="module")
def images():
    BUILD.mkdir(exist_ok=True)
    for src in ("test_isa.s", "test_c.c", "tetris.c"):
        r = run(TOOLS / "build.py", PROJECT / "sw" / src, "-o", BUILD / Path(src).stem)
        assert r.returncode == 0, r.stdout + r.stderr
    return BUILD


def test_isa_test_passes_on_the_simulator(images):
    r = run(TOOLS / "rv32sim.py", images / "test_isa.hex", "--trace", images / "test_isa.trc")
    assert r.returncode == 0 and "exit 0" in r.stdout, r.stdout
    assert "UART: OK" in r.stdout


def test_c_suite_passes_on_the_simulator(images):
    r = run(TOOLS / "rv32sim.py", images / "test_c.hex", "--trace", images / "test_c.trc")
    assert r.returncode == 0 and "exit 0" in r.stdout, r.stdout
    assert "failures 0" in r.stdout


def test_tetris_plays_on_the_simulator(images):
    # seed 0x1d481499: the blind script clears a line (found with play_test.py --search), so scoring, line clearing
    # and the BCD digits are all exercised
    r = run(TOOLS / "play_test.py", "--hex", images / "tetris.hex", "--seed", "0x1d481499", "--quiet",
            "--expect-lines", "1", timeout=600)
    assert r.returncode == 0, r.stdout[-2000:]


def test_the_compiler_rejects_what_it_does_not_support(tmp_path):
    bad = tmp_path / "bad.c"
    bad.write_text("struct p { int x; };\nint main(void) { return 0; }\n", encoding="utf-8")
    r = run(TOOLS / "cc.py", bad, "-o", tmp_path / "bad.s", "-I", PROJECT / "sw")
    assert r.returncode != 0 and "bad.c:1" in r.stdout


def test_memory_map_is_the_same_in_python_and_verilog():
    sys.path.insert(0, str(TOOLS))
    import memmap
    soc = (PROJECT / "src" / "rv32_soc.sv").read_text(encoding="utf-8")
    header = (PROJECT / "sw" / "soc.h").read_text(encoding="utf-8")
    for name, off in memmap.IO.items():
        assert f"#define IO_{name} (*(volatile int *)0x{memmap.IO_BASE + off:08X})" in header, name
        if name in ("HEX", "LEDS", "BUZZER", "UART", "EXIT", "BUTTONS", "FRAME", "RANDOM", "SWITCHES", "CYCLES"):
            assert f"6'h{off // 4:02X}:" in soc, f"{name} at word {off // 4} missing in rv32_soc.sv"
    assert "addr[31:28] == 4'h1" in soc and memmap.TEXT_BASE == 0x1000_0000
    assert "addr[31:28] == 4'h2" in soc and memmap.IO_BASE == 0x2000_0000


@pytest.mark.skipif(shutil.which("iverilog") is None and not Path(r"C:\oss-cad-suite-20261009").exists(),
                    reason="Icarus Verilog not installed")
@pytest.mark.parametrize("prog", ["test_isa", "test_c"])
def test_rtl_cpu_matches_the_simulator_in_lock_step(images, prog):
    r = run(ROOT / "scripts" / "sim.py", PROJECT / "sim" / "tb_soc.sv", "-D", f'PROG="../build/{prog}.hex"',
            "-D", f'TRACE="../build/{prog}_rtl.trc"', timeout=1500)
    assert "PASS" in r.stdout, r.stdout[-3000:]
    r = run(TOOLS / "trace_compare.py", images / f"{prog}.trc", images / f"{prog}_rtl.trc")
    assert r.returncode == 0, r.stdout[-3000:]
