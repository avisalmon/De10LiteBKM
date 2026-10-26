"""The FFT lab project: its tables and test vectors are what the model makes, the recorded answers of the Altera IP
belong to the model's inputs, and (when Icarus Verilog is installed) the unit testbenches pass and the system
testbench passes with every frame, screen picture and report line equal to the model."""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "projects" / "fft_lab"
SIM = PROJECT / "sim"
PY = sys.executable
sys.path.insert(0, str(SIM))
import lab_model as m  # noqa: E402
import record_ip  # noqa: E402

ICARUS = shutil.which("iverilog") is not None or Path(r"C:\oss-cad-suite-20261009").exists()


def run(*args, timeout=900):
    return subprocess.run([PY, *map(str, args)], cwd=ROOT, capture_output=True, text=True, timeout=timeout)


def test_assets_are_the_models_tables(tmp_path, monkeypatch):
    monkeypatch.setattr(m, "ASSETS", str(tmp_path))
    m.make()
    for name in ("sine.hex", "hann.hex", "twiddle.hex", "mag_rom.bin"):
        assert (tmp_path / name).read_text() == (PROJECT / "assets" / name).read_text(), name


def test_unit_test_vectors_are_the_models(tmp_path, monkeypatch):
    monkeypatch.setattr(m, "HERE", str(tmp_path))
    m.expect()
    for name in ("expect_wave.hex", "expect_mag.hex", "expect_fft.hex"):
        assert (tmp_path / name).read_text() == (SIM / name).read_text(), name


def test_the_recorded_ip_answers_every_case_of_the_recording():
    cases = m.load_ip_vectors()
    assert len(cases) == len(record_ip.CASES)
    for name in record_ip.CASES:
        st = m.frame_state(name, m.Gen(), cases)
        assert st["ip"] is not None, f"{name}: no recording for the model's input"
        assert st["ip"]["clk"] == m.IP_LATENCY + m.N and not st["ip"]["bad"], name


def test_report_line_is_126_characters_also_when_the_ip_fails():
    for fault in (None, "dead", "zero"):
        st = m.frame_state("S0N80W0L0", m.Gen(), ip_fault=fault)
        assert len(m.report_line(st)) == 126, fault
    st = m.frame_state("S0N80W0L0", m.Gen(), ip_fault="dead")
    assert m.report_line(st).endswith("IP_CLK=00000 IP_PK=000/000 IP_EXP=+00 IP_OK=0")


@pytest.mark.skipif(not ICARUS, reason="Icarus Verilog not installed")
@pytest.mark.parametrize("tb", ["tb_wave_gen.sv", "tb_mag.sv", "tb_fft_r2.sv"])
def test_unit_testbench_passes(tb):
    r = run(ROOT / "scripts" / "sim.py", SIM / tb)
    assert r.returncode == 0 and "PASS" in r.stdout, r.stdout[-3000:]


@pytest.mark.skipif(not ICARUS, reason="Icarus Verilog not installed")
def test_system_testbench_equals_the_model():
    # about 4 minutes: 2.8 million clocks of the whole design, 12 screen pictures compared pixel by pixel
    r = run(SIM / "check_tb.py", timeout=1800)
    assert r.returncode == 0, r.stdout[-4000:]
    assert "pictures and" in r.stdout and "equal the model" in r.stdout
