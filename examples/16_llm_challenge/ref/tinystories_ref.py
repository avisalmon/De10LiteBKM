"""The reference for the DE10-Lite LLM challenge: stories15M (llama2.c) in plain numpy, float32, temperature 0.

This file is the whole definition of "the same story". It downloads the published model and tokenizer, tells a
story the way llama2.c's run.c does (float32 math, greedy: the most likely token every time), prints every fact
about the model, writes the official reference stories, and checks a challenger's stories against them.

  python tinystories_ref.py download              the model (58 MB) and the tokenizer (0.4 MB), once
  python tinystories_ref.py info                  dimensions, every tensor, the parameter count, the file hashes
  python tinystories_ref.py tell "Once upon a"    a story from a prompt (--new 32 tokens; --ids shows the tokens)
  python tinystories_ref.py official              the official set -> reference_stories.json (--check: compare)
  python tinystories_ref.py check my_stories.json a challenger's stories against the reference, and the score
  python tinystories_ref.py selftest              the tokenizer and the model against known answers

Needs Python 3.8+ and numpy. The model: stories15M.bin from huggingface.co/karpathy/tinyllamas; the tokenizer:
tokenizer.bin from github.com/karpathy/llama2.c (both MIT). They are downloaded into models/ next to this file.
"""
import argparse
import hashlib
import heapq
import json
import os
import struct
import sys
import time
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(HERE, "models")
REFERENCE = os.path.join(HERE, "reference_stories.json")
URLS = {
    "stories15M.bin": "https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin",
    "tokenizer.bin": "https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin",
}
# The published files, byte for byte: a different hash is a different model (or a broken download).
SIZES = {"stories15M.bin": 60816028, "tokenizer.bin": 433869}
SHA256 = {
    "stories15M.bin": "cd590644d963867a2b6e5a1107f51fad663c41d79c149fbecbbb1f95fa81f49a",
    "tokenizer.bin": "50a52ef822ee9e83de5ce9d0be0a025a773d019437f58b5ff9dcafb063ece361",
}
BOS, EOS = 1, 2

# The official set: the prompts every entry is scored on, and how many new tokens each story has.
OFFICIAL_PROMPTS = ["Once", "Once upon a", "Lily was a", "One night, a magic", "Tom and his mom", "The robot said"]
OFFICIAL_NEW_TOKENS = 32


def fetch(name, quiet=False):
    """A model or tokenizer file by name -> its local path (downloaded once)."""
    p = os.path.join(MODELS_DIR, name)
    if os.path.exists(p) and os.path.getsize(p) == SIZES[name]:
        return p
    os.makedirs(MODELS_DIR, exist_ok=True)
    url = URLS[name]
    if not quiet:
        print(f"downloading {url}", flush=True)
    t0 = time.perf_counter()
    urllib.request.urlretrieve(url, p + ".part")
    os.replace(p + ".part", p)
    if not quiet:
        print(f"  {os.path.getsize(p) / 2**20:.1f} MB in {time.perf_counter() - t0:.0f} s", flush=True)
    if os.path.getsize(p) != SIZES[name]:
        raise SystemExit(f"{name}: {os.path.getsize(p)} bytes, expected {SIZES[name]} (a broken download?)")
    return p


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ============================================================ the tokenizer (llama2.c tokenizer.bin, encode, decode)
class Tokenizer:
    """llama2.c's tokenizer: 32,000 vocabulary strings with merge scores; encode() and decode() with run.c's rules."""

    def __init__(self, path, vocab_size=32000):
        self.vocab_size = vocab_size
        self.vocab, self.scores = [], np.zeros(vocab_size, np.float32)
        with open(path, "rb") as f:
            (self.max_token_length,) = struct.unpack("<i", f.read(4))
            for i in range(vocab_size):
                score, n = struct.unpack("<fi", f.read(8))
                self.scores[i] = score
                self.vocab.append(f.read(n))
        self.lookup = {}
        for i, piece in enumerate(self.vocab):          # the first id wins, like llama2.c's sorted lookup
            self.lookup.setdefault(piece, i)

    def encode(self, text, bos=True, eos=False):
        """str -> token ids, exactly llama2.c's encode(): BOS, the dummy ' ' prefix, UTF-8 pieces or byte
        fallbacks (byte + 3), then merge the adjacent pair with the best score until none is in the vocab."""
        if isinstance(text, str):
            text = text.encode("utf-8")
        toks = self._pieces(text, bos)
        toks = self._merge(toks)
        if eos:
            toks.append(EOS)
        return toks

    def _pieces(self, text, bos=True):
        toks = [BOS] if bos else []
        if text:
            toks.append(self.lookup[b" "])
            i = 0
            while i < len(text):
                n = 1
                while i + n < len(text) and (text[i + n] & 0xC0) == 0x80 and n < 4:
                    n += 1
                piece = text[i:i + n]
                tid = self.lookup.get(piece)
                if tid is not None:
                    toks.append(tid)
                else:
                    toks.extend(b + 3 for b in piece)
                i += n
        return toks

    def _merge(self, toks):
        """llama2.c's merge loop (best score first, the leftmost pair on a tie) with a heap instead of a rescan
        per merge: the same merges in the same order."""
        n = len(toks)
        if n < 2:
            return list(toks)
        ids = list(toks)
        nxt = list(range(1, n)) + [-1]
        prv = [-1] + list(range(n - 1))
        start = list(range(n))
        alive = [True] * n
        heap = []

        def push(a, b):
            if a < 0 or b < 0:
                return
            tid = self.lookup.get(self.vocab[ids[a]] + self.vocab[ids[b]])
            if tid is not None:
                heapq.heappush(heap, (-float(self.scores[tid]), start[a], a, b, ids[a], ids[b], tid))
        for a in range(n - 1):
            push(a, a + 1)
        while heap:
            _, _, a, b, ia, ib, tid = heapq.heappop(heap)
            if not (alive[a] and alive[b] and nxt[a] == b and ids[a] == ia and ids[b] == ib):
                continue
            ids[a] = tid
            alive[b] = False
            nxt[a] = nxt[b]
            if nxt[a] >= 0:
                prv[nxt[a]] = a
            push(prv[a], a)
            push(a, nxt[a])
        out, a = [], 0
        while a >= 0:
            out.append(ids[a])
            a = nxt[a]
        return out

    def _merge_naive(self, toks):
        """llama2.c's loop as written (rescan every pair per merge): the oracle the fast merge is checked against."""
        toks = list(toks)
        while True:
            best, best_id, best_idx = -1e10, -1, -1
            for i in range(len(toks) - 1):
                tid = self.lookup.get(self.vocab[toks[i]] + self.vocab[toks[i + 1]])
                if tid is not None and self.scores[tid] > best:
                    best, best_id, best_idx = self.scores[tid], tid, i
            if best_idx < 0:
                return toks
            toks[best_idx:best_idx + 2] = [best_id]

    def piece(self, prev, tok):
        """The bytes run.c prints for tok after prev (the space after BOS is dropped, byte tokens are raw bytes)."""
        p = self.vocab[tok]
        if prev == BOS and p[:1] == b" ":
            p = p[1:]
        if len(p) == 6 and p[:3] == b"<0x" and p[-1:] == b">":
            try:
                return bytes([int(p[3:5], 16)])
            except ValueError:
                pass
        return p

    def decode(self, toks):
        """token ids -> str (BOS and EOS print nothing)."""
        out, prev = bytearray(), BOS
        for t in toks:
            if t not in (BOS, EOS):
                out += self.piece(prev, t)
            prev = t
        return out.decode("utf-8", errors="replace")


# ============================================================ the checkpoint and the float32 forward pass
class Checkpoint:
    """A llama2.c .bin: the 7-int header and every tensor as a float32 array (memory-mapped, nothing copied)."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            dim, hidden, n_layers, n_heads, n_kv_heads, vocab, seq_len = struct.unpack("<7i", f.read(28))
        self.shared_classifier = vocab > 0                # a negative vocab size means "separate classifier"
        self.dim, self.hidden, self.n_layers = dim, hidden, n_layers
        self.n_heads, self.n_kv_heads, self.vocab, self.seq_len = n_heads, n_kv_heads, abs(vocab), seq_len
        self.head_size = dim // n_heads
        self.kv_dim = self.n_kv_heads * self.head_size
        data = np.memmap(path, dtype="<f4", mode="r", offset=28)
        self.t, self.order, pos = {}, [], 0

        def take(name, *shape):
            nonlocal pos
            n = int(np.prod(shape))
            self.t[name] = data[pos:pos + n].reshape(shape)
            self.order.append(name)
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
        self.t["wcls"] = self.t["tok_emb"] if self.shared_classifier else self.t["wcls"]

    def dims(self):
        return dict(dim=self.dim, hidden_dim=self.hidden, n_layers=self.n_layers, n_heads=self.n_heads,
                    n_kv_heads=self.n_kv_heads, vocab_size=self.vocab, seq_len=self.seq_len,
                    head_size=self.head_size, kv_dim=self.kv_dim, shared_classifier=self.shared_classifier)

    def parameters(self):
        """[(tensor, shape, count, is_parameter)]: the RoPE tables are stored in the file but are not weights."""
        rows = []
        for name in self.order:
            arr = self.t[name]
            rows.append((name, arr.shape, int(arr.size), not name.startswith("freq_cis")))
        return rows

    def n_parameters(self):
        return sum(n for _, _, n, is_p in self.parameters() if is_p)

    def rope(self, pos):
        """cos and sin per pair for a position, as run.c computes them (float32 math, not the stored tables)."""
        hd = np.arange(0, self.head_size, 2, dtype=np.float32)
        freq = (1.0 / np.power(np.float32(10000.0), hd / np.float32(self.head_size))).astype(np.float32)
        val = (np.float32(pos) * freq).astype(np.float32)
        return np.cos(val).astype(np.float32), np.sin(val).astype(np.float32)


def rmsnorm(x, w, eps=1e-5):
    ss = np.float32(np.dot(x, x) / x.size + eps)
    return (w * (x * np.float32(1.0 / np.sqrt(ss)))).astype(np.float32)


def softmax(x):
    e = np.exp(x - x.max())
    return e / e.sum()


class FloatModel:
    """run.c's forward pass in float32: forward(token, pos) -> logits, with the KV cache inside."""

    def __init__(self, ckpt):
        self.c = ckpt
        c = ckpt
        self.k_cache = np.zeros((c.n_layers, c.seq_len, c.kv_dim), np.float32)
        self.v_cache = np.zeros((c.n_layers, c.seq_len, c.kv_dim), np.float32)

    def reset(self):
        self.k_cache[:] = 0
        self.v_cache[:] = 0

    def _rope(self, vec, cos, sin, width):
        v = vec[:width].reshape(-1, self.c.head_size // 2, 2)
        v0, v1 = v[:, :, 0].copy(), v[:, :, 1].copy()
        v[:, :, 0] = v0 * cos - v1 * sin
        v[:, :, 1] = v0 * sin + v1 * cos
        return vec

    def forward(self, token, pos):
        """Logits (float32 [vocab]) for the token at position pos, given everything before it (the KV cache)."""
        c, t = self.c, self.c.t
        hs, H = c.head_size, c.n_heads
        x = np.array(t["tok_emb"][token], dtype=np.float32)              # 1. the token's embedding
        cos, sin = c.rope(pos)
        for l in range(c.n_layers):                                        # 2. six identical layers
            xa = rmsnorm(x, t["rms_att"][l])
            q = t["wq"][l] @ xa                                            #    query, key, value
            k = t["wk"][l] @ xa
            v = t["wv"][l] @ xa
            q = self._rope(q, cos, sin, c.dim)                             #    position: rotate q and k
            k = self._rope(k, cos, sin, c.kv_dim)
            self.k_cache[l, pos] = k                                       #    remember k and v for later tokens
            self.v_cache[l, pos] = v
            att = np.zeros(c.dim, np.float32)
            kv_mul = c.n_heads // c.n_kv_heads
            for h in range(H):                                             #    attention, one head at a time
                kh = (h // kv_mul) * hs
                qh = q[h * hs:(h + 1) * hs]
                scores = (self.k_cache[l, :pos + 1, kh:kh + hs] @ qh) / np.float32(np.sqrt(hs))
                a = softmax(scores).astype(np.float32)
                att[h * hs:(h + 1) * hs] = a @ self.v_cache[l, :pos + 1, kh:kh + hs]
            x = x + t["wo"][l] @ att                                       #    output projection, residual
            xf = rmsnorm(x, t["rms_ffn"][l])
            h1 = t["w1"][l] @ xf                                           #    feed-forward (SwiGLU)
            h3 = t["w3"][l] @ xf
            hh = (h1 * (1.0 / (1.0 + np.exp(-h1))) * h3).astype(np.float32)
            x = x + t["w2"][l] @ hh                                        #    residual
        xb = rmsnorm(x, t["rms_final"])                                    # 3. final norm
        return (t["wcls"] @ xb).astype(np.float32)                         # 4. one score per vocabulary word

    def generate(self, prompt_tokens, new_tokens, temperature=0.0, topp=0.9, seed=0, stop_at_end=False,
                 on_token=None):
        """run.c's loop: the prompt tokens are forced in, then new_tokens tokens are chosen (argmax when the
        temperature is 0). Returns the whole token list, prompt included. The model's window is seq_len."""
        self.reset()
        rng = np.random.default_rng(seed)
        toks = list(prompt_tokens)
        total = min(len(toks) + new_tokens, self.c.seq_len)
        pos, token = 0, toks[0]
        out = [token]
        while pos < total - 1:
            logits = self.forward(token, pos)
            if pos + 1 < len(toks):
                nxt = toks[pos + 1]
            else:
                nxt = sample(logits, temperature, topp, rng)
            pos += 1
            out.append(int(nxt))
            if on_token:
                on_token(int(nxt))
            if stop_at_end and nxt in (BOS, EOS) and pos + 1 >= len(toks):
                break
            token = nxt
        return out


def sample(logits, temperature, topp, rng):
    """run.c's sampler: argmax at temperature 0, else softmax(logits / T) and multinomial or top-p sampling."""
    if temperature == 0.0:
        return int(np.argmax(logits))
    p = softmax(logits.astype(np.float64) / temperature)
    if topp <= 0 or topp >= 1:
        return int(rng.choice(p.size, p=p))
    order = np.argsort(-p)
    cum = np.cumsum(p[order])
    last = int(np.searchsorted(cum, topp)) + 1
    keep = order[:last]
    pk = p[keep] / p[keep].sum()
    return int(keep[rng.choice(last, p=pk)])


def load(quiet=False):
    """(Checkpoint, Tokenizer, FloatModel), downloading the two files on first use."""
    ckpt = Checkpoint(fetch("stories15M.bin", quiet))
    tok = Tokenizer(fetch("tokenizer.bin", quiet), ckpt.vocab)
    return ckpt, tok, FloatModel(ckpt)


# ============================================================ the commands
def story_record(tok, model, prompt, new_tokens):
    """One reference story as a dict: the prompt, its ids, the generated ids, and both texts.
    generated_text is the story minus the prompt, so it begins with the space of the first new word."""
    ids = tok.encode(prompt)
    out = model.generate(ids, new_tokens)
    new = out[len(ids):]
    story = tok.decode(out)
    return {"prompt": prompt, "prompt_tokens": ids, "new_tokens": new,
            "generated_text": story[len(tok.decode(ids)):], "story": story}


def cmd_download(a):
    for name in URLS:
        p = fetch(name)
        h = sha256_of(p)
        print(f"{name}: {os.path.getsize(p):,} bytes, sha256 {h} ({'the published file' if h == SHA256[name] else 'UNEXPECTED HASH'})")


def cmd_info(a):
    ckpt, tok, _ = load(quiet=True)
    print("stories15M (llama2.c format): the header")
    for k, v in ckpt.dims().items():
        print(f"  {k:<18} {v}")
    print("\nthe tensors, in file order")
    print(f"  {'tensor':<14} {'shape':<20} {'floats':>12}  counted as parameters")
    total = 0
    for name, shape, n, is_p in ckpt.parameters():
        print(f"  {name:<14} {str(tuple(shape)):<20} {n:>12,}  {'yes' if is_p else 'no (RoPE table)'}")
        total += n
    print(f"  {'file total':<14} {'':<20} {total:>12,}  = {total * 4 + 28:,} bytes with the 28-byte header")
    print(f"\nparameters: {ckpt.n_parameters():,} (the classifier shares the token embedding)")
    per_layer = sum(ckpt.t[n][0].size for n in ("wq", "wk", "wv", "wo", "w1", "w2", "w3"))
    cls = ckpt.t["wcls"].size
    print(f"matrix multiply-accumulates per generated token: {per_layer:,} x {ckpt.n_layers} layers"
          f" + {cls:,} classifier = {per_layer * ckpt.n_layers + cls:,}")
    print(f"  plus attention: {ckpt.n_layers} x 2 x (position + 1) x {ckpt.dim} (at most"
          f" {ckpt.n_layers * 2 * ckpt.seq_len * ckpt.dim:,} at position {ckpt.seq_len - 1})")
    print(f"weights read per token if nothing is cached: {(per_layer * ckpt.n_layers + cls) * 4 / 2**20:.1f} MB"
          f" as float32")
    print(f"\ntokenizer: {tok.vocab_size:,} pieces, longest {tok.max_token_length} bytes;"
          f" BOS = {BOS}, EOS = {EOS}")
    for name in URLS:
        p = os.path.join(MODELS_DIR, name)
        print(f"sha256 {name}: {sha256_of(p)}  ({os.path.getsize(p):,} bytes)")


def cmd_tell(a):
    ckpt, tok, model = load(quiet=True)
    ids = tok.encode(a.prompt)
    if a.ids:
        print(f"prompt tokens: {ids}")
    printed = [BOS]

    def show(t):
        sys.stdout.write(tok.piece(printed[-1], t).decode("utf-8", errors="replace") if t not in (BOS, EOS)
                         else "")
        sys.stdout.flush()
        printed.append(t)
    t0 = time.perf_counter()
    out = model.generate(ids, a.new, temperature=a.temperature, seed=a.seed, stop_at_end=a.stop,
                         on_token=show)
    dt = time.perf_counter() - t0
    new = out[len(ids):]
    print(f"\n\n{len(new)} new tokens in {dt:.1f} s on this PC ({len(new) / dt:.1f} tok/s, numpy float32)")
    if a.ids:
        print(f"new tokens: {new}")


def cmd_official(a):
    ckpt, tok, model = load(quiet=True)
    t0 = time.perf_counter()
    stories = [story_record(tok, model, p, OFFICIAL_NEW_TOKENS) for p in OFFICIAL_PROMPTS]
    dt = time.perf_counter() - t0
    doc = {"model": "stories15M.bin", "tokenizer": "tokenizer.bin", "math": "float32, llama2.c run.c order",
           "temperature": 0.0, "new_tokens_per_story": OFFICIAL_NEW_TOKENS,
           "total_new_tokens": OFFICIAL_NEW_TOKENS * len(OFFICIAL_PROMPTS), "stories": stories}
    if a.check:
        with open(REFERENCE, encoding="utf-8") as f:
            have = json.load(f)
        same = have["stories"] == stories
        print(f"{REFERENCE}: {'matches' if same else 'DIFFERS FROM'} a fresh float32 run ({dt:.0f} s)")
        return 0 if same else 1
    with open(REFERENCE, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
    for s in stories:
        print(f"{s['prompt']!r}: {s['story']!r}")
    print(f"\nwrote {REFERENCE}: {len(stories)} stories, {doc['total_new_tokens']} new tokens, in {dt:.0f} s")


def cmd_check(a):
    """A challenger's file against the reference. The file is JSON:
      {"entrant": "...", "stories": [{"prompt": "Once", "new_tokens": [...], "seconds": 1.23}, ...]}
    new_tokens are the generated ids (or give "generated_text" instead: the story minus the prompt; a missing
    leading space is forgiven); seconds is the time from the prompt being given to the last token, per story.
    The score is total new tokens / total seconds."""
    with open(REFERENCE, encoding="utf-8") as f:
        ref = {s["prompt"]: s for s in json.load(f)["stories"]}
    with open(a.file, encoding="utf-8") as f:
        sub = json.load(f)
    ok_all, n_tokens, seconds = True, 0, 0.0
    seen = set()
    for s in sub.get("stories", []):
        p = s.get("prompt")
        r = ref.get(p)
        if r is None:
            print(f"  {p!r}: not an official prompt, ignored")
            continue
        seen.add(p)
        if "new_tokens" in s:
            same = list(s["new_tokens"]) == r["new_tokens"]
            got = s["new_tokens"]
            want = r["new_tokens"]
        else:
            got, want = s.get("generated_text", ""), r["generated_text"]
            same = got.lstrip(" ") == want.lstrip(" ")
        n_tokens += len(r["new_tokens"])
        seconds += float(s.get("seconds", 0.0))
        ok_all &= same
        print(f"  {p!r}: {'same as the reference' if same else 'DIFFERENT'}"
              f"{'' if same else chr(10) + '     got  ' + repr(got) + chr(10) + '     want ' + repr(want)}")
    missing = [p for p in OFFICIAL_PROMPTS if p not in seen]
    if missing:
        ok_all = False
        print(f"  missing prompts: {missing}")
    if seconds > 0 and ok_all:
        print(f"\n{sub.get('entrant', 'entry')}: {n_tokens} tokens in {seconds:.3f} s = {n_tokens / seconds:.2f} tok/s")
    elif ok_all:
        print("\nno 'seconds' given: the stories are right but there is no score")
    print("PASS: every official story equals the reference" if ok_all else "FAIL: the stories differ")
    return 0 if ok_all else 1


def cmd_selftest(a):
    ckpt, tok, model = load(quiet=True)
    fails = 0

    def check(name, cond, detail=""):
        nonlocal fails
        print(f"  {'ok  ' if cond else 'FAIL'} {name}{(' ' + detail) if detail and not cond else ''}")
        fails += 0 if cond else 1
    check("header", ckpt.dims() == dict(dim=288, hidden_dim=768, n_layers=6, n_heads=6, n_kv_heads=6,
                                        vocab_size=32000, seq_len=256, head_size=48, kv_dim=288,
                                        shared_classifier=True), str(ckpt.dims()))
    for name, h in SHA256.items():
        got = sha256_of(os.path.join(MODELS_DIR, name))
        check(f"sha256 of {name}", got == h, got)
    check("parameter count 15,191,712", ckpt.n_parameters() == 15191712, str(ckpt.n_parameters()))
    check("encode('Once upon a') == [1, 9038, 2501, 263]", tok.encode("Once upon a") == [1, 9038, 2501, 263],
          str(tok.encode("Once upon a")))
    for s in ["Once upon a time, there was a little girl named Lily.", "The robot said \"hello\" 3 times!",
              "Tom & Jerry\n", "naïve café", "One night, a magic"]:
        fast, slow = tok._merge(tok._pieces(s.encode())), tok._merge_naive(tok._pieces(s.encode()))
        check(f"merge order for {s!r}", fast == slow, f"{fast} vs {slow}")
        check(f"decode(encode({s!r}))", tok.decode(tok.encode(s)) == s, repr(tok.decode(tok.encode(s))))
    t0 = time.perf_counter()
    rec = story_record(tok, model, "Once upon a", 8)
    dt = time.perf_counter() - t0
    check("'Once upon a' + 8 tokens is a sentence", rec["story"].startswith("Once upon a time, there was a"),
          repr(rec["story"]))
    if os.path.exists(REFERENCE):
        with open(REFERENCE, encoding="utf-8") as f:
            ref = {s["prompt"]: s for s in json.load(f)["stories"]}
        check("first 8 tokens equal reference_stories.json", rec["new_tokens"] == ref["Once upon a"]["new_tokens"][:8],
              f"{rec['new_tokens']} vs {ref['Once upon a']['new_tokens'][:8]}")
    print(f"{'PASS' if fails == 0 else 'FAIL'}: selftest, {dt:.1f} s for 8 tokens")
    return 1 if fails else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("download", help="fetch stories15M.bin and tokenizer.bin into models/").set_defaults(f=cmd_download)
    sub.add_parser("info", help="dimensions, tensors, parameter count, hashes").set_defaults(f=cmd_info)
    p = sub.add_parser("tell", help="tell a story from a prompt")
    p.add_argument("prompt")
    p.add_argument("--new", type=int, default=OFFICIAL_NEW_TOKENS, help="new tokens to generate (default 32)")
    p.add_argument("--temperature", type=float, default=0.0, help="0 = greedy, the challenge's setting")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--stop", action="store_true", help="stop at the end of the story (BOS/EOS)")
    p.add_argument("--ids", action="store_true", help="print the token ids too")
    p.set_defaults(f=cmd_tell)
    p = sub.add_parser("official", help="write reference_stories.json (the official set)")
    p.add_argument("--check", action="store_true", help="compare the file with a fresh run instead of writing")
    p.set_defaults(f=cmd_official)
    p = sub.add_parser("check", help="a challenger's stories (JSON) against the reference, and the score")
    p.add_argument("file")
    p.set_defaults(f=cmd_check)
    sub.add_parser("selftest", help="tokenizer and model against known answers").set_defaults(f=cmd_selftest)
    a = ap.parse_args(argv)
    return a.f(a) or 0


if __name__ == "__main__":
    sys.exit(main())
