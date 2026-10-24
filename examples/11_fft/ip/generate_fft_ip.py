"""Generate the FFT IP used by example 11, from the command line (no IP Catalog GUI).

  python examples/11_fft/ip/generate_fft_ip.py

Writes ip/fft256/ (fft256.qip + 107 files). Settings: 256 points, Burst, one engine (Single Output), block floating
point, 16-bit data and twiddles, natural output order, Bi-directional (forward/inverse chosen by the `inverse` port).
Burst allows only Bi-directional and Natural output order: other values make ip-generate print an Error.
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

cmd = [os.path.join(QUARTUS, "sopc_builder", "bin", "ip-generate.exe"), "--remove-qsys-generate-warning",
       "--project-directory=.", "--output-directory=fft256", "--file-set=QUARTUS_SYNTH",
       "--report-file=qip:fft256/fft256.qip", "--component-name=altera_fft_ii", "--output-name=fft256",
       "--system-info=DEVICE_FAMILY=MAX 10", "--system-info=DEVICE=10M50DAF484C7G"]
cmd += [f"--component-parameter={k}={v}" for k, v in params.items()]
env = dict(os.environ, QUARTUS_ROOTDIR=QUARTUS)
rc = subprocess.call(cmd, cwd=HERE, env=env)
print("OK: ip/fft256/fft256.qip" if rc == 0 else "FAIL: ip-generate (see the Error lines above)")
sys.exit(rc)
