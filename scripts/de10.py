"""One command per step for the DE10-Lite + shield (Windows, standard library only).

  python scripts/de10.py build   <project_dir>        compile (quartus_sh --flow compile), log in <dir>/logs/build.log
                                                      (a project in a OneDrive folder builds in a local copy: work_dir)
  python scripts/de10.py program <project_dir|.sof>   load the .sof over JTAG (volatile: gone at power-off)
                                                      (evaluation IP: the _time_limited.sof, stays connected; leave it open)
  python scripts/de10.py flash   <project_dir|.pof>   write the design into the MAX 10's flash (stays after power-off)
  python scripts/de10.py pack    <project_dir>        <name>.qar (sources) next to the example's page (no .sof in git)
                                                      (refuses when the last build read files outside it and lib/)
  python scripts/de10.py report  <project_dir> [--html]   the resource list of the last build: area, memory, M9K,
                                                      multipliers, PLLs, clocks + Fmax + slack, memory by block
                                                      (--html: logs/resources.html, the table the project page starts with)
  python scripts/de10.py jtag                         list the JTAG chain and the debug nodes in the design
  python scripts/de10.py log     [seconds]            show + save the board's JTAG UART log (logs/uart_*.log)
  python scripts/de10.py send    <text> [seconds]     send characters to the board, print what comes back
  python scripts/de10.py screen  [out.png]            capture the screen over JTAG (lib debug_link 'F' command)
  python scripts/de10.py cam     [out.jpg]            take a still from the webcam that sees the kit

Tools: DE10_QUARTUS, then C:\\intelFPGA_lite\\17.1\\quartus, then QUARTUS_ROOTDIR, then C:\\altera_pro\\25.1\\quartus
(Pro can program and talk JTAG but cannot compile for MAX 10). 17.1 has no juart-terminal; nios2-terminal works.
"""
import glob
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUARTUS_CANDIDATES = [os.environ.get("DE10_QUARTUS", ""), r"C:\intelFPGA_lite\17.1\quartus",
                      os.environ.get("QUARTUS_ROOTDIR", ""), r"C:\altera_pro\25.1\quartus"]
CAMERA = os.environ.get("DE10_CAMERA", "USB2.0 HD UVC WebCam")
FFMPEG = os.environ.get("FFMPEG", r"C:\ffmpeg\bin\ffmpeg.exe")
LOGS = os.path.join(ROOT, "logs")


def tool(name, need_compile=False):
    for root in QUARTUS_CANDIDATES:
        if root and not (need_compile and "altera_pro" in root):
            exe = os.path.join(root, "bin64", name + ".exe")
            if os.path.exists(exe):
                return exe
    raise FileNotFoundError(f"{name} not found. Install Quartus Prime Lite 17.1 or set DE10_QUARTUS.")


def revision(project_dir):
    qpf = glob.glob(os.path.join(project_dir, "*.qpf"))
    if not qpf:
        sys.exit(f"FAIL: no .qpf in {project_dir} (run scripts/new_project.py first)")
    return os.path.splitext(os.path.basename(qpf[0]))[0]


def run(cmd, cwd=None, log=None, show=lambda l: False):
    print(">", " ".join(cmd))
    with subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors="replace") as p:
        out = open(log, "w") if log else None
        for line in p.stdout:
            if out:
                out.write(line)
            if show(line):
                print(line.rstrip())
        if out:
            out.close()
        return p.wait()


# OneDrive / SharePoint (and any Windows cloud-files sync folder) keeps putting the read-only flag on its folders,
# also on the ones Quartus creates while it builds. Windows ignores that flag on a folder; Quartus does not and stops:
# 'Error (297009) / (132005): Can't open project', 'Error (138001): Cannot write to directory ... incremental_db'.
# Clearing the flag does not help (OneDrive sets it again within seconds), and every build would upload ~30 MB of
# db/ files to the cloud. So a project in such a folder is built in a local copy of the repo (same layout, so every
# ../../lib path still works); program / flash / report read the build from there. DE10_LOCAL_BUILD=1 forces it, =0
# switches it off.
CLOUD_BITS = 0x40000 | 0x80000 | 0x100000 | 0x400000	# RECALL_ON_OPEN, PINNED, UNPINNED, RECALL_ON_DATA_ACCESS
BUILD_DIRS = {"db", "incremental_db", "output_files", "greybox_tmp", "logs"}
MIRROR_SKIP = BUILD_DIRS | {".git", "env", "__pycache__", ".pytest_cache"}
MIRROR = os.path.join(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(), "de10lite",
                      os.path.basename(ROOT) + "-" + hashlib.sha1(os.path.normcase(ROOT).encode()).hexdigest()[:8])


def in_cloud_folder(path):
    if os.name != "nt":
        return False
    path = os.path.normcase(os.path.abspath(path))
    for var in ("OneDrive", "OneDriveCommercial", "OneDriveConsumer"):
        root = os.environ.get(var)
        if root and (path + os.sep).startswith(os.path.normcase(os.path.abspath(root)) + os.sep):
            return True
    while True:
        try:
            if getattr(os.stat(path), "st_file_attributes", 0) & CLOUD_BITS:
                return True
        except OSError:
            pass
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent


def work_dir(project_dir):
    """Where Quartus builds the project: the project folder, or the same path in the local copy (see above)."""
    rel = os.path.relpath(os.path.abspath(project_dir), ROOT)
    force = os.environ.get("DE10_LOCAL_BUILD", "")
    if rel.startswith("..") or force == "0" or (force != "1" and not in_cloud_folder(project_dir)):
        return project_dir
    return os.path.join(MIRROR, rel)


def mirror(src=ROOT, dst=MIRROR):
    """Make dst a copy of src: copy what is new or changed, delete what src no longer has. The build folders
    (db, output_files...) in dst are kept, so a later program / report still finds the last build."""
    copied = 0
    for top, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in MIRROR_SKIP]
        files = [f for f in files if f not in MIRROR_SKIP]
        out = os.path.join(dst, os.path.relpath(top, src))
        os.makedirs(out, exist_ok=True)
        for name in set(os.listdir(out)) - set(dirs) - set(files) - MIRROR_SKIP:
            gone = os.path.join(out, name)
            shutil.rmtree(gone) if os.path.isdir(gone) else os.remove(gone)
        for f in files:
            s, d = os.stat(os.path.join(top, f)), os.path.join(out, f)
            old = os.stat(d) if os.path.exists(d) else None
            if not old or old.st_size != s.st_size or int(old.st_mtime) != int(s.st_mtime):
                shutil.copy2(os.path.join(top, f), d)
                copied += 1
    return copied


def prepare(project_dir):
    """The folder to run Quartus in; refreshes the local copy first when the project is in a cloud folder."""
    work = work_dir(project_dir)
    if work != project_dir:
        n = mirror()
        print(f"note: {project_dir} is in a OneDrive / SharePoint folder, where Quartus cannot build.\n"
              f"      building in a local copy instead ({n} files updated): {work}")
    return work


def build(project_dir):
    rev = revision(project_dir)
    work = prepare(project_dir)
    os.makedirs(os.path.join(project_dir, "logs"), exist_ok=True)
    log = os.path.join(project_dir, "logs", "build.log")
    t0 = time.time()
    rc = run([tool("quartus_sh", need_compile=True), "--flow", "compile", rev], cwd=work, log=log,
             show=lambda l: l.startswith(("Error", "Critical Warning")) or " was successful" in l or "error(s)" in l)
    print(f"{'OK' if rc == 0 else 'FAIL'}: build {rev} in {time.time() - t0:.0f} s, full log {log}")
    if rc and work == project_dir and re.search(r"\((297009|132005|138001)\)", open(log, errors="replace").read()):
        print("hint: Quartus found a read-only folder. Is this folder synced by OneDrive? "
              "Run with DE10_LOCAL_BUILD=1 to build in a local copy.")
    if rc == 0:
        report(project_dir)
        standalone(project_dir, "warning")
    return rc


def rpt_table(path, title):
    """The rows (dicts by column) of the Quartus report table whose title line is '; <title> ;'."""
    if not os.path.exists(path):
        return []
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    cells = lambda l: [c.strip() for c in l.strip()[1:-1].split(";")]
    for n, line in enumerate(lines):
        if line.startswith(";") and line.strip("; ") == title:
            head, rows = None, []
            for l in lines[n + 1:]:
                if l.startswith(";"):
                    if head is None:
                        head = cells(l)
                    else:
                        rows.append(dict(zip(head, cells(l))))
                elif not l.startswith("+") or rows:
                    break
            return rows
    return []


def entity_tree(fit):
    """The fitter's 'Resource Utilization by Entity' table, one dict per node in file order (depth 0 is the top):
    path (instance names below the top), entity, lcs (total) and own (in the node itself), regs, bits, m9k, dsp."""
    if not os.path.exists(fit):
        return []
    lines = open(fit, encoding="utf-8", errors="replace").read().splitlines()
    start = next((n for n, l in enumerate(lines) if l.startswith(";") and l.strip("; ") == "Fitter Resource Utilization by Entity"), None)
    if start is None:
        return []
    head, rows, stack = None, [], []
    first = lambda s: int(re.match(r"\s*(\d+)", s).group(1)) if re.match(r"\s*\d", s or "") else 0
    for l in lines[start + 1:]:
        if not l.startswith(";"):
            if l.startswith("+") and not rows:
                continue
            break
        raw = l[1:].split(";")
        if head is None:
            head = [c.strip() for c in raw]
            continue
        cell = dict(zip(head, raw))
        node = raw[0]
        depth = (len(node) - len(node.lstrip()) - 1) // 3
        entity, _, inst = node.strip().strip("|").partition(":")
        del stack[depth:]
        stack.append(inst or entity)
        own = re.search(r"\((\d+)\)", cell.get("Logic Cells", ""))
        rows.append({"depth": depth, "path": "/".join(stack[1:]) or entity, "entity": entity,
                     "lcs": first(cell.get("Logic Cells")), "own": int(own.group(1)) if own else 0,
                     "regs": first(cell.get("Dedicated Logic Registers")), "bits": first(cell.get("Memory Bits")),
                     "m9k": first(cell.get("M9Ks")), "dsp": first(cell.get("DSP Elements"))})
    return rows


def area_blocks(tree, share=0.25):
    """What uses the area: the top's children, opening every wrapper (a node whose cells are mostly in its children)
    that holds more than `share` of the design, so one big module shows its parts. Biggest first."""
    if not tree:
        return []
    kids, stack = {i: [] for i in range(len(tree))}, []
    for i, r in enumerate(tree):
        del stack[r["depth"]:]
        if stack:
            kids[stack[-1]].append(i)
        stack.append(i)
    total, out, todo = tree[0]["lcs"] or 1, [], list(kids[0])
    while todo:
        i = todo.pop(0)
        r = tree[i]
        if kids[i] and r["lcs"] > share * total and r["own"] < r["lcs"] / 2:
            todo[0:0] = kids[i]
        elif r["lcs"] or r["bits"] or r["dsp"]:
            out.append(r)
    return sorted(out, key=lambda r: (-r["lcs"], -r["bits"]))


def _used(text):
    """'9,504 / 49,760 ( 19 % )' -> (9504, 49760, 19)"""
    m = re.match(r"\s*([\d,]+)\s*(?:/\s*([\d,]+)\s*\(\s*(<?\s*\d+)\s*%\s*\))?", text or "")
    if not m:
        return None
    num = lambda s: int(s.replace(",", "")) if s else None
    return num(m.group(1)), num(m.group(2)), (m.group(3) or "").replace(" ", "") or None


def _clock_label(name):
    """'pll|altpll_component|auto_generated|pll1|clk[0]' -> 'pll clk[0]'; '..|adc_pll|auto_generated|..' -> 'pad/adc_pll clk[0]'"""
    parts = name.split("|")
    if len(parts) == 1:
        return name
    owner = parts[parts.index("auto_generated") - 1] if "auto_generated" in parts else parts[0]
    inst = parts[0] if owner in ("altpll_component", parts[0]) else f"{parts[0]}/{owner}"
    return f"{inst} {parts[-1]}"


def resources(project_dir):
    """The numbers of the last build: area, memory, multipliers, PLLs, clocks with Fmax and slack, memory by block."""
    rev = revision(project_dir)
    out = os.path.join(work_dir(project_dir), "output_files")
    fit, sta, flow = (os.path.join(out, f"{rev}.{x}.rpt") for x in ("fit", "sta", "flow"))
    if not os.path.exists(fit):
        return None
    use = {r.get("Resource", ""): r.get("Usage", "") for r in rpt_table(fit, "Fitter Resource Usage Summary")}
    info = {}
    for l in open(os.path.join(out, rev + ".fit.summary"), encoding="utf-8", errors="replace"):
        if " : " in l:
            k, v = l.split(" : ", 1)
            info[k.strip()] = v.strip()
    pick = lambda *keys: next((use[k] for k in keys if k in use), None) or next((info[k] for k in keys if k in info), None)
    r = {"rev": rev, "device": info.get("Device", "?"), "family": info.get("Family", "?"),
         "version": info.get("Quartus Prime Version", "?"), "date": info.get("Fitter Status", "").split(" - ")[-1],
         "les": _used(pick("Total logic elements")), "regs": _used(pick("Total registers", "Dedicated logic registers")),
         "bits": _used(pick("Total block memory bits", "Total memory bits")), "m9k": _used(pick("M9Ks")),
         "mult": _used(pick("Embedded Multiplier 9-bit elements")), "plls": _used(pick("PLLs", "Total PLLs")),
         "pins": _used(pick("I/O pins", "Total pins")), "adc": _used(pick("ADC blocks")),
         "ufm": _used(pick("UFM blocks")), "jtag": _used(pick("JTAGs"))}
    total = [x for x in rpt_table(flow, "Flow Elapsed Time") if x.get("Module Name", "").startswith("Total")]
    r["build_time"] = total[0].get("Elapsed Time") if total else None
    fmax = {x["Clock Name"]: x.get("Restricted Fmax", x.get("Fmax")) for x in rpt_table(sta, "Slow 1200mV 85C Model Fmax Summary")}
    slack = {x["Clock"]: x.get("Slack") for x in rpt_table(sta, "Slow 1200mV 85C Model Setup Summary")}
    r["clocks"] = [{"name": c["Clock Name"], "label": _clock_label(c["Clock Name"]), "freq": c.get("Frequency", ""),
                    "fmax": fmax.get(c["Clock Name"]), "slack": slack.get(c["Clock Name"])}
                   for c in rpt_table(sta, "Clocks")]
    worst = [float(x["Slack"]) for t in ("Setup", "Hold", "Recovery", "Removal") for corner in
             ("Slow 1200mV 85C", "Slow 1200mV 0C", "Fast 1200mV 0C")
             for x in rpt_table(sta, f"{corner} Model {t} Summary") if re.match(r"-?\d", x.get("Slack", ""))]
    r["worst_slack"] = min(worst) if worst else None
    groups = {}
    for ram in rpt_table(fit, "Fitter RAM Summary"):
        names = []
        for comp in ram.get("Name", "").split("|"):
            if comp.split(":")[0] in ("altsyncram", "altera_syncram", "scfifo", "dcfifo", "altshift_taps"):
                names.append(re.sub(r"_rtl_\d+$", "", comp.split(":")[1]) if not names else "")
                break
            names.append(comp.split(":")[1] if ":" in comp else comp)
        key = "/".join(n for n in names[:2] if n)
        g = groups.setdefault(key, {"block": key, "bits": 0, "m9k": 0})
        g["bits"] += int(ram.get("Size", "0") or 0)
        g["m9k"] += int(ram.get("M9Ks", "0") or 0) if (ram.get("M9Ks", "") or "").isdigit() else 0
    r["memories"] = sorted(groups.values(), key=lambda g: -g["bits"])
    r["blocks"] = area_blocks(entity_tree(fit))
    return r


def top_users(blocks, key, n=5, times="x"):
    """'uart (jtag_uart) 4,820; game (pac_logic) 1,512; seven_segment x6 68': the blocks that use most of `key`."""
    groups = {}
    for b in blocks:
        if b[key]:
            g = groups.setdefault(b["entity"], {"label": f"{b['path']} ({b['entity']})", "entity": b["entity"], "n": 0, "v": 0})
            g["n"] += 1
            g["v"] += b[key]
    top = sorted(groups.values(), key=lambda g: -g["v"])[:n]
    return "; ".join((g["label"] if g["n"] == 1 else f"{g['entity']} {times}{g['n']}") + f" {g['v']:,}" for g in top)


def _fmt(u, unit=""):
    if not u:
        return "-"
    n, total, pct = u
    return f"{n:,}{unit}" + (f" / {total:,} ({pct} %)" if total else "")


def resources_html(r, project_dir=None):
    """The 'Resources' table the project pages start with (make-project skill). Paste it, then add the notes."""
    made_by = (project_dir or f"projects/{r['rev']}").replace(os.sep, "/").rstrip("/")
    plls = "; ".join(f"{c['label']} {c['freq']}" for c in r["clocks"] if "clk[" in c["name"])
    row = lambda name, u, note="": (f"<tr><td>{name}</td><td>{u[0]:,}</td><td>{u[1]:,} ({u[2]} %)</td><td>{note}</td></tr>"
                                    if u and u[1] else f"<tr><td>{name}</td><td>{u[0] if u else 0:,}</td><td>-</td><td>{note}</td></tr>")
    rows = [row("Logic elements (area)", r["les"], top_users(r["blocks"], "lcs", 5, "&times;")),
            row("Registers", r["regs"], top_users(r["blocks"], "regs", 3, "&times;")),
            row("Memory bits", r["bits"], top_users(r["blocks"], "bits", 4, "&times;")),
            row("M9K memory blocks (9 kbit each)", r["m9k"], top_users(r["blocks"], "m9k", 4, "&times;")),
            row("Multipliers (9-bit elements)", r["mult"], top_users(r["blocks"], "dsp", 4, "&times;")), row("PLLs", r["plls"], plls),
            row("Pins", r["pins"]), row("ADC blocks", r["adc"]), row("JTAG hub (USB link)", r["jtag"])]
    clocks = [f"<tr><td>{c['label']}</td><td>{c['freq']}</td><td>{c['fmax'] or '-'}</td>"
              f"<td>{c['slack'] + ' ns' if c['slack'] else '-'}</td></tr>" for c in r["clocks"]]
    worst = r["worst_slack"]
    return "\n".join([
        f'<h2 id="resources">Resources</h2>',
        f'<p class="note">The last build: {r["family"]} {r["device"]}, Quartus Prime {r["version"].split(" Build")[0]} Lite, '
        f'{r["build_time"] or "?"} to build. Made by <code>python scripts/de10.py report {made_by} --html</code>.</p>',
        '<div class="tablewrap"><table class="res">',
        "<tr><th>Resource</th><th>Used</th><th>Of the device</th><th>What uses it</th></tr>", *rows, "</table></div>",
        '<div class="tablewrap"><table class="res">',
        "<tr><th>Clock</th><th>Runs at</th><th>Fmax (slow model, 85 &deg;C)</th><th>Setup slack</th></tr>", *clocks,
        "</table></div>",
        f'<p class="note">Timing: {"met, worst slack " + f"{worst:+.3f} ns" if worst is not None and worst >= 0 else "NOT MET, worst slack " + str(worst) + " ns"}'
        " (all corners, setup, hold, recovery, removal).</p>"])


def report(project_dir, html=False):
    r = resources(project_dir)
    if not r:
        print(f"no build in {os.path.join(work_dir(project_dir), 'output_files')}: run build first")
        return 1
    print(f"  {r['rev']}: {r['family']} {r['device']}, built {r['date']}, build time {r['build_time']}")
    for name, key in (("Logic elements (area)", "les"), ("Registers", "regs"), ("Memory bits", "bits"),
                      ("M9K blocks", "m9k"), ("Multipliers (9-bit)", "mult"), ("PLLs", "plls"), ("Pins", "pins"),
                      ("ADC blocks", "adc"), ("JTAG", "jtag")):
        print(f"  {name:22s} {_fmt(r[key])}")
    print(f"  {'clock':34s} {'runs at':>10s} {'Fmax 85C':>11s} {'setup slack':>12s}")
    for c in r["clocks"]:
        print(f"  {c['label'][:34]:34s} {c['freq']:>10s} {c['fmax'] or '-':>11s} {c['slack'] or '-':>12s}")
    print("  memory by block: " + "; ".join(f"{g['block']} {g['bits']:,} bits ({g['m9k']} M9K)" for g in r["memories"]))
    print(f"  {'area by block':34s} {'LEs':>7s} {'regs':>6s} {'mem bits':>9s} {'M9K':>4s} {'mult':>4s}")
    for b in r["blocks"]:
        print(f"  {(b['path'] + ' (' + b['entity'] + ')')[:34]:34s} {b['lcs']:>7,} {b['regs']:>6,} {b['bits']:>9,} {b['m9k']:>4} {b['dsp']:>4}")
    w = r["worst_slack"]
    print("  timing:", "OK (no negative slack, worst %+.3f ns)" % w if w is not None and w >= 0 else f"FAIL: worst slack {w}")
    if html:
        path = os.path.join(project_dir, "logs", "resources.html")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(resources_html(r, project_dir) + "\n")
        print(f"  HTML for the page's Resources section: {path}")
    return 0 if w is None or w >= 0 else 1


def built(project_dir, ext):
    """output_files/<rev><ext> of the last build (in the local copy for a project in a OneDrive folder)."""
    return os.path.join(work_dir(project_dir), "output_files", revision(project_dir) + ext)


def program(target):
    sof = target if target.endswith(".sof") else built(target, ".sof")
    if not os.path.exists(sof) and not target.endswith(".sof"):	# evaluation (OpenCore Plus) IP: time-limited only
        sof = sof[:-4] + "_time_limited.sof"
    if not os.path.exists(sof):
        sys.exit(f"FAIL: {sof} not found, run build first")
    if sof.endswith("_time_limited.sof"):
        print("NOTE: the design holds evaluation IP (a time-limited .sof). quartus_pgm stays connected (tethered) so the"
              " IP keeps running, and this command does not return: leave it open while you use the board. Without the"
              " connection the IP stops when its evaluation time runs out (one hour, Intel's IP guides say). The USB"
              " commands (log, send, screen) work meanwhile.")
    rc = run([tool("quartus_pgm"), "-m", "jtag", "-o", f"p;{sof}"],
             show=lambda l: "rror" in l or "successful" in l or "succeeded" in l or "valuation" in l or "ethered" in l)
    print("OK: programmed (until power-off)" if rc == 0 else "FAIL: programming, check the cable: scripts/de10.py jtag")
    return rc


def flash(target):
    """Program the internal configuration flash (CFM + UFM) with the .pof and verify it: the design then starts by
    itself at every power-up, until something else is flashed. A .sof loaded later runs only until power-off."""
    pof = target if target.endswith(".pof") else built(target, ".pof")
    if not os.path.exists(pof) and os.path.exists(pof[:-4] + "_time_limited.sof"):
        sys.exit("FAIL: no .pof to flash: the design holds evaluation (OpenCore Plus) IP, so Quartus makes only a"
                 " time-limited .sof. It runs while the programmer stays connected (de10.py program) and cannot go into"
                 " the flash. To flash the design, license the IP or build a version without it.")
    if not os.path.exists(pof):
        sys.exit(f"FAIL: {pof} not found (MAX 10 builds make it next to the .sof)")
    rc = run([tool("quartus_pgm"), "-m", "jtag", "-o", f"pv;{pof}"], show=lambda l: "rror" in l or "successful" in l)
    print("OK: flashed and verified; it starts at the next power-up (unplug and plug the USB cable to see)"
          if rc == 0 else "FAIL: flash programming")
    return rc


def outside_files(project_dir):
    """The repo files the last build read from outside the project folder and lib/ (Quartus' list in the .map.rpt).
    A .qar holds every file the last build read, also ones an older .qsf listed that db/ still remembers."""
    work = work_dir(project_dir)
    base = MIRROR if work != project_dir else ROOT
    norm = lambda p: os.path.normcase(os.path.abspath(p)) + os.sep
    found = []
    for r in rpt_table(os.path.join(work, "output_files", revision(project_dir) + ".map.rpt"),
                       "Analysis & Synthesis Source Files Read"):
        p = r.get("File Name with Absolute Path")
        if p and norm(p).startswith(norm(base)) and not norm(p).startswith((norm(work), norm(os.path.join(base, "lib")))):
            found.append(r.get("File Name with User-Entered Path") or p)
    return found


def standalone(project_dir, level):
    """True when the last build read only the project's own files and lib/; else says what to do and returns False."""
    found = outside_files(project_dir)
    if found:
        print(f"{level}: the last build read {len(found)} file(s) from outside the project and lib/, e.g. {found[0]}\n"
              "      A project stands on its own: copy what it reuses into its folder. If its .qsf no longer lists\n"
              f"      them, Quartus kept them from an older build: delete db and incremental_db in\n"
              f"      {work_dir(project_dir)} and build again.")
    return not found


def pack(project_dir):
    """<rev>.qar (all sources, from Quartus' own archiver) next to index.html. The repo keeps no .sof (too big):
    a user builds it in a few minutes. Refuses when the last build read files from outside the project and lib/."""
    rev = revision(project_dir)
    if not standalone(project_dir, "FAIL"):
        print(f"      {rev}.qar not made: it would hold those files.")
        return 1
    work = prepare(project_dir)
    qar = os.path.join(project_dir, rev + ".qar")
    rc = run([tool("quartus_sh", need_compile=True), "--archive", rev, "-output", rev + ".qar"], cwd=work,
             show=lambda l: l.lstrip().startswith("Error"))
    if work != project_dir and rc == 0:
        shutil.copy2(os.path.join(work, rev + ".qar"), qar)
    print(f"{'OK' if rc == 0 and os.path.exists(qar) else 'FAIL'}: {rev}.qar in {project_dir}")
    return rc


def uart_session(send_text, seconds, out_path=None, stop_marker=None, echo=True):
    """Run the JTAG UART terminal, optionally send text, collect output for `seconds` or until stop_marker."""
    try:
        term = [tool("juart-terminal"), "-q"]
    except FileNotFoundError:
        term = [tool("nios2-terminal"), "-q", "--instance", "0"]
    p = subprocess.Popen(term, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    chunks = []

    def reader():
        while True:
            b = p.stdout.read1(65536)
            if not b:
                break
            chunks.append(b)
            if echo and out_path is None:
                sys.stdout.write(b.decode("ascii", "replace"))
                sys.stdout.flush()

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    time.sleep(1.0)
    if send_text:
        p.stdin.write(send_text.encode("ascii"))
        p.stdin.flush()
    t_end = time.time() + seconds
    while time.time() < t_end:
        if stop_marker and stop_marker in b"".join(chunks[-3:]):
            break
        time.sleep(0.1)
    p.kill()
    th.join(timeout=2)
    data = b"".join(chunks)
    if out_path:
        with open(out_path, "wb") as f:
            f.write(data)
    return data


def log(seconds):
    os.makedirs(LOGS, exist_ok=True)
    path = os.path.join(LOGS, time.strftime("uart_%Y%m%d_%H%M%S.log"))
    data = uart_session("", seconds)
    with open(path, "wb") as f:
        f.write(data)
    print(f"\nsaved {len(data)} bytes to {path}")


def screen(out_png):
    os.makedirs(os.path.dirname(os.path.abspath(out_png)), exist_ok=True)
    dump = os.path.splitext(out_png)[0] + ".txt"
    t0 = time.time()
    data = uart_session("F", 120, out_path=dump, stop_marker=b"END")
    print(f"received {len(data)} bytes in {time.time() - t0:.1f} s")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import frame_to_png
    with open(dump, "r", encoding="ascii", errors="replace") as f:
        w, h, pix = frame_to_png.parse(f.read())
    frame_to_png.write_png(out_png, w, h, pix, 2 if w >= 320 else 4)
    print(f"OK: {out_png} ({w}x{h})")


def cam(out_jpg):
    os.makedirs(os.path.dirname(os.path.abspath(out_jpg)), exist_ok=True)
    rc = subprocess.call([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "dshow",
                          "-video_size", "640x480", "-i", f"video={CAMERA}", "-ss", "1.5",
                          "-frames:v", "1", out_jpg])
    print(f"OK: {out_jpg}" if rc == 0 else "FAIL: camera capture (is another program using it?)")


if __name__ == "__main__":
    a = sys.argv[1:] or ["-h"]
    cmd, arg = a[0], (a[1] if len(a) > 1 else None)
    if cmd == "build":
        sys.exit(build(arg or "."))
    elif cmd == "program":
        sys.exit(program(arg or "."))
    elif cmd == "flash":
        sys.exit(flash(arg or "."))
    elif cmd == "pack":
        sys.exit(pack(arg or "."))
    elif cmd == "report":
        sys.exit(report(arg or ".", html="--html" in a))
    elif cmd == "jtag":
        subprocess.call([tool("jtagconfig"), "-n"])
    elif cmd == "log":
        log(float(arg) if arg else 10)
    elif cmd == "send":
        uart_session(arg, float(a[2]) if len(a) > 2 else 3)
    elif cmd == "screen":
        screen(arg or os.path.join(LOGS, "screen.png"))
    elif cmd == "cam":
        cam(arg or os.path.join(LOGS, "cam.jpg"))
    else:
        print(__doc__)
