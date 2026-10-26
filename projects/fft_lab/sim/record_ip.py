"""Record the Altera FFT IP's answers for the lab's test cases, and check the engine with the real IP (ModelSim).

  python projects/fft_lab/sim/record_ip.py

1. ip/generate_fft_ip.py --sim CACHE makes the IP's simulation model (once).
2. ModelSim compiles it in the order of its .spd file list (once, a few minutes), then wave_gen, fft_r2, mag_px,
   mag_rom, lab_engine and sim/tb_lab_ip.sv.
3. tb_lab_ip runs every case below through lab_engine with the real IP and writes sim/ip_vectors.hex: per case
   the IP's latency and exponent, its 256 inputs and its 256 outputs. The model (lab_model.py) and the replay IP
   of the system testbench (fft256_replay.sv) use these recordings; Icarus cannot run the IP itself.
4. Every case is checked against the model: the clocks of both FFTs, the IP's exponent, all 128 bars of each
   FFT, the tallest bars and the 256 scope spans.
CACHE is %LOCALAPPDATA%\\de10lite\\fft_lab_ipsim: outside the cloud-synced folder, and kept between runs.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PROJ))
sys.path.insert(0, HERE)
import lab_model as M  # noqa: E402

MODELSIM = os.environ.get("MODELSIM_BIN", r"C:\intelFPGA_lite\17.1\modelsim_ase\win32aloem")
CACHE = os.path.join(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(), "de10lite", "fft_lab_ipsim")
CASES = ["S0N80W0L0", "S0N84W0L0", "S0N84W1L0", "S1N80W0L0", "S2N80W0L0", "S3N80W0L0", "S4N80W0L0",
         "S0N1000W0L1", "S1N200W1L1", "S2N84W1L1", "S3N333W1L0", "S0N1023W0L0", "S0N0W0L0"]
LIBS = ["altera_mf", "lpm", "sgate", "fiftyfivenm", "altera_lnsim",
        "altera_ver", "altera_mf_ver", "lpm_ver", "sgate_ver", "fiftyfivenm_ver", "altera_lnsim_ver"]
RTL = ["projects/fft_lab/src/wave_gen.sv", "projects/fft_lab/src/mag_rom.sv", "projects/fft_lab/src/mag_px.sv",
       "projects/fft_lab/src/fft_r2.sv", "projects/fft_lab/src/lab_engine.sv", "projects/fft_lab/sim/tb_lab_ip.sv"]


def tool(name):
    return os.path.join(MODELSIM, name + ".exe")


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    return p.returncode, p.stdout + p.stderr


def ip_model():
    """The IP's simulation files in compile order: [(type, path)] from its .spd list (ModelSim's copies)."""
    spd = os.path.join(CACHE, "fft256_sim", "fft256.spd")
    if not os.path.exists(spd):
        print("making the IP's simulation model (once, about a minute)")
        gen = os.path.join(PROJ, "ip", "generate_fft_ip.py")
        if subprocess.call([sys.executable, gen, "--sim", CACHE], stdout=subprocess.DEVNULL):
            sys.exit("FAIL: generate_fft_ip.py --sim")
    files = []
    for f in ET.parse(spd).getroot().iter("file"):
        if f.get("simulator") and "modelsim" not in f.get("simulator").split(","):
            continue
        files.append((f.get("type"), os.path.join(CACHE, "fft256_sim", f.get("path"))))
    return spd, files


def compile_ip(run_dir, spd, files):
    mark = os.path.join(run_dir, "work", "_fft256_compiled.txt")
    stamp = str(os.path.getmtime(spd))
    if os.path.exists(mark) and open(mark).read() == stamp:
        return
    print("compiling the IP's simulation model (once, a few minutes)")
    shutil.rmtree(os.path.join(run_dir, "work"), ignore_errors=True)
    run([tool("vlib"), "work"], run_dir)
    groups = []                                     # consecutive files of one language: one compiler call
    for typ, path in files:
        lang = ("vhdl" if typ.startswith("VHDL") else "sv" if typ.startswith("SYSTEM_VERILOG")
                else "v" if typ.startswith("VERILOG") else None)
        if lang:
            if groups and groups[-1][0] == lang:
                groups[-1][1].append(path)
            else:
                groups.append((lang, [path]))
    for lang, paths in groups:
        cmd = ([tool("vcom"), "-quiet", "-work", "work"] if lang == "vhdl" else
               [tool("vlog"), "-quiet", "-work", "work"] + (["-sv"] if lang == "sv" else []))
        rc, out = run(cmd + paths, run_dir)
        if rc:
            print(out[-4000:])
            sys.exit("FAIL: compiling the IP's simulation model")
    open(mark, "w").write(stamp)


def results(path):
    """lab_ip_results.txt -> [dict(case, dclk, iclk, dpk, dpx, ipk, ipx, iexp, ok, dead, lat, bd, bi, sc)]"""
    out, cur = [], None
    for line in open(path):
        w = line.split()
        if not w:
            continue
        if w[0] == "CASE":
            v = [int(x) for x in w[2:]]
            cur = dict(case=w[1], dclk=v[0], iclk=v[1], dpk=v[2], dpx=v[3], ipk=v[4], ipx=v[5], iexp=v[6],
                       ok=v[7], dead=v[8], lat=v[9])
            out.append(cur)
        elif w[0] in ("BD", "BI"):
            cur[w[0].lower()] = [int(x) for x in w[1:]]
        elif w[0] == "SC":
            cur["sc"] = [tuple(int(y) for y in x.split(":")) for x in w[1:]]
    return out


def check(res, cases):
    """Every case against the model, with one generator through all of them (its noise generator runs on)."""
    gen, bad = M.Gen(), 0
    for r in res:
        st = M.frame_state(r["case"], gen=gen, ip_cases=cases)
        d, ip = st["diy"], st["ip"]
        err = []
        if ip is None:
            err.append("the IP's inputs are not the model's wave")
        else:
            if (r["iclk"], r["iexp"], r["ipk"], r["ipx"]) != (ip["clk"], ip["exp"], ip["pk"], ip["px"][ip["pk"]]):
                err.append(f"IP clk/exp/peak {r['iclk']}/{r['iexp']}/{r['ipk']}:{r['ipx']}, model "
                           f"{ip['clk']}/{ip['exp']}/{ip['pk']}:{ip['px'][ip['pk']]}")
            if r["bi"] != ip["px"]:
                err.append(f"IP bars differ at {[k for k in range(128) if r['bi'][k] != ip['px'][k]][:8]}")
            if r["ok"] != (0 if ip["bad"] else 1) or r["dead"]:
                err.append(f"IP ok={r['ok']} dead={r['dead']}")
        if (r["dclk"], r["dpk"], r["dpx"]) != (d["clk"], d["pk"], d["px"][d["pk"]]):
            err.append(f"our clk/peak {r['dclk']}/{r['dpk']}:{r['dpx']}, model {d['clk']}/{d['pk']}:{d['px'][d['pk']]}")
        if r["bd"] != d["px"]:
            err.append(f"our bars differ at {[k for k in range(128) if r['bd'][k] != d['px'][k]][:8]}")
        if r["sc"] != st["scope"]:
            err.append(f"scope differs at {[n for n in range(256) if r['sc'][n] != st['scope'][n]][:8]}")
        if err:
            bad += 1
            print(f"FAIL: {r['case']}: " + "; ".join(err))
        else:
            print(f"OK: {r['case']}: our FFT {r['dclk']} clocks, IP {r['iclk']} clocks (exp {r['iexp']}), "
                  f"peaks {r['dpk']} / {r['ipk']}: 256 bars and 256 scope spans equal the model")
    return bad


def main():
    if not os.path.exists(tool("vsim")):
        sys.exit(f"FAIL: ModelSim not found in {MODELSIM} (set MODELSIM_BIN)")
    run_dir = os.path.join(CACHE, "run")
    os.makedirs(run_dir, exist_ok=True)
    spd, files = ip_model()
    compile_ip(run_dir, spd, files)
    for typ, path in files:
        if typ == "HEX":
            shutil.copy(path, run_dir)
    for name in ("sine.hex", "hann.hex", "twiddle.hex", "mag_rom.bin"):
        shutil.copy(os.path.join(PROJ, "assets", name), run_dir)
    with open(os.path.join(run_dir, "cases.txt"), "w") as f:
        for c in CASES:
            p = M.parse_case(c)
            f.write(f"{p['shape']} {p['fq']} {p['win']} {p['lin']}\n")
    rc, out = run([tool("vlog"), "-sv", "-quiet", "-work", "work"] + [os.path.join(ROOT, r) for r in RTL], run_dir)
    if rc:
        print(out)
        sys.exit("FAIL: vlog")
    libs = sum((["-L", lib] for lib in LIBS), [])
    t0 = time.time()
    print(f"running {len(CASES)} cases with the real IP in ModelSim (slow: about 10 s per case)")
    rc, out = run([tool("vsim"), "-c", "-quiet"] + libs + ["work.tb_lab_ip", "-do", "run -all; quit -f"], run_dir)
    for line in out.splitlines():
        if re.search(r"PASS|FAIL|CASE|Error|Fatal", line):
            print(line.lstrip("# "))
    if "PASS: recorded" not in out:
        sys.exit(f"FAIL: the recording did not finish (see {run_dir}\\transcript)")
    print(f"ModelSim took {time.time() - t0:.0f} s")
    shutil.copy(os.path.join(run_dir, "ip_vectors.hex"), M.IP_VECTORS)
    cases = M.load_ip_vectors()
    bad = check(results(os.path.join(run_dir, "lab_ip_results.txt")), cases)
    if bad:
        sys.exit(f"FAIL: {bad} of {len(CASES)} cases differ from the model")
    print(f"PASS: sim/ip_vectors.hex: {len(cases)} cases recorded; the engine with the real IP equals the model")


if __name__ == "__main__":
    main()
