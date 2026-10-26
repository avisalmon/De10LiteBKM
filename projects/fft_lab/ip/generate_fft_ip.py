"""Generate the FFT lab's own copy of the FFT II IP, from the command line (no IP Catalog GUI).

  python projects/fft_lab/ip/generate_fft_ip.py             the synthesis files, for Quartus
  python projects/fft_lab/ip/generate_fft_ip.py --sim DIR   the simulation model, for ModelSim

Writes ip/fft256/ (fft256.qip + 107 files). Settings: 256 points, Burst, one engine (Single Output), block floating
point, 16-bit data and twiddles, natural output order, Bi-directional (forward/inverse chosen by the `inverse` port).
Burst allows only Bi-directional and Natural output order: other values make ip-generate print an Error.
--sim writes DIR/fft256_sim/ and DIR/fft256_sim/fft256.spd, the list of its files in compile order
(projects/fft_lab/sim/record_ip.py compiles them). ip-generate needs an absolute --project-directory for this.
The same pattern works for any IP in <quartus>/../ip/altera: find its parameter names in <ip>/<name>_hw.tcl
(add_parameter lines) and pass them as --component-parameter=name=value.
"""
import os
import subprocess
import sys

QUARTUS = os.environ.get("DE10_QUARTUS", r"C:\intelFPGA_lite\17.1\quartus")
HERE = os.path.dirname(os.path.abspath(__file__))

params = {
    "length": "256",
    "data_flow": "Burst",
    "engine_arch": "Single Output",
    "num_engines": "1",
    "direction": "Bi-directional",
    "data_rep": "Block Floating Point",
    "in_width": "16",
    "twid_width": "16",
    "out_order": "Natural",
}

sim = os.path.abspath(sys.argv[sys.argv.index("--sim") + 1]) if "--sim" in sys.argv[1:-1] else None
if sim:
    out = os.path.join(sim, "fft256_sim")
    os.makedirs(out, exist_ok=True)
    where = [f"--project-directory={sim}", f"--output-directory={out}", "--file-set=SIM_VERILOG",
             f"--report-file=spd:{os.path.join(out, 'fft256.spd')}"]
    done = os.path.join(out, "fft256.spd")
else:
    where = ["--project-directory=.", "--output-directory=fft256", "--file-set=QUARTUS_SYNTH",
             "--report-file=qip:fft256/fft256.qip"]
    done = "ip/fft256/fft256.qip"
cmd = [os.path.join(QUARTUS, "sopc_builder", "bin", "ip-generate.exe"), "--remove-qsys-generate-warning"] + where
cmd += ["--component-name=altera_fft_ii", "--output-name=fft256",
        "--system-info=DEVICE_FAMILY=MAX 10", "--system-info=DEVICE=10M50DAF484C7G"]
cmd += [f"--component-parameter={k}={v}" for k, v in params.items()]
env = dict(os.environ, QUARTUS_ROOTDIR=QUARTUS)
rc = subprocess.call(cmd, cwd=HERE, env=env)
print(f"OK: {done}" if rc == 0 else "FAIL: ip-generate (see the Error lines above)")
sys.exit(rc)
