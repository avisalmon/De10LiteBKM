"""Lesson 2's project checker, against the .qsf Quartus itself wrote when the lesson was made by hand in the GUI."""

import importlib.util
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LESSON = ROOT / "lessons" / "02_first_project"
spec = importlib.util.spec_from_file_location("check_project", LESSON / "check_project.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def project(tmp_path, edit=lambda text: text):
    shutil.copy(LESSON / "reference" / "first_led.qsf", tmp_path / "first_led.qsf")
    qsf = tmp_path / "first_led.qsf"
    qsf.write_text(edit(qsf.read_text(encoding="utf-8")), encoding="utf-8")
    return str(tmp_path)


def test_the_reference_project_passes(tmp_path):
    assert check.main([project(tmp_path)]) == 0


def test_the_change_task_is_not_done_in_the_reference(tmp_path):
    assert check.main([project(tmp_path), "--change"]) == 1


def test_the_default_io_standard_is_caught(tmp_path, capsys):
    folder = project(tmp_path, lambda t: t.replace('IO_STANDARD "3.3-V LVTTL" -to led0', 'IO_STANDARD "2.5 V" -to led0'))
    assert check.main([folder]) == 1
    assert "led0 I/O standard 2.5 V" in capsys.readouterr().out


def test_a_wrong_pin_and_a_wrong_device_are_caught(tmp_path, capsys):
    folder = project(tmp_path, lambda t: t.replace("PIN_C10 -to sw0", "PIN_C11 -to sw0").replace("10M50DAF484C7G", "10M08DAF484C8G"))
    assert check.main([folder]) == 1
    out = capsys.readouterr().out
    assert "sw0 on PIN_C11" in out and "device 10M08DAF484C8G" in out


def test_an_empty_folder_says_to_run_the_wizard(tmp_path, capsys):
    assert check.main([str(tmp_path)]) == 1
    assert "New Project Wizard" in capsys.readouterr().out
