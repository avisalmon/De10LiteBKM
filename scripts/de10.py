"""One command per step for the DE10-Lite + shield (Windows, standard library only).

  python scripts/de10.py build   <project_dir>        compile (quartus_sh --flow compile), log in <dir>/logs/build.log
  python scripts/de10.py program <project_dir|.sof>   load the .sof over JTAG (volatile: gone at power-off)
  python scripts/de10.py flash   <project_dir|.pof>   write the design into the MAX 10's flash (stays after power-off)
  python scripts/de10.py pack    <project_dir>        <name>.qar (sources) + <name>.sof next to the example's page
  python scripts/de10.py report  <project_dir>        resources + timing summary of the last build
  python scripts/de10.py jtag                         list the JTAG chain and the debug nodes in the design
  python scripts/de10.py log     [seconds]            show + save the board's JTAG UART log (logs/uart_*.log)
  python scripts/de10.py send    <text> [seconds]     send characters to the board, print what comes back
  python scripts/de10.py screen  [out.png]            capture the screen over JTAG (lib debug_link 'F' command)
  python scripts/de10.py cam     [out.jpg]            take a still from the webcam that sees the kit

Tools: DE10_QUARTUS, then C:\\intelFPGA_lite\\17.1\\quartus, then QUARTUS_ROOTDIR, then C:\\altera_pro\\25.1\\quartus
(Pro can program and talk JTAG but cannot compile for MAX 10). 17.1 has no juart-terminal; nios2-terminal works.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
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


def build(project_dir):
    rev = revision(project_dir)
    os.makedirs(os.path.join(project_dir, "logs"), exist_ok=True)
    log = os.path.join(project_dir, "logs", "build.log")
    t0 = time.time()
    rc = run([tool("quartus_sh", need_compile=True), "--flow", "compile", rev], cwd=project_dir, log=log,
             show=lambda l: l.startswith(("Error", "Critical Warning")) or " was successful" in l or "error(s)" in l)
    print(f"{'OK' if rc == 0 else 'FAIL'}: build {rev} in {time.time() - t0:.0f} s, full log {log}")
    if rc == 0:
        report(project_dir)
    return rc


def report(project_dir):
    rev = revision(project_dir)
    out = os.path.join(project_dir, "output_files")
    fit = os.path.join(out, rev + ".fit.summary")
    if os.path.exists(fit):
        for l in open(fit):
            if re.match(r"(Total (logic elements|registers|pins|memory bits|PLLs)|Embedded Multiplier)", l):
                print("  " + l.strip())
    sta = os.path.join(out, rev + ".sta.summary")
    if os.path.exists(sta):
        worst = {}
        typ = None
        for l in open(sta):
            if l.startswith("Type"):
                typ = l.split(":", 1)[1].strip()
            elif l.startswith("Slack") and typ:
                worst[typ] = float(l.split(":")[1])
        bad = {k: v for k, v in worst.items() if v < 0}
        print("  timing:", "OK (no negative slack)" if not bad else
              "FAIL: " + "; ".join(f"{k}: {v}" for k, v in list(bad.items())[:3]))


def program(target):
    sof = target if target.endswith(".sof") else os.path.join(target, "output_files", revision(target) + ".sof")
    if not os.path.exists(sof):
        sys.exit(f"FAIL: {sof} not found, run build first")
    rc = run([tool("quartus_pgm"), "-m", "jtag", "-o", f"p;{sof}"], show=lambda l: "rror" in l or "successful" in l)
    print("OK: programmed (until power-off)" if rc == 0 else "FAIL: programming, check the cable: scripts/de10.py jtag")
    return rc


def flash(target):
    """Program the internal configuration flash (CFM + UFM) with the .pof and verify it: the design then starts by
    itself at every power-up, until something else is flashed. A .sof loaded later runs only until power-off."""
    pof = target if target.endswith(".pof") else os.path.join(target, "output_files", revision(target) + ".pof")
    if not os.path.exists(pof):
        sys.exit(f"FAIL: {pof} not found (MAX 10 builds make it next to the .sof)")
    rc = run([tool("quartus_pgm"), "-m", "jtag", "-o", f"pv;{pof}"], show=lambda l: "rror" in l or "successful" in l)
    print("OK: flashed and verified; it starts at the next power-up (unplug and plug the USB cable to see)"
          if rc == 0 else "FAIL: flash programming")
    return rc


def pack(project_dir):
    """<rev>.qar (all sources, from Quartus' own archiver) and <rev>.sof copied next to index.html."""
    rev = revision(project_dir)
    sof = os.path.join(project_dir, "output_files", rev + ".sof")
    if not os.path.exists(sof):		# a design with evaluation (OpenCore Plus) IP only makes <rev>_time_limited.sof
        sof = os.path.join(project_dir, "output_files", rev + "_time_limited.sof")
    if not os.path.exists(sof):
        sys.exit(f"FAIL: no .sof in {project_dir}/output_files, run build first")
    qar = os.path.join(project_dir, rev + ".qar")
    rc = run([tool("quartus_sh", need_compile=True), "--archive", rev, "-output", rev + ".qar"], cwd=project_dir,
             show=lambda l: l.lstrip().startswith("Error"))
    shutil.copy2(sof, os.path.join(project_dir, os.path.basename(sof)))
    print(f"{'OK' if rc == 0 and os.path.exists(qar) else 'FAIL'}: {rev}.qar + {os.path.basename(sof)} in {project_dir}")
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
        report(arg or ".")
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
