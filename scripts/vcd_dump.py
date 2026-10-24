"""Print a VCD (Signal Tap export or simulation) as a table: one row per change, buses joined into hex.

  python scripts/vcd_dump.py <file.vcd> [--all] [--max N]

Single bits named like a3[0] .. a3[11] are joined into one bus "a3". Rows are printed only when something
changes (--all prints every time point). Signal Tap exports two time points per sample clock.
"""
import re
import sys


def load(path):
    ids, order, rows, cur, t = {}, [], [], {}, None
    for line in open(path):
        line = line.strip()
        # escaped names (\ph.P_IDLE, one-hot states) end with their own space: allow any whitespace
        m = re.match(r"\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)(?:\s+\[\d+(?::\d+)?\])?\s+\$end", line)
        if m:
            name = m.group(3).lstrip("\\")
            ids[m.group(2)] = name
            if name not in order:
                order.append(name)
            continue
        if line.startswith("#"):
            if t is not None:
                rows.append((t, dict(cur)))
            t = int(line[1:])
        elif line[:1] in "01xXzZ" and line[1:] in ids:
            cur[ids[line[1:]]] = line[0]
        elif re.match(r"[bB][01xXzZ]+ \S+$", line) and line.split()[1] in ids:
            v, i = line[1:].split()
            cur[ids[i]] = v
    if t is not None:
        rows.append((t, dict(cur)))
    return order, rows


def columns(order):
    cols = []
    for name in order:
        m = re.match(r"(.*)\[(\d+)\]$", name)
        base = m.group(1) if m else name
        if base not in [c[0] for c in cols]:
            cols.append((base, []))
        if m:
            dict(cols)[base].append((int(m.group(2)), name))
    return cols


def value(row, base, bits):
    if not bits:
        return row.get(base, "x")
    s = "".join(row.get(n, "x") for _, n in sorted(bits, reverse=True))
    return f"{int(s, 2):0{(len(s) + 3) // 4}X}" if set(s) <= {"0", "1"} else s


if __name__ == "__main__":
    path = sys.argv[1]
    show_all = "--all" in sys.argv
    limit = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 60
    order, rows = load(path)
    cols = columns(order)
    # drop the sample clock: a column that changes at (almost) every time point carries no information here
    def flips(b, bits):
        vals = [value(r, b, bits) for _, r in rows]
        return sum(1 for a, c in zip(vals, vals[1:]) if a != c)
    if len(rows) > 10:
        cols = [c for c in cols if flips(*c) < 0.9 * (len(rows) - 1)]
    print("time".rjust(8), " ".join(c[0].split("|")[-1][:14].rjust(14) for c in cols))
    last, n = None, 0
    for t, row in rows:
        vals = [value(row, b, bits) for b, bits in cols]
        if show_all or vals != last:
            print(str(t).rjust(8), " ".join(v.rjust(14) for v in vals))
            n += 1
            if n >= limit:
                print("... (--max N for more)")
                break
        last = vals
