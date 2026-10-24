"""A small C compiler for the RV32I SoC: C source -> RV32I assembly (tools/asm.py assembles it).

    python tools/cc.py game.c -o build/game.s [-I sw] [-D NAME=value]

The language: a C subset chosen so a game, a driver or a test fits in it and the generated code stays readable:
  * types: int, char (signed), unsigned int / unsigned char, void; pointers of any depth; arrays of one or two
    dimensions (of int, char or pointers); const / volatile / static / extern accepted (no effect on code).
  * declarations: globals with constant initialisers ({...} for arrays, "..." for char arrays, string literals for
    char *), locals anywhere in a block, function definitions and prototypes (up to 8 parameters).
  * statements: if / else, while, do / while, for (with a declaration in the init), switch / case / default,
    break, continue, return, blocks, expression statements.
  * expressions: everything in C's precedence table except the comma operator and compound literals: assignment and
    op=, ?:, || && | ^ & == != < > <= >= << >> + - * / % unary ! ~ - + * & ++ -- (prefix and postfix), casts,
    sizeof, [], function calls, string and character literals.
  * preprocessor: #include "file", #define (constants and function-like macros with arguments), #ifdef / #ifndef /
    #else / #endif, #undef; // and /* */ comments.
Not there: struct / union / enum, typedef, float, long, goto, variadic functions, the comma operator, function
pointers, initialisers for local arrays. The compiler says so with a line number instead of guessing.

Code generation is the simple kind: every expression ends in a0, temporaries go on the stack, locals live in the
frame at s0 offsets, arguments arrive in a0..a7 and are spilled to the frame. * / % call __mul __div __mod __udiv
__umod from sw/crt0.s (RV32I has no multiplier; a multiply by a power of two becomes a shift).
"""
import argparse
import re
import sys
from pathlib import Path


class CError(Exception):
    pass


# ============================================================ preprocessor + lexer
KEYWORDS = {"int", "char", "void", "unsigned", "signed", "const", "volatile", "static", "extern", "if", "else",
            "while", "do", "for", "return", "break", "continue", "switch", "case", "default", "sizeof"}
PUNCT = ["<<=", ">>=", "...", "->", "++", "--", "&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=",
         "&=", "|=", "^=", "<<", ">>", "+", "-", "*", "/", "%", "=", "<", ">", "!", "~", "&", "|", "^", "?", ":",
         ";", ",", "(", ")", "[", "]", "{", "}", "."]
TOKEN_RE = re.compile(r"""
    (?P<ws>[ \t\r]+) | (?P<nl>\n) | (?P<lcom>//[^\n]*) | (?P<bcom>/\*.*?\*/) |
    (?P<num>0[xX][0-9a-fA-F]+[uUlL]*|0[bB][01]+|\d+[uUlL]*) | (?P<chr>'(?:\\.|[^'\\])') |
    (?P<str>"(?:\\.|[^"\\])*") | (?P<id>[A-Za-z_]\w*) |
    (?P<punct>""" + "|".join(re.escape(p) for p in PUNCT) + r")", re.X | re.S)


class Tok:
    __slots__ = ("kind", "text", "line", "file")

    def __init__(self, kind, text, line, file):
        self.kind, self.text, self.line, self.file = kind, text, line, file

    def __repr__(self):
        return f"{self.kind}:{self.text}"


class Preprocessor:
    def __init__(self, include_dirs, defines):
        self.include_dirs = include_dirs
        self.macros = {}            # name -> (params or None, tokens)
        for d in defines:
            name, _, value = d.partition("=")
            self.macros[name] = (None, self.lex_line(value or "1", "<cmdline>", 0))

    def lex_line(self, text, file, line):
        out = []
        pos = 0
        while pos < len(text):
            m = TOKEN_RE.match(text, pos)
            if not m:
                raise CError(f"{file}:{line}: bad character {text[pos]!r}")
            pos = m.end()
            kind = m.lastgroup
            if kind in ("ws", "lcom", "bcom", "nl"):
                continue
            out.append(Tok(kind, m.group(kind), line, file))
        return out

    def run(self, path):
        """Returns the token list of the file with includes and macros expanded, directives handled."""
        return self.file_tokens(Path(path))

    def file_tokens(self, path):
        text = path.read_text(encoding="utf-8")
        # join block comments that span lines, keep line numbers by counting newlines inside them
        out = []
        skip = []               # stack of booleans: True = skipping this #if region
        lines = text.split("\n")
        i = 0
        while i < len(lines):
            raw = lines[i]
            lineno = i + 1
            # a block comment that spans lines: swallow until its end
            while "/*" in raw and "*/" not in raw[raw.index("/*"):]:
                i += 1
                if i >= len(lines):
                    raise CError(f"{path}:{lineno}: unterminated comment")
                raw += "\n" + lines[i]
            stripped = raw.strip()
            if stripped.startswith("#"):
                parts = stripped[1:].strip().split(None, 1)
                d = parts[0] if parts else ""
                arg = parts[1] if len(parts) > 1 else ""
                arg = re.sub(r"//.*|/\*.*?\*/", "", arg).strip()
                if d == "ifdef":
                    skip.append(any(skip) or arg not in self.macros)
                elif d == "ifndef":
                    skip.append(any(skip) or arg in self.macros)
                elif d == "if":
                    if arg.strip() not in ("0", "1"):
                        raise CError(f"{path}:{lineno}: only #if 0 / #if 1 are supported")
                    skip.append(any(skip) or arg.strip() == "0")
                elif d == "else":
                    if not skip:
                        raise CError(f"{path}:{lineno}: #else without #if")
                    skip[-1] = (not skip[-1]) or any(skip[:-1])
                elif d == "endif":
                    if not skip:
                        raise CError(f"{path}:{lineno}: #endif without #if")
                    skip.pop()
                elif any(skip):
                    pass
                elif d == "include":
                    m = re.fullmatch(r'"([^"]+)"|<([^>]+)>', arg)
                    if not m:
                        raise CError(f"{path}:{lineno}: bad #include")
                    name = m.group(1) or m.group(2)
                    for d_ in [path.parent] + self.include_dirs:
                        cand = Path(d_) / name
                        if cand.exists():
                            out += self.file_tokens(cand)
                            break
                    else:
                        raise CError(f"{path}:{lineno}: cannot find {name}")
                elif d == "define":
                    m = re.fullmatch(r"(\w+)(\(([^)]*)\))?\s*(.*)", arg, re.S)
                    if not m:
                        raise CError(f"{path}:{lineno}: bad #define")
                    params = [p.strip() for p in m.group(3).split(",")] if m.group(2) else None
                    if params == [""]:
                        params = []
                    self.macros[m.group(1)] = (params, self.lex_line(m.group(4), str(path), lineno))
                elif d == "undef":
                    self.macros.pop(arg, None)
                elif d in ("pragma", "error", "line"):
                    if d == "error":
                        raise CError(f"{path}:{lineno}: #error {arg}")
                else:
                    raise CError(f"{path}:{lineno}: unknown directive #{d}")
                i += 1
                continue
            if any(skip):
                i += 1
                continue
            out += self.expand(self.lex_line(raw, str(path), lineno))
            i += 1
        if skip:
            raise CError(f"{path}: missing #endif")
        return out

    def expand(self, toks, depth=0):
        """Macro expansion of a token list (object-like and function-like, recursive, no self-reference)."""
        if depth > 50:
            raise CError("macro expansion too deep")
        out = []
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.kind == "id" and t.text in self.macros:
                params, body = self.macros[t.text]
                if params is None:
                    rep = [Tok(b.kind, b.text, t.line, t.file) for b in body]
                    out += self.expand(rep, depth + 1)
                    i += 1
                    continue
                if i + 1 < len(toks) and toks[i + 1].text == "(":
                    # collect the arguments
                    args, cur, level, j = [], [], 0, i + 2
                    while j < len(toks):
                        tj = toks[j]
                        if tj.text == "(":
                            level += 1
                        elif tj.text == ")":
                            if level == 0:
                                break
                            level -= 1
                        if tj.text == "," and level == 0:
                            args.append(cur)
                            cur = []
                        else:
                            cur.append(tj)
                        j += 1
                    if j >= len(toks):
                        raise CError(f"{t.file}:{t.line}: unterminated macro call {t.text}")
                    args.append(cur)
                    if len(params) == 0 and args == [[]]:
                        args = []
                    if len(args) != len(params):
                        raise CError(f"{t.file}:{t.line}: macro {t.text} takes {len(params)} arguments")
                    rep = []
                    for b in body:
                        if b.kind == "id" and b.text in params:
                            rep += [Tok("punct", "(", t.line, t.file)] + \
                                   [Tok(x.kind, x.text, t.line, t.file) for x in args[params.index(b.text)]] + \
                                   [Tok("punct", ")", t.line, t.file)]
                        else:
                            rep.append(Tok(b.kind, b.text, t.line, t.file))
                    out += self.expand(rep, depth + 1)
                    i = j + 1
                    continue
            out.append(t)
            i += 1
        return out


# ============================================================ types
class Type:
    __slots__ = ("kind", "base", "count", "unsigned")

    def __init__(self, kind, base=None, count=0, unsigned=False):
        self.kind, self.base, self.count, self.unsigned = kind, base, count, unsigned

    @property
    def size(self):
        if self.kind == "int" or self.kind == "ptr":
            return 4
        if self.kind == "char":
            return 1
        if self.kind == "array":
            return self.count * self.base.size
        return 0

    @property
    def is_ptr(self):
        return self.kind in ("ptr", "array")

    @property
    def is_int(self):
        return self.kind in ("int", "char")

    def elem(self):
        """The pointed-to / element type."""
        if self.kind in ("ptr", "array"):
            return self.base
        raise CError("not a pointer")

    def decay(self):
        return Type("ptr", self.base) if self.kind == "array" else self

    def __repr__(self):
        if self.kind == "ptr":
            return f"{self.base!r}*"
        if self.kind == "array":
            return f"{self.base!r}[{self.count}]"
        return ("unsigned " if self.unsigned else "") + self.kind


INT = Type("int")
UINT = Type("int", unsigned=True)
CHAR = Type("char")
UCHAR = Type("char", unsigned=True)
VOID = Type("void")


class Var:
    __slots__ = ("name", "type", "where", "offset")      # where: "global" | "local"; offset for locals (s0-relative)

    def __init__(self, name, type_, where, offset=0):
        self.name, self.type, self.where, self.offset = name, type_, where, offset


class Func:
    __slots__ = ("name", "ret", "params", "defined")

    def __init__(self, name, ret, params, defined):
        self.name, self.ret, self.params, self.defined = name, ret, params, defined


# ============================================================ parser + code generator (one pass)
class Compiler:
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0
        self.out = []               # the whole .s
        self.data = []              # .data lines
        self.bss = []               # .bss lines
        self.strings = {}           # literal -> label
        self.globals = {}           # name -> Var
        self.funcs = {}             # name -> Func
        self.scopes = []            # list of dicts name -> Var
        self.label_no = 0
        self.frame = 0              # bytes of locals in the current function
        self.cur = None             # current Func
        self.loop_stack = []        # (break_label, continue_label)
        self.body = []              # lines of the current function body
        self.switch_stack = []      # for case collection: (cases list, default label)
        self.const_at = None        # (body index, value) when the last emitted line is "li a0, literal"

    # ---- tokens
    def peek(self, k=0):
        if self.pos + k < len(self.toks):
            return self.toks[self.pos + k]
        return Tok("eof", "", self.toks[-1].line if self.toks else 0, self.toks[-1].file if self.toks else "")

    def next(self):
        t = self.peek()
        self.pos += 1
        return t

    def at(self, text):
        return self.peek().text == text and self.peek().kind in ("punct", "id")

    def accept(self, text):
        if self.at(text):
            self.pos += 1
            return True
        return False

    def expect(self, text):
        t = self.next()
        if t.text != text:
            raise self.err(f"expected '{text}', got '{t.text}'", t)
        return t

    def err(self, msg, tok=None):
        tok = tok or self.peek()
        return CError(f"{tok.file}:{tok.line}: {msg}")

    def label(self, hint="L"):
        self.label_no += 1
        return f".{hint}{self.label_no}"

    def emit(self, line):
        self.body.append("\t" + line if not line.endswith(":") else line)
        self.const_at = None            # the last line is no longer a literal constant (primary sets it)

    def last_is_constant(self):
        """The value in a0 is a literal the last emitted line loaded: (index, value), or None."""
        if self.const_at is not None and self.const_at[0] == len(self.body) - 1:
            return self.const_at
        return None

    # ---- scopes
    def push_scope(self):
        self.scopes.append({})

    def pop_scope(self):
        self.scopes.pop()

    def declare_local(self, name, type_, tok):
        if name in self.scopes[-1]:
            raise self.err(f"redeclared {name}", tok)
        size = (type_.size + 3) & ~3
        self.frame += size
        v = Var(name, type_, "local", -(self.frame + 8))      # below the saved ra (s0-4) and s0 (s0-8)
        self.scopes[-1][name] = v
        return v

    def lookup(self, name, tok):
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        if name in self.globals:
            return self.globals[name]
        raise self.err(f"undeclared identifier {name}", tok)

    # ---- types
    def is_type_start(self):
        return self.peek().kind == "id" and self.peek().text in ("int", "char", "void", "unsigned", "signed",
                                                                   "const", "volatile", "static", "extern")

    def parse_base_type(self):
        unsigned = False
        kind = None
        while self.peek().kind == "id" and self.peek().text in ("const", "volatile", "static", "extern", "unsigned",
                                                                  "signed", "int", "char", "void"):
            t = self.next().text
            if t == "unsigned":
                unsigned = True
            elif t in ("int", "char", "void"):
                kind = t
        if kind is None:
            kind = "int"            # "unsigned x"
        if kind == "void":
            return VOID
        return Type(kind, unsigned=unsigned)

    def parse_declarator(self, base):
        """Pointers, the name, array dimensions. Returns (name token, type)."""
        t = base
        while self.accept("*"):
            t = Type("ptr", t)
            while self.peek().text in ("const", "volatile"):
                self.next()
        name = self.next()
        if name.kind != "id":
            raise self.err("expected a name", name)
        dims = []
        while self.accept("["):
            if self.at("]"):
                dims.append(None)
            else:
                dims.append(self.const_expr())
            self.expect("]")
        for d in reversed(dims):
            t = Type("array", t, d if d is not None else 0)
        return name, t

    def parse_abstract_type(self):
        """For casts and sizeof: base type, then * and [N]."""
        t = self.parse_base_type()
        while self.accept("*"):
            t = Type("ptr", t)
        return t

    # ---- constant expressions (array sizes, case labels, global initialisers)
    def const_expr(self):
        save = self.pos
        node = self.parse_ternary_const()
        return node

    def parse_ternary_const(self):
        v = self.parse_binary_const(0)
        if self.accept("?"):
            a = self.parse_ternary_const()
            self.expect(":")
            b = self.parse_ternary_const()
            return a if v else b
        return v

    CONST_OPS = [("||",), ("&&",), ("|",), ("^",), ("&",), ("==", "!="), ("<", ">", "<=", ">="), ("<<", ">>"),
                 ("+", "-"), ("*", "/", "%")]

    def parse_binary_const(self, level):
        if level >= len(self.CONST_OPS):
            return self.parse_unary_const()
        v = self.parse_binary_const(level + 1)
        while self.peek().kind == "punct" and self.peek().text in self.CONST_OPS[level]:
            op = self.next().text
            w = self.parse_binary_const(level + 1)
            v = self.fold(op, v, w)
        return v

    @staticmethod
    def fold(op, a, b):
        def s32(x):
            x &= 0xFFFFFFFF
            return x - (1 << 32) if x & 0x80000000 else x
        a, b = s32(a), s32(b)
        if op == "+": return s32(a + b)
        if op == "-": return s32(a - b)
        if op == "*": return s32(a * b)
        if op == "/":
            if b == 0: raise CError("division by zero in a constant")
            return s32(int(a / b))
        if op == "%":
            if b == 0: raise CError("division by zero in a constant")
            return s32(a - int(a / b) * b)
        if op == "<<": return s32(a << (b & 31))
        if op == ">>": return s32(a >> (b & 31))
        if op == "&": return s32(a & b)
        if op == "|": return s32(a | b)
        if op == "^": return s32(a ^ b)
        if op == "==": return int(a == b)
        if op == "!=": return int(a != b)
        if op == "<": return int(a < b)
        if op == ">": return int(a > b)
        if op == "<=": return int(a <= b)
        if op == ">=": return int(a >= b)
        if op == "&&": return int(bool(a) and bool(b))
        if op == "||": return int(bool(a) or bool(b))
        raise CError(f"bad constant operator {op}")

    def parse_unary_const(self):
        t = self.peek()
        if t.text == "-":
            self.next()
            return self.fold("-", 0, self.parse_unary_const())
        if t.text == "+":
            self.next()
            return self.parse_unary_const()
        if t.text == "~":
            self.next()
            return self.fold("^", -1, self.parse_unary_const())
        if t.text == "!":
            self.next()
            return int(not self.parse_unary_const())
        if t.text == "(":
            if self.peek(1).kind == "id" and self.peek(1).text in ("int", "char", "unsigned", "signed", "const"):
                self.next()
                ty = self.parse_abstract_type()
                self.expect(")")
                v = self.parse_unary_const()
                return self.cast_const(v, ty)
            self.next()
            v = self.parse_ternary_const()
            self.expect(")")
            return v
        if t.kind == "id" and t.text == "sizeof":
            self.next()
            self.expect("(")
            ty = self.parse_abstract_type()
            self.expect(")")
            return ty.size
        if t.kind == "num":
            self.next()
            return self.number(t)
        if t.kind == "chr":
            self.next()
            return self.char_value(t)
        raise self.err("expected a constant", t)

    @staticmethod
    def cast_const(v, ty):
        if ty.kind == "char":
            v &= 0xFF
            return v if ty.unsigned or v < 128 else v - 256
        return v

    @staticmethod
    def number(t):
        return int(re.sub(r"[uUlL]+$", "", t.text), 0)

    @staticmethod
    def char_value(t):
        return ord(bytes(t.text[1:-1], "utf-8").decode("unicode_escape"))

    # ---- top level
    def compile(self):
        while self.peek().kind != "eof":
            self.top_declaration()
        lines = ["# GENERATED by tools/cc.py", "\t.text", "\t.globl main"]
        lines += self.out
        lines += ["", "\t.data", "\t.align 2"] + self.data
        lines += ["", "\t.align 2", "__bss_start:"] + self.bss + ["\t.align 2", "__bss_end:"]
        return "\n".join(lines) + "\n"

    def top_declaration(self):
        base = self.parse_base_type()
        if self.accept(";"):
            return
        while True:
            name, ty = self.parse_declarator(base)
            if self.at("("):
                self.function(name, ty)
                return
            self.global_var(name, ty)
            if self.accept(","):
                continue
            self.expect(";")
            return

    def global_var(self, name, ty):
        if name.text in self.globals and self.globals[name.text].type.size:
            # a repeated extern declaration is fine; a second definition is not
            if self.at("="):
                raise self.err(f"{name.text} defined twice", name)
            return
        if self.accept("="):
            items = self.initializer(ty, name)
            if ty.kind == "array" and ty.count == 0:
                ty = Type("array", ty.base, len(items) if ty.base.kind != "array" else len(items) // max(ty.base.count, 1))
            self.data.append(f"\t.align 2")
            self.data.append(f"{name.text}:")
            unit = ".byte" if (ty.base.kind == "char" if ty.kind == "array" else ty.kind == "char") else ".word"
            for i in range(0, len(items), 8):
                self.data.append(f"\t{unit} " + ", ".join(str(x) for x in items[i:i + 8]))
            if not items:
                self.data.append(f"\t.space {max(ty.size, 1)}")
        else:
            if ty.kind == "array" and ty.count == 0:
                raise self.err(f"array {name.text} needs a size", name)
            self.bss.append(f"\t.align 2")
            self.bss.append(f"{name.text}:")
            self.bss.append(f"\t.space {max(ty.size, 4)}")
        self.globals[name.text] = Var(name.text, ty, "global")

    def initializer(self, ty, name):
        """Returns the list of numbers (words, or bytes for char arrays) to emit; strings become labels."""
        if ty.kind == "array":
            if self.peek().kind == "str":
                if ty.base.kind != "char":
                    raise self.err("a string initialises a char array", name)
                s = self.string_bytes(self.next())
                if ty.count and len(s) + 1 > ty.count:
                    raise self.err(f"string too long for {name.text}", name)
                vals = list(s) + [0]
                if ty.count:
                    vals += [0] * (ty.count - len(vals))
                return vals
            self.expect("{")
            vals = []
            while not self.at("}"):
                if ty.base.kind == "array":
                    sub = self.initializer(ty.base, name)
                    sub += [0] * (ty.base.count - len(sub)) if ty.base.base.kind != "array" else []
                    vals += sub
                elif self.at("{"):
                    raise self.err("too many braces", name)
                else:
                    vals.append(self.init_value(ty.base, name))
                if not self.accept(","):
                    break
            self.expect("}")
            if ty.count:
                elem_words = ty.base.count if ty.base.kind == "array" else 1
                if len(vals) > ty.count * elem_words:
                    raise self.err(f"too many initialisers for {name.text}", name)
                vals += [0] * (ty.count * elem_words - len(vals))
            return vals
        return [self.init_value(ty, name)]

    def init_value(self, ty, name):
        if self.peek().kind == "str":
            if ty.kind != "ptr" or ty.base.kind != "char":
                raise self.err("a string literal initialises a char *", name)
            return self.string_label(self.next())
        v = self.const_expr()
        return self.cast_const(v, ty) if ty.kind == "char" else v

    def string_bytes(self, tok):
        raw = tok.text[1:-1]
        return bytes(raw, "utf-8").decode("unicode_escape").encode("latin-1")

    def string_label(self, tok):
        s = self.string_bytes(tok)
        if s not in self.strings:
            lab = self.label("S")
            self.strings[s] = lab
            self.data.append(f"{lab}:")
            self.data.append("\t.byte " + ", ".join(str(b) for b in s + b"\0"))
        return self.strings[s]

    # ---- functions
    def function(self, name, ret):
        self.expect("(")
        params = []
        if not self.at(")"):
            if self.at("void") and self.peek(1).text == ")":
                self.next()
            else:
                while True:
                    base = self.parse_base_type()
                    pname, pty = self.parse_declarator(base)
                    if pty.kind == "array":
                        pty = Type("ptr", pty.base)
                    params.append((pname, pty))
                    if not self.accept(","):
                        break
        self.expect(")")
        if len(params) > 8:
            raise self.err("at most 8 parameters", name)
        if name.text in self.funcs and self.funcs[name.text].defined and not self.at(";"):
            raise self.err(f"function {name.text} defined twice", name)
        f = Func(name.text, ret, [p[1] for p in params], defined=False)
        if self.accept(";"):
            self.funcs.setdefault(name.text, f)
            return
        f.defined = True
        self.funcs[name.text] = f
        self.cur = f
        self.frame = 0
        self.body = []
        self.push_scope()
        for i, (pname, pty) in enumerate(params):
            v = self.declare_local(pname.text, pty, pname)
            self.emit(f"sw a{i}, {v.offset}(s0)")
        self.block(new_scope=False)
        self.pop_scope()
        self.emit(f"{self.ret_label()}:")
        size = (self.frame + 8 + 15) & ~15
        self.out += [f"", f"{name.text}:", f"\taddi sp, sp, -{size}", f"\tsw ra, {size - 4}(sp)",
                     f"\tsw s0, {size - 8}(sp)", f"\taddi s0, sp, {size}"]
        self.out += self.body
        self.out += [f"\tlw ra, {size - 4}(sp)", f"\tlw s0, {size - 8}(sp)", f"\taddi sp, sp, {size}", "\tret"]
        self.cur = None

    def ret_label(self):
        return f".ret_{self.cur.name}"

    # ---- statements
    def block(self, new_scope=True):
        self.expect("{")
        if new_scope:
            self.push_scope()
        while not self.at("}"):
            if self.peek().kind == "eof":
                raise self.err("missing }")
            self.statement()
        self.expect("}")
        if new_scope:
            self.pop_scope()

    def statement(self):
        t = self.peek()
        if t.text == "{":
            self.block()
        elif self.is_type_start():
            self.local_declaration()
            self.expect(";")
        elif t.kind == "id" and t.text == "if":
            self.next()
            self.expect("(")
            self.expression()
            self.expect(")")
            else_l, end_l = self.label("else"), self.label("endif")
            self.emit(f"beqz a0, {else_l}")
            self.statement()
            if self.accept("else"):
                self.emit(f"j {end_l}")
                self.emit(f"{else_l}:")
                self.statement()
                self.emit(f"{end_l}:")
            else:
                self.emit(f"{else_l}:")
        elif t.kind == "id" and t.text == "while":
            self.next()
            top, end = self.label("while"), self.label("endwhile")
            self.emit(f"{top}:")
            self.expect("(")
            self.expression()
            self.expect(")")
            self.emit(f"beqz a0, {end}")
            self.loop_stack.append((end, top))
            self.statement()
            self.loop_stack.pop()
            self.emit(f"j {top}")
            self.emit(f"{end}:")
        elif t.kind == "id" and t.text == "do":
            self.next()
            top, cont, end = self.label("do"), self.label("docond"), self.label("enddo")
            self.emit(f"{top}:")
            self.loop_stack.append((end, cont))
            self.statement()
            self.loop_stack.pop()
            self.expect("while")
            self.expect("(")
            self.emit(f"{cont}:")
            self.expression()
            self.expect(")")
            self.expect(";")
            self.emit(f"bnez a0, {top}")
            self.emit(f"{end}:")
        elif t.kind == "id" and t.text == "for":
            self.next()
            self.expect("(")
            self.push_scope()
            if not self.at(";"):
                if self.is_type_start():
                    self.local_declaration()
                else:
                    self.expression()
            self.expect(";")
            top, cont, end = self.label("for"), self.label("forstep"), self.label("endfor")
            self.emit(f"{top}:")
            if not self.at(";"):
                self.expression()
                self.emit(f"beqz a0, {end}")
            self.expect(";")
            # the step expression is parsed now but emitted after the body: save its tokens
            step_start = self.pos
            depth = 0
            while not (self.at(")") and depth == 0):
                if self.at("("):
                    depth += 1
                elif self.at(")"):
                    depth -= 1
                self.next()
            step_end = self.pos
            self.expect(")")
            self.loop_stack.append((end, cont))
            self.statement()
            self.loop_stack.pop()
            self.emit(f"{cont}:")
            if step_end > step_start:
                save = self.pos
                self.pos = step_start
                self.expression()
                self.pos = save
            self.emit(f"j {top}")
            self.emit(f"{end}:")
            self.pop_scope()
        elif t.kind == "id" and t.text == "switch":
            self.switch()
        elif t.kind == "id" and t.text in ("case", "default"):
            if not self.switch_stack:
                raise self.err("case outside switch", t)
            self.next()
            cases, default = self.switch_stack[-1]
            lab = self.label("case")
            if t.text == "case":
                cases.append((self.const_expr(), lab))
            else:
                self.switch_stack[-1][1].append(lab)
            self.expect(":")
            self.emit(f"{lab}:")
        elif t.kind == "id" and t.text == "break":
            self.next()
            self.expect(";")
            if not self.loop_stack:
                raise self.err("break outside a loop", t)
            self.emit(f"j {self.loop_stack[-1][0]}")
        elif t.kind == "id" and t.text == "continue":
            self.next()
            self.expect(";")
            for brk, cont in reversed(self.loop_stack):
                if cont is not None:
                    self.emit(f"j {cont}")
                    break
            else:
                raise self.err("continue outside a loop", t)
        elif t.kind == "id" and t.text == "return":
            self.next()
            if not self.at(";"):
                self.expression()
            self.expect(";")
            self.emit(f"j {self.ret_label()}")
        elif self.accept(";"):
            pass
        else:
            self.expression()
            self.expect(";")

    def switch(self):
        self.next()
        self.expect("(")
        self.expression()
        self.expect(")")
        end = self.label("endswitch")
        # the body is parsed with its cases collected; the dispatch is emitted before it
        dispatch_at = len(self.body)
        self.switch_stack.append(([], []))
        self.loop_stack.append((end, None))
        self.statement()
        self.loop_stack.pop()
        cases, default = self.switch_stack.pop()
        dispatch = []
        for value, lab in cases:
            dispatch.append(f"\tli a1, {value}")
            dispatch.append(f"\tbeq a0, a1, {lab}")
        dispatch.append(f"\tj {default[0] if default else end}")
        self.body[dispatch_at:dispatch_at] = dispatch
        self.emit(f"{end}:")

    def local_declaration(self):
        base = self.parse_base_type()
        while True:
            name, ty = self.parse_declarator(base)
            if ty.kind == "array" and ty.count == 0:
                raise self.err("a local array needs a size", name)
            if ty.kind == "void":
                raise self.err("a variable cannot be void", name)
            v = self.declare_local(name.text, ty, name)
            if self.accept("="):
                if ty.kind == "array":
                    raise self.err("initialising a local array is not supported (assign in a loop)", name)
                self.assignment()
                self.store_to(f"{v.offset}(s0)", ty)
            if not self.accept(","):
                break

    # ---- expressions: every function leaves the value in a0 and returns its type
    def expression(self):
        return self.assignment()

    def push(self):
        self.emit("addi sp, sp, -4")
        self.emit("sw a0, 0(sp)")

    def pop(self, reg="a1"):
        self.emit(f"lw {reg}, 0(sp)")
        self.emit("addi sp, sp, 4")

    def load_from(self, addr, ty):
        if ty.kind == "char":
            self.emit(f"{'lbu' if ty.unsigned else 'lb'} a0, {addr}")
        elif ty.kind == "array":
            self.emit(f"addi a0, {addr.split('(')[1][:-1]}, {addr.split('(')[0]}") if "(" in addr else None
        else:
            self.emit(f"lw a0, {addr}")

    def store_to(self, addr, ty):
        self.emit(f"{'sb' if ty.kind == 'char' else 'sw'} a0, {addr}")

    def assignment(self):
        start = self.pos
        # is this an assignment? parse the left side as a ternary; if an assignment operator follows, redo as lvalue
        save_body = len(self.body)
        ty = self.ternary()
        t = self.peek()
        if t.kind == "punct" and t.text in ("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="):
            del self.body[save_body:]
            self.pos = start
            lty = self.lvalue_address()          # a0 = address
            if lty.kind == "array":
                raise self.err("cannot assign to an array", t)
            self.next()
            self.push()
            if t.text == "=":
                rty = self.assignment()
                self.pop("a1")
                self.store_to("0(a1)", lty)
                return lty
            op = t.text[:-1]
            rty = self.assignment()
            self.pop("a1")                          # a1 = address, a0 = right value
            self.emit("mv a2, a0")
            self.emit(f"{'lbu' if lty.unsigned else 'lb'} a0, 0(a1)" if lty.kind == "char" else "lw a0, 0(a1)")
            self.emit("mv a3, a1")                  # keep the address: the op may call __mul and clobber a1
            self.push()                             # left value on the stack
            self.emit("mv a0, a2")
            self.push_reg("a3")
            self.binary_op(op, lty, rty, left_on_stack=True, addr_on_stack=True)
            self.pop("a1")
            self.store_to("0(a1)", lty)
            return lty
        return ty

    def push_reg(self, reg):
        self.emit("addi sp, sp, -4")
        self.emit(f"sw {reg}, 0(sp)")

    def ternary(self):
        ty = self.logical_or()
        if self.accept("?"):
            else_l, end_l = self.label("tern"), self.label("terne")
            self.emit(f"beqz a0, {else_l}")
            t1 = self.assignment()
            self.emit(f"j {end_l}")
            self.expect(":")
            self.emit(f"{else_l}:")
            t2 = self.ternary()
            self.emit(f"{end_l}:")
            return t1.decay() if t1.is_ptr else t1
        return ty

    def logical_or(self):
        ty = self.logical_and()
        if self.at("||"):
            end = self.label("or")
            while self.accept("||"):
                self.emit("snez a0, a0")
                self.emit(f"bnez a0, {end}")
                self.logical_and()
            self.emit("snez a0, a0")
            self.emit(f"{end}:")
            return INT
        return ty

    def logical_and(self):
        ty = self.binary(0)
        if self.at("&&"):
            end = self.label("and")
            while self.accept("&&"):
                self.emit("snez a0, a0")
                self.emit(f"beqz a0, {end}")
                self.binary(0)
            self.emit("snez a0, a0")
            self.emit(f"{end}:")
            return INT
        return ty

    BIN_LEVELS = [("|",), ("^",), ("&",), ("==", "!="), ("<", ">", "<=", ">="), ("<<", ">>"), ("+", "-"),
                  ("*", "/", "%")]

    def binary(self, level):
        if level >= len(self.BIN_LEVELS):
            return self.unary()
        lty = self.binary(level + 1)
        while self.peek().kind == "punct" and self.peek().text in self.BIN_LEVELS[level]:
            op = self.next().text
            # a constant right operand (complete only if the next operator binds no tighter): no stack traffic
            cval = self.try_constant_operand(level)
            if cval is not None:
                left = self.last_is_constant()
                if left is not None and lty.is_int:            # literal op literal: fold at compile time
                    unsigned = lty.unsigned or self.const_rhs_unsigned
                    v = (self.fold_unsigned if unsigned else self.fold)(op, left[1], cval)
                    self.body[-1] = f"\tli a0, {v}"
                    self.const_at = (len(self.body) - 1, v)
                    if unsigned:
                        lty = UINT
                    continue
                lty = self.binary_const(op, lty, cval)
                continue
            self.push()
            rty = self.binary(level + 1)
            self.pop("a1")
            lty = self.binary_op(op, lty, rty, left_on_stack=False)
        return lty

    def try_constant_operand(self, level):
        """If the next operand (at this precedence level) is a plain constant, consume it and return its value."""
        t = self.peek()
        nxt = self.peek(1)
        ends = nxt.kind == "punct" and (nxt.text in (";", ")", "]", ",", "?", ":", "}") or
                                        any(nxt.text in lv for lv in self.BIN_LEVELS[:level + 1]) or
                                        nxt.text in ("||", "&&", "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
                                                     "<<=", ">>="))
        if t.kind == "num" and ends:
            self.next()
            self.const_rhs_unsigned = "u" in t.text.lower()
            return self.number(t)
        if t.kind == "chr" and ends:
            self.next()
            self.const_rhs_unsigned = False
            return self.char_value(t)
        return None

    @staticmethod
    def fold_unsigned(op, a, b):
        """Constant folding with unsigned 32-bit semantics for the operators where it matters."""
        a &= 0xFFFFFFFF
        b &= 0xFFFFFFFF
        if op == "/":
            if b == 0: raise CError("division by zero in a constant")
            return a // b
        if op == "%":
            if b == 0: raise CError("division by zero in a constant")
            return a % b
        if op == ">>": return a >> (b & 31)
        if op == "<": return int(a < b)
        if op == ">": return int(a > b)
        if op == "<=": return int(a <= b)
        if op == ">=": return int(a >= b)
        return Compiler.fold(op, a, b)

    def result_type(self, op, lty, rty):
        if op in ("==", "!=", "<", ">", "<=", ">="):
            return INT
        if op == "+" and lty.is_ptr and rty.is_int:
            return lty.decay()
        if op == "+" and rty.is_ptr and lty.is_int:
            return rty.decay()
        if op == "-" and lty.is_ptr and rty.is_int:
            return lty.decay()
        if op == "-" and lty.is_ptr and rty.is_ptr:
            return INT
        if lty.is_ptr or rty.is_ptr:
            raise self.err(f"bad pointer arithmetic with {op}")
        # the usual arithmetic conversions, reduced: an unsigned int on either side makes the result unsigned
        return UINT if (lty.kind == "int" and lty.unsigned) or (rty.kind == "int" and rty.unsigned) else INT

    def scale(self, reg, size):
        if size == 4:
            self.emit(f"slli {reg}, {reg}, 2")
        elif size == 2:
            self.emit(f"slli {reg}, {reg}, 1")
        elif size != 1:
            self.emit(f"li a4, {size}")
            self.emit(f"mv a5, a0")
            self.emit(f"mv a0, {reg}")
            self.emit("mv a1, a4")
            self.emit("call __mul")
            if reg != "a0":
                self.emit(f"mv {reg}, a0")
                self.emit("mv a0, a5")

    def binary_const(self, op, lty, c):
        """a0 = a0 op c, c a constant."""
        if op in ("+", "-") and lty.is_ptr:
            c = c * lty.elem().size
        if op == "*":
            if lty.is_ptr:
                raise self.err("bad pointer arithmetic")
            if c > 0 and (c & (c - 1)) == 0:
                self.emit(f"slli a0, a0, {c.bit_length() - 1}")
                return lty
            if 0 < c < 4096 and bin(c).count("1") <= 3:        # a few shifts and adds beat the 32-step __mul
                bits = [i for i in range(12) if c >> i & 1]
                self.emit("mv a1, a0")
                self.emit(f"slli a0, a1, {bits[-1]}" if bits[-1] else "mv a0, a1")
                for b in bits[:-1]:
                    self.emit(f"slli a2, a1, {b}" if b else "mv a2, a1")
                    self.emit("add a0, a0, a2")
                return lty
            self.emit(f"li a1, {c}")
            self.emit("call __mul")
            return lty
        if op in ("/", "%") and c > 0 and (c & (c - 1)) == 0 and lty.unsigned:
            n = c.bit_length() - 1
            self.emit(f"srli a0, a0, {n}" if op == "/" else f"andi a0, a0, {c - 1}" if c <= 2048 else f"li a1, {c-1}\n\tand a0, a0, a1")
            return lty
        if op in ("/", "%"):
            self.emit(f"li a1, {c}")
            self.emit("call " + {"/": "__udiv" if lty.unsigned else "__div", "%": "__umod" if lty.unsigned else "__mod"}[op])
            return lty
        if op in ("+", "-", "&", "|", "^") and -2048 <= (c if op != "-" else -c) <= 2047:
            mn = {"+": "addi", "-": "addi", "&": "andi", "|": "ori", "^": "xori"}[op]
            self.emit(f"{mn} a0, a0, {c if op != '-' else -c}")
            return self.result_type(op, lty, INT)
        if op in ("<<", ">>"):
            self.emit(f"{'slli' if op == '<<' else ('srli' if lty.unsigned else 'srai')} a0, a0, {c & 31}")
            return lty
        if op in ("<", ">=") and -2048 <= c <= 2047:
            self.emit(f"{'sltiu' if lty.unsigned else 'slti'} a0, a0, {c}")
            if op == ">=":
                self.emit("xori a0, a0, 1")
            return INT
        self.emit("mv a1, a0")                  # binary_op wants the left value in a1 and the right in a0
        self.emit(f"li a0, {c}")
        return self.binary_op(op, lty, INT, left_on_stack=False)

    def binary_op(self, op, lty, rty, left_on_stack, addr_on_stack=False):
        """a0 = a1 op a0 (left in a1, right in a0) when not left_on_stack; else left on the stack top, right in a0."""
        if left_on_stack:
            # stack: [addr][left]; a0 = right. We need a1 = left, keep the address below.
            self.pop("a1") if not addr_on_stack else None
            if addr_on_stack:
                self.pop("a1")              # address
                self.emit("mv a3, a1")
                self.pop("a1")              # left
                self.push_reg("a3")         # address back on the stack
        unsigned = lty.unsigned or rty.unsigned
        if op == "+":
            if lty.is_ptr and rty.is_int:
                self.scale("a0", lty.elem().size)
            elif rty.is_ptr and lty.is_int:
                self.scale("a1", rty.elem().size)
            self.emit("add a0, a1, a0")
        elif op == "-":
            if lty.is_ptr and rty.is_int:
                self.scale("a0", lty.elem().size)
                self.emit("sub a0, a1, a0")
            elif lty.is_ptr and rty.is_ptr:
                self.emit("sub a0, a1, a0")
                size = lty.elem().size
                if size == 4:
                    self.emit("srai a0, a0, 2")
                elif size != 1:
                    self.emit(f"li a1, {size}")
                    self.emit("call __div")
            else:
                self.emit("sub a0, a1, a0")
        elif op == "*":
            self.emit("mv a2, a0")
            self.emit("mv a0, a1")
            self.emit("mv a1, a2")
            self.emit("call __mul")
        elif op in ("/", "%"):
            self.emit("mv a2, a0")
            self.emit("mv a0, a1")
            self.emit("mv a1, a2")
            self.emit("call " + {"/": "__udiv" if unsigned else "__div", "%": "__umod" if unsigned else "__mod"}[op])
        elif op == "&":
            self.emit("and a0, a1, a0")
        elif op == "|":
            self.emit("or a0, a1, a0")
        elif op == "^":
            self.emit("xor a0, a1, a0")
        elif op == "<<":
            self.emit("sll a0, a1, a0")
        elif op == ">>":
            self.emit(f"{'srl' if lty.unsigned else 'sra'} a0, a1, a0")
        elif op == "==":
            self.emit("xor a0, a1, a0")
            self.emit("seqz a0, a0")
        elif op == "!=":
            self.emit("xor a0, a1, a0")
            self.emit("snez a0, a0")
        elif op == "<":
            self.emit(f"{'sltu' if unsigned or lty.is_ptr else 'slt'} a0, a1, a0")
        elif op == ">":
            self.emit(f"{'sltu' if unsigned or lty.is_ptr else 'slt'} a0, a0, a1")
        elif op == "<=":
            self.emit(f"{'sltu' if unsigned or lty.is_ptr else 'slt'} a0, a0, a1")
            self.emit("xori a0, a0, 1")
        elif op == ">=":
            self.emit(f"{'sltu' if unsigned or lty.is_ptr else 'slt'} a0, a1, a0")
            self.emit("xori a0, a0, 1")
        else:
            raise self.err(f"operator {op} not supported")
        return self.result_type(op, lty, rty)

    def unary(self):
        t = self.peek()
        if t.kind == "punct":
            if t.text == "-":
                self.next()
                ty = self.unary()
                self.emit("neg a0, a0")
                return ty
            if t.text == "+":
                self.next()
                return self.unary()
            if t.text == "!":
                self.next()
                self.unary()
                self.emit("seqz a0, a0")
                return INT
            if t.text == "~":
                self.next()
                ty = self.unary()
                self.emit("not a0, a0")
                return ty
            if t.text == "*":
                self.next()
                ty = self.unary()
                if not ty.is_ptr:
                    raise self.err("dereferencing a non-pointer", t)
                et = ty.elem()
                if et.kind == "array":
                    return et                   # *p of a pointer to array: still an address
                self.load_from("0(a0)", et)
                return et
            if t.text == "&":
                self.next()
                return Type("ptr", self.lvalue_address())
            if t.text in ("++", "--"):
                self.next()
                ty = self.lvalue_address()
                step = ty.elem().size if ty.is_ptr else 1
                self.emit("mv a1, a0")
                self.load_from("0(a1)", ty)
                self.emit(f"addi a0, a0, {step if t.text == '++' else -step}")
                self.store_to("0(a1)", ty)
                return ty
            if t.text == "(" and self.peek(1).kind == "id" and self.peek(1).text in ("int", "char", "void", "unsigned",
                                                                                       "signed", "const", "volatile"):
                self.next()
                ty = self.parse_abstract_type()
                self.expect(")")
                inner = self.unary()
                if ty.kind == "char":
                    if ty.unsigned:
                        self.emit("andi a0, a0, 255")
                    else:
                        self.emit("slli a0, a0, 24")
                        self.emit("srai a0, a0, 24")
                return ty if ty.kind != "void" else VOID
        if t.kind == "id" and t.text == "sizeof":
            self.next()
            if self.at("(") and self.peek(1).kind == "id" and self.peek(1).text in ("int", "char", "void", "unsigned",
                                                                                      "signed", "const"):
                self.next()
                ty = self.parse_abstract_type()
                self.expect(")")
                size = ty.size
            else:
                save_body = len(self.body)
                ty = self.unary()
                del self.body[save_body:]
                size = ty.size
            self.emit(f"li a0, {size}")
            return INT
        return self.postfix()

    def postfix(self):
        ty = self.primary()
        while True:
            t = self.peek()
            if t.text == "[":
                self.next()
                if not ty.is_ptr:
                    raise self.err("indexing a non-pointer", t)
                et = ty.elem()
                self.push()
                self.expression()
                self.expect("]")
                self.scale("a0", et.size)
                self.pop("a1")
                self.emit("add a0, a1, a0")
                if et.kind == "array":
                    ty = et
                else:
                    self.load_from("0(a0)", et)
                    ty = et
            elif t.text in ("++", "--") and t.kind == "punct":
                # postfix: a0 holds the value; we need the address: re-parse as lvalue is complex, so handle in primary
                raise self.err("postfix ++/-- only on a simple variable, array element or *pointer", t)
            else:
                return ty

    def primary(self):
        t = self.next()
        if t.kind == "num":
            self.emit(f"li a0, {self.number(t)}")
            self.const_at = (len(self.body) - 1, self.number(t))
            return UINT if "u" in t.text.lower() else INT
        if t.kind == "chr":
            self.emit(f"li a0, {self.char_value(t)}")
            self.const_at = (len(self.body) - 1, self.char_value(t))
            return INT
        if t.kind == "str":
            lab = self.string_label(t)
            self.emit(f"la a0, {lab}")
            return Type("ptr", CHAR)
        if t.text == "(":
            ty = self.expression()
            self.expect(")")
            return ty
        if t.kind == "id":
            if self.at("("):
                return self.call(t)
            # a variable, maybe with postfix ++ / --
            if self.peek().text in ("++", "--"):
                op = self.next().text
                v = self.lookup(t.text, t)
                ty = v.type
                if ty.kind == "array":
                    raise self.err("cannot increment an array", t)
                self.var_address(v)
                self.emit("mv a1, a0")
                self.load_from("0(a1)", ty)
                step = ty.elem().size if ty.is_ptr else 1
                self.emit(f"addi a2, a0, {step if op == '++' else -step}")
                self.emit(f"{'sb' if ty.kind == 'char' else 'sw'} a2, 0(a1)")
                return ty
            v = self.lookup(t.text, t)
            if v.type.kind == "array":
                self.var_address(v)
                # postfix [ ] on an array variable, possibly followed by ++/--
                return self.array_postfix(v.type)
            self.var_address(v)
            self.load_from("0(a0)", v.type)
            return v.type
        raise self.err(f"unexpected '{t.text}'", t)

    def array_postfix(self, ty):
        """a0 = the address of an array; handle [i] chains with a possible trailing ++/-- on the element."""
        while self.at("["):
            self.next()
            et = ty.elem()
            self.push()
            self.expression()
            self.expect("]")
            self.scale("a0", et.size)
            self.pop("a1")
            self.emit("add a0, a1, a0")
            ty = et
            if ty.kind != "array":
                if self.peek().text in ("++", "--") and self.peek().kind == "punct":
                    op = self.next().text
                    self.emit("mv a1, a0")
                    self.load_from("0(a1)", ty)
                    step = ty.elem().size if ty.is_ptr else 1
                    self.emit(f"addi a2, a0, {step if op == '++' else -step}")
                    self.emit(f"{'sb' if ty.kind == 'char' else 'sw'} a2, 0(a1)")
                    return ty
                self.load_from("0(a0)", ty)
                return self.postfix_rest(ty)
        return ty

    def postfix_rest(self, ty):
        while self.at("["):
            t = self.next()
            if not ty.is_ptr:
                raise self.err("indexing a non-pointer", t)
            et = ty.elem()
            self.push()
            self.expression()
            self.expect("]")
            self.scale("a0", et.size)
            self.pop("a1")
            self.emit("add a0, a1, a0")
            if et.kind != "array":
                self.load_from("0(a0)", et)
            ty = et
        return ty

    def var_address(self, v):
        if v.where == "global":
            self.emit(f"la a0, {v.name}")
        else:
            self.emit(f"addi a0, s0, {v.offset}")

    def call(self, name_tok):
        self.expect("(")
        args = 0
        if not self.at(")"):
            while True:
                self.assignment()
                self.push()
                args += 1
                if not self.accept(","):
                    break
        self.expect(")")
        if args > 8:
            raise self.err("at most 8 arguments", name_tok)
        f = self.funcs.get(name_tok.text)
        if f is None:
            raise self.err(f"undeclared function {name_tok.text}", name_tok)
        if len(f.params) != args:
            raise self.err(f"{name_tok.text} takes {len(f.params)} arguments, {args} given", name_tok)
        for i in range(args):
            self.emit(f"lw a{i}, {(args - 1 - i) * 4}(sp)")
        if args:
            self.emit(f"addi sp, sp, {args * 4}")
        self.emit(f"call {name_tok.text}")
        return f.ret

    def lvalue_address(self):
        """Parse an lvalue and leave its address in a0; returns its type."""
        t = self.peek()
        if t.text == "*" and t.kind == "punct":
            self.next()
            ty = self.unary()
            if not ty.is_ptr:
                raise self.err("dereferencing a non-pointer", t)
            return ty.elem()
        if t.text == "(" and t.kind == "punct":
            self.next()
            ty = self.lvalue_address()
            self.expect(")")
            return ty
        if t.kind != "id":
            raise self.err("not an lvalue", t)
        self.next()
        v = self.lookup(t.text, t)
        ty = v.type
        self.var_address(v)
        if ty.kind == "array" and not self.at("["):
            return ty
        while self.at("["):
            tb = self.next()
            if not ty.is_ptr:
                raise self.err("indexing a non-pointer", tb)
            if ty.kind == "ptr":
                self.emit("lw a0, 0(a0)")            # the pointer's value is the base
            et = ty.elem()
            self.push()
            self.expression()
            self.expect("]")
            self.scale("a0", et.size)
            self.pop("a1")
            self.emit("add a0, a1, a0")
            ty = et
        return ty


def compile_files(sources, include_dirs, defines):
    pp = Preprocessor([Path(d) for d in include_dirs], defines)
    toks = []
    for s in sources:
        toks += pp.run(s)
    c = Compiler(toks)
    return c.compile()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("sources", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("-I", action="append", default=[], dest="include")
    ap.add_argument("-D", action="append", default=[], dest="define")
    a = ap.parse_args(argv)
    try:
        asm = compile_files(a.sources, a.include, a.define)
    except CError as e:
        print(f"error: {e}")
        return 1
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(asm, encoding="utf-8", newline="\n")
    print(f"OK: {a.out} ({asm.count(chr(10))} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
