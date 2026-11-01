"""The TinyStories LLM challenge (example 16): the public page says everything about the model and nothing about
the organizer's design, the official set is well formed, the checker judges a submission built from it, the
tokenizer and model selftest runs when the model files are present (they are downloaded, never committed), and
the portals point at the page."""

import hashlib
import html
import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "examples" / "16_llm_challenge"
REF = EXAMPLE / "ref"
PAGE = EXAMPLE / "index.html"


def load_ref():
    spec = importlib.util.spec_from_file_location("llm_challenge_ref", REF / "tinystories_ref.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def reference():
    return json.loads((REF / "reference_stories.json").read_text(encoding="utf-8"))


# --- the official set and the checker ---

def test_the_official_set_is_six_stories_of_32_new_tokens():
    ref = load_ref()
    doc = reference()
    assert doc["temperature"] == 0.0 and doc["new_tokens_per_story"] == 32 == ref.OFFICIAL_NEW_TOKENS
    assert doc["model"] == "stories15M.bin" and doc["tokenizer"] == "tokenizer.bin"
    assert [s["prompt"] for s in doc["stories"]] == ref.OFFICIAL_PROMPTS
    assert doc["total_new_tokens"] == sum(len(s["new_tokens"]) for s in doc["stories"]) == 192
    for s in doc["stories"]:
        assert s["prompt_tokens"][0] == ref.BOS and len(s["new_tokens"]) == 32
        assert all(0 <= t < 32000 for t in s["prompt_tokens"] + s["new_tokens"])
        assert s["story"].startswith(s["prompt"]) and s["story"] == s["prompt"] + s["generated_text"]
    once = {s["prompt"]: s for s in doc["stories"]}
    assert once["Once upon a"]["prompt_tokens"] == [1, 9038, 2501, 263]
    assert once["Once"]["new_tokens"][:6] == [2501, 263, 931, 29892, 727, 471]      # " upon a time, there was"


def test_the_checker_passes_the_reference_and_fails_one_wrong_token(tmp_path, capsys):
    ref = load_ref()
    doc = reference()
    entry = {"entrant": "test", "stories": [{"prompt": s["prompt"], "new_tokens": s["new_tokens"], "seconds": 1.25}
                                            for s in doc["stories"]]}
    good = tmp_path / "good.json"
    good.write_text(json.dumps(entry), encoding="utf-8")
    assert ref.main(["check", str(good)]) == 0
    out = capsys.readouterr().out
    assert "PASS" in out and "192 tokens in 7.500 s = 25.60 tok/s" in out
    entry["stories"][2]["new_tokens"] = list(entry["stories"][2]["new_tokens"])
    entry["stories"][2]["new_tokens"][5] += 1
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(entry), encoding="utf-8")
    assert ref.main(["check", str(bad)]) == 1
    assert "DIFFERENT" in capsys.readouterr().out
    entry["stories"][2]["new_tokens"][5] -= 1
    del entry["stories"][0]
    short = tmp_path / "short.json"
    short.write_text(json.dumps(entry), encoding="utf-8")
    assert ref.main(["check", str(short)]) == 1
    assert "missing prompts: ['Once']" in capsys.readouterr().out


def test_generated_text_may_stand_in_for_the_ids(tmp_path, capsys):
    ref = load_ref()
    stories = reference()["stories"]
    entry = {"stories": [{"prompt": s["prompt"], "generated_text": s["generated_text"]} for s in stories]}
    entry["stories"][1]["generated_text"] = entry["stories"][1]["generated_text"].lstrip(" ")   # forgiven
    f = tmp_path / "text.json"
    f.write_text(json.dumps(entry, ensure_ascii=False), encoding="utf-8")
    assert ref.main(["check", str(f)]) == 0
    assert "no 'seconds' given" in capsys.readouterr().out


def test_the_tokenizer_and_model_selftest():
    ref = load_ref()
    models = [Path(ref.MODELS_DIR) / n for n in ref.SIZES]
    if not all(p.exists() and p.stat().st_size == ref.SIZES[p.name] for p in models):
        pytest.skip("model files not downloaded (python tinystories_ref.py download)")
    assert ref.main(["selftest"]) == 0
    assert ref.main(["info"]) == 0


# --- the page ---

def page():
    return PAGE.read_text(encoding="utf-8")


def test_the_page_has_every_section_and_its_links_resolve():
    text = page()
    for anchor in ("see", "model", "how", "reference", "official", "submit", "rules", "score", "contact"):
        assert f'id="{anchor}"' in text, anchor
    for href in re.findall(r'(?:href|src)="([^"#:]+)"', text):
        assert (EXAMPLE / href).exists(), href
    assert "youtube.com/embed/3uAi1w1iltc" in text and "mailto:avi.salmon@intel.com" in text
    assert "FILL IN" not in text and "BKM-TODO" not in text and "{{" not in text


def test_the_page_states_the_model_the_record_and_the_hashes():
    ref = load_ref()
    text = page()
    for fact in ("15,191,712", "60,816,028", "433,869", "32,000", "288", "768", "6 layers", "26.16", "7.340", "192"):
        assert fact in text, fact
    for h in ref.SHA256.values():
        assert h in text.replace(" ", ""), h                         # printed in 8-character groups
    for prompt in ref.OFFICIAL_PROMPTS:
        assert html.escape(prompt, quote=False) in text, prompt
    doc = reference()
    for s in doc["stories"]:                                          # the official stories are on the page
        assert html.escape(s["story"].split("\n")[0].strip()) in text, s["prompt"]


def test_the_page_keeps_the_organizers_design_to_itself():
    """No implementation hints: not the private design, not the examples it grew from. The words that would
    give something away are kept here as hashes, since this file is as public as the page."""
    text = page()
    for plain in ("projects/", "14_usb_sdram_loader", "15_sdram_stream_fabric"):
        assert plain not in text, plain
    banned = {"6c1ccd1f2074", "e97d734d6251", "00337646bb39", "1c4c2549fa7c", "919559d14527", "93cfaf2195d4",
              "442573c37724", "cb1525bced78", "d991b1bb53f9", "6a9d9f72a423", "8950abfda7b7", "7ce608c5f50e",
              "57d59e28722d", "ad2a542c84c7", "950c5f3506a1", "b98aaaa13a6c"}
    words = set(re.findall(r"[a-z0-9]+", text.lower()))
    said = [w for w in words if hashlib.sha256(w.encode()).hexdigest()[:12] in banned]
    assert not said, said
    assert "The organizer's design is not published" in text


def test_code_lines_on_the_page_fit_in_100_characters():
    for block in re.findall(r"<pre[^>]*>(.*?)</pre>", page(), re.S):
        for line in html.unescape(re.sub(r"<[^>]+>", "", block)).splitlines():
            assert len(line) <= 100, line


def test_the_portals_point_at_it():
    assert "16_llm_challenge/index.html" in (ROOT / "examples" / "index.html").read_text(encoding="utf-8")
    assert "examples/16_llm_challenge/index.html" in (ROOT / "index.html").read_text(encoding="utf-8")


def test_the_model_files_are_ignored_and_not_committed():
    assert "examples/16_llm_challenge/ref/models/" in (ROOT / ".gitignore").read_text(encoding="utf-8")
    assert not list(EXAMPLE.rglob("*.sof")) and not list(EXAMPLE.rglob("*.pof"))
    assert not list(EXAMPLE.rglob("*.sv")) and not list(EXAMPLE.rglob("*.v")) and not list(EXAMPLE.rglob("*.qsf"))
