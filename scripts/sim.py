"""Run a unit-level simulation without the FPGA.

  python scripts/sim.py <testbench.sv> [--modelsim] [--gui] [-D NAME ...]

The testbench names its sources in one comment line (paths from the repo root, or from the testbench's folder
when they start with ./ or ../):
    // sim-sources: lib/rtl/freq_counter.sv ../src/my_module.sv
It runs in the testbench's folder, so its output files ($dumpfile, $fopen) land next to it.

Simulators:
  default      Icarus Verilog (OSS CAD Suite, C:\\oss-cad-suite-20261009); waves in the .vcd -> GTKWave (--gui)
  --modelsim   ModelSim-Intel Starter (Quartus 17.1) with the Altera libraries (altpll, altsyncram, lpm,
               MAX 10 atoms), so testbenches that include IP run too; --gui opens the wave window.
A testbench passes when it prints PASS and never FAIL.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OSS = os.environ.get("OSS_CAD_SUITE", r"C:\oss-cad-suite-20261009\oss-cad-suite")
MODELSIM = os.environ.get("MODELSIM_BIN", r"C:\intelFPGA_lite\17.1\modelsim_ase\win32aloem")
ALTERA_LIBS = ["altera_ver", "altera_mf_ver", "lpm_ver", "sgate_ver", "fiftyfivenm_ver", "altera_lnsim_ver"]


def sources(tb):
    here = os.path.dirname(os.path.abspath(tb))
    srcs = []
    for line in open(tb, encoding="utf-8"):
        m = re.match(r"\s*//\s*sim-sources:\s*(.*)", line)
        if m:
            for s in m.group(1).split():
                base = here if s.startswith(".") else ROOT
                srcs.append(os.path.normpath(os.path.join(base, s)))
    return srcs + [os.path.abspath(tb)]


def run(cmd, cwd, env=None):
    print(">", " ".join(os.path.relpath(c, cwd) if os.path.isabs(c) and c.startswith(ROOT) else c for c in cmd))
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    out = p.stdout + p.stderr
    for l in out.splitlines():
        if "sorry: constant selects" in l or l.startswith("# //") or not l.strip():
            continue
        print(l)
    return p.returncode, out


def icarus(tb, defines, gui):
    here = os.path.dirname(os.path.abspath(tb))
    name = os.path.splitext(os.path.basename(tb))[0]
    env = dict(os.environ)
    env["PATH"] = os.path.join(OSS, "bin") + os.pathsep + os.path.join(OSS, "lib") + os.pathsep + env["PATH"]
    rc, _ = run([os.path.join(OSS, "bin", "iverilog.exe"), "-g2012", *["-D" + d for d in defines],
                 "-o", name + ".vvp", *sources(tb)], here, env)
    if rc:
        return rc, ""
    rc, out = run([os.path.join(OSS, "bin", "vvp.exe"), "-n", name + ".vvp"], here, env)
    vcd = os.path.join(here, name + ".vcd")
    if gui and os.path.exists(vcd):
        subprocess.Popen([os.path.join(OSS, "bin", "gtkwave.exe"), vcd], env=env)
    return rc, out


def modelsim(tb, defines, gui):
    here = os.path.dirname(os.path.abspath(tb))
    name = os.path.splitext(os.path.basename(tb))[0]
    exe = lambda n: os.path.join(MODELSIM, n + ".exe")
    if not os.path.exists(exe("vsim")):
        sys.exit(f"FAIL: ModelSim not found in {MODELSIM} (install ModelSim-Intel Starter 17.1 or set MODELSIM_BIN)")
    if not os.path.isdir(os.path.join(here, "work")):
        run([exe("vlib"), "work"], here)
    rc, _ = run([exe("vlog"), "-sv", "-quiet", *["+define+" + d for d in defines], *sources(tb)], here)
    if rc:
        return rc, ""
    libs = [x for l in ALTERA_LIBS for x in ("-L", l)]
    if gui:
        subprocess.Popen([exe("vsim"), *libs, name, "-do", "add wave -r /*; run -all"], cwd=here)
        return 0, "PASS (gui)"
    return run([exe("vsim"), "-c", *libs, name, "-do", "run -all; quit -f"], here)


if __name__ == "__main__":
    args = sys.argv[1:]
    tbs = [a for a in args if a.endswith((".sv", ".v"))]
    defines = [args[i + 1] for i, a in enumerate(args) if a == "-D"]
    if not tbs:
        sys.exit(__doc__)
    rc, out = (modelsim if "--modelsim" in args else icarus)(tbs[0], defines, "--gui" in args)
    ok = rc == 0 and "PASS" in out and "FAIL" not in out
    print("OK: testbench passed" if ok else "FAIL: testbench did not print PASS (or printed FAIL)")
    sys.exit(0 if ok else 1)
