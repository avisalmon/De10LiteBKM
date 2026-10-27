"""Export a llama2.c model (.bin, float32) to the stream fabric's int8 weight format (spec section 6).

  python tools/export_q8.py stories260K            download karpathy/tinyllamas stories260K.bin, export it
  python tools/export_q8.py stories15M             the target model (60 MB download, 16 MB exported)
  python tools/export_q8.py path/to/model.bin [-o model.q8.bin] [--map model.json] [--aux model.aux.npz]

Writes, next to the input unless told otherwise:
  model.q8.bin   every matrix of every layer (wq wk wv wo w1 w2 w3) and the classifier, one after the other, each
                 starting on a 1024-word boundary: load it at SDRAM word 0 with scripts/sdram_load.py
  model.json     the map: dims, and per matrix name, offset_words, rows, k, exponent (w = q * s_g * 2^exponent)
  model.aux.npz  what is not a matrix: the RMS-norm weights, the rotary tables (float32) and, when the model does
                 not share it with the classifier, the token embedding table

Matrices are stored [rows = outputs, k = inputs] like llama2.c's run.c reads them (matmul(xout, x, w, n, d):
xout[i] = sum_j w[i * n + j] x[j]). The model files come from https://huggingface.co/karpathy/tinyllamas and land
in examples/15_sdram_stream_fabric/logs/models/ (git-ignored).
"""
import argparse
import json
import os
import struct
import sys
import time
import urllib.request

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_matvec as rm  # noqa: E402

HF = "https://huggingface.co/karpathy/tinyllamas/resolve/main/{name}/{name}.bin"
MODELS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "logs", "models")
KINDS = ("wq", "wk", "wv", "wo", "w1", "w2", "w3")


def download(name, dest_dir=MODELS_DIR):
    """stories260K / stories15M / stories42M -> the local .bin path (downloaded once)."""
    os.makedirs(dest_dir, exist_ok=True)
    path = os.path.join(dest_dir, name + ".bin")
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return path
    url = HF.format(name=name)
    print(f"downloading {url}", flush=True)
    t0 = time.perf_counter()

    def hook(blocks, block_size, total):
        done = blocks * block_size
        if total > 0 and blocks % 256 == 0:
            print(f"  {done / 2**20:6.1f} / {total / 2**20:.1f} MB", flush=True)
    urllib.request.urlretrieve(url, path + ".part", hook)
    os.replace(path + ".part", path)
    print(f"  {os.path.getsize(path) / 2**20:.1f} MB in {time.perf_counter() - t0:.0f} s")
    return path


class Llama2Bin:
    """A llama2.c checkpoint: the header and every tensor as a float32 array (memory-mapped)."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            hdr = f.read(28)
        dim, hidden, n_layers, n_heads, n_kv_heads, vocab, seq_len = struct.unpack("<7i", hdr)
        self.shared_classifier = vocab > 0
        self.dim, self.hidden, self.n_layers = dim, hidden, n_layers
        self.n_heads, self.n_kv_heads, self.vocab, self.seq_len = n_heads, n_kv_heads, abs(vocab), seq_len
        self.head_size = dim // n_heads
        self.kv_dim = self.n_kv_heads * self.head_size
        data = np.memmap(path, dtype="<f4", mode="r", offset=28)
        self.t = {}
        pos = 0

        def take(name, *shape):
            nonlocal pos
            n = int(np.prod(shape))
            self.t[name] = data[pos:pos + n].reshape(shape)
            pos += n
        take("tok_emb", self.vocab, dim)
        take("rms_att", n_layers, dim)
        take("wq", n_layers, dim, dim)
        take("wk", n_layers, self.kv_dim, dim)
        take("wv", n_layers, self.kv_dim, dim)
        take("wo", n_layers, dim, dim)
        take("rms_ffn", n_layers, dim)
        take("w1", n_layers, hidden, dim)
        take("w2", n_layers, dim, hidden)
        take("w3", n_layers, hidden, dim)
        take("rms_final", dim)
        take("freq_cis_real", seq_len, self.head_size // 2)
        take("freq_cis_imag", seq_len, self.head_size // 2)
        if not self.shared_classifier:
            take("wcls", self.vocab, dim)
        if pos != data.size:
            raise ValueError(f"{path}: {data.size} floats, the header accounts for {pos}")

    def dims(self):
        return dict(dim=self.dim, hidden_dim=self.hidden, n_layers=self.n_layers, n_heads=self.n_heads,
                    n_kv_heads=self.n_kv_heads, vocab_size=self.vocab, seq_len=self.seq_len,
                    head_size=self.head_size, shared_classifier=self.shared_classifier)

    def matrices(self):
        """(name, layer, kind, float32 [rows, k]) for every matrix in stream order."""
        for l in range(self.n_layers):
            for kind in KINDS:
                yield f"l{l}.{kind}", l, kind, self.t[kind][l]
        yield "cls", None, "cls", self.t["tok_emb"] if self.shared_classifier else self.t["wcls"]


def export(model, out_bin, out_map, out_aux, quiet=False):
    t0 = time.perf_counter()
    entries, offset = [], 0
    with open(out_bin, "wb") as f:
        for name, layer, kind, w in model.matrices():
            rows, k = w.shape
            q, s, e = rm.quantize(w)
            words = rm.stream_words(q, s)
            assert words.size == rm.matrix_words(rows, k)
            f.write(words.astype("<u2").tobytes())
            back = rm.dequantize(q, s, e)[:, :k]
            err = float(np.abs(back - w).max())
            entries.append(dict(name=name, layer=layer, kind=kind, offset_words=offset, rows=rows, k=k,
                                k_pad=rm.pad_k(k), row_words=rm.row_words(k), words=int(words.size), exponent=e,
                                max_abs=float(np.abs(w).max()), max_err=err,
                                default_shift=rm.default_shift(k)))
            if not quiet:
                print(f"  {name:10s} {rows:6d} x {k:<5d} -> {words.size:9,} words at {offset:#010x}  "
                      f"E {e:4d}  max |w| {entries[-1]['max_abs']:.4f}  max err {err:.2e}", flush=True)
            offset += words.size
            pad = rm.aligned(offset) - offset
            f.write(b"\0" * (2 * pad))
            offset += pad
    aux = {k: np.asarray(model.t[k], dtype=np.float32)
           for k in ("rms_att", "rms_ffn", "rms_final", "freq_cis_real", "freq_cis_imag")}
    if not model.shared_classifier:
        aux["tok_emb"] = np.asarray(model.t["tok_emb"], dtype=np.float32)
    np.savez(out_aux, **aux)
    m = dict(source=os.path.basename(model.path), format="q8: groups of 32 int8 with an int16 scale, 17 words "
             "per group, matrices [rows, k] row after row on 1024-word boundaries; w = q * s * 2^exponent",
             total_words=offset, total_bytes=2 * offset, aux=os.path.basename(out_aux), matrices=entries,
             **model.dims())
    with open(out_map, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=1)
    if not quiet:
        print(f"{out_bin}: {2 * offset / 2**20:.2f} MB ({offset:,} words, {len(entries)} matrices) "
              f"in {time.perf_counter() - t0:.1f} s; map {out_map}; aux {out_aux}")
    return m


def load_map(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def find_matrix(m, name):
    for e in m["matrices"]:
        if e["name"] == name:
            return e
    raise KeyError(f"no matrix {name!r} in the map; there are: " + ", ".join(e["name"] for e in m["matrices"]))


def read_matrix_words(bin_path, entry):
    """The uint16 words of one matrix from model.q8.bin."""
    with open(bin_path, "rb") as f:
        f.seek(2 * entry["offset_words"])
        return np.frombuffer(f.read(2 * entry["words"]), dtype="<u2").astype(np.uint16)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", help="stories260K | stories15M | stories42M (downloaded) or a path to a .bin")
    ap.add_argument("-o", "--out", default=None, help="model.q8.bin (default: next to the input)")
    ap.add_argument("--map", default=None, help="model.json (default: next to the output)")
    ap.add_argument("--aux", default=None, help="model.aux.npz (default: next to the output)")
    ap.add_argument("--check", action="store_true", help="read the output back and compare with the map")
    a = ap.parse_args()
    path = a.model if os.path.exists(a.model) else download(a.model)
    out = a.out or os.path.splitext(path)[0] + ".q8.bin"
    out_map = a.map or os.path.splitext(out)[0].replace(".q8", "") + ".json"
    out_aux = a.aux or os.path.splitext(out)[0].replace(".q8", "") + ".aux.npz"
    model = Llama2Bin(path)
    d = model.dims()
    print(f"{path}: dim {d['dim']}, hidden {d['hidden_dim']}, {d['n_layers']} layers, {d['n_heads']} heads "
          f"({d['n_kv_heads']} KV), vocab {d['vocab_size']}, context {d['seq_len']}, "
          f"classifier {'shared with the embedding' if d['shared_classifier'] else 'separate'}")
    m = export(model, out, out_map, out_aux)
    if a.check:
        bad = 0
        for e, (name, _, _, w) in zip(m["matrices"], model.matrices()):
            q, s = rm.parse_stream(read_matrix_words(out, e), e["rows"], e["k"])
            q2, s2, e2 = rm.quantize(w)
            if not (np.array_equal(q, q2) and np.array_equal(s, s2) and e2 == e["exponent"]):
                print(f"  FAIL: {name} does not read back as quantized")
                bad += 1
        print("check: OK, every matrix reads back" if not bad else f"check: {bad} matrices FAIL")
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
