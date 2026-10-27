"""Write the Quartus project files (.qpf, .qsf, .sdc) for a DE10-Lite design.

  python scripts/new_project.py <project_dir> <top_module> [--lib name ...] [--file extra ...]

* Ports: read from the top module's port list (<project_dir>/src/<top_module>.sv); every port whose name is in
  lib/board/de10_lite_pins.csv gets its pin and I/O standard (buses are expanded: HEX0 -> HEX0[0..7]).
* Sources: every .v/.sv/.qip/.vhd in <project_dir>/src, plus the shared library parts named with --lib:
    display   the LCD + VGA chain (pll25, vga_controller, lcd_ctrl, lcd_cmd ROM, Screens_dispaly)
    gamepad   ADC + game-pad decode (adc IP, analog_input, gamepad)
    debug     JTAG UART + debug link (jtag_uart, debug_link)
    font      font8x8
    sevenseg  seven_segment
    pll       pll_de10 (parameterized altpll, 5 outputs)
    print     jtag_uart + line_printer (text lines to the PC)
    bcd       bin2bcd
    freq      freq_counter
    sdram     sdram_ctrl (the 64 MB SDRAM)
    loader    sdram_ctrl + sdram_loader (PC <-> SDRAM over the USB-Blaster cable: scripts/sdram_load.py)
    burst     sdram_burst_ctrl (the 100 MHz burst SDRAM controller, example 15)
    memtest   sdram_burst_ctrl + sdram_memtest (the register-driven SDRAM memory test)
    jtagregs  jtag_regs (a 32-bit register bus driven from the PC over JTAG)
    dps       pll_de10_dps + pll_phase_step (the PLL with a run-time phase shift on c1)
* Device: 10M50DAF484C7G (the production DE10-Lite part). Every RAM goes into M9K (resource-aware inference off).
Re-running it overwrites the three files; keep project-specific settings in src/extra.qsf (appended if present).
"""
import argparse
import csv
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib", "rtl")
PINS = os.path.join(ROOT, "lib", "board", "de10_lite_pins.csv")
LIB_PARTS = {
    "display": ["pll25.qip", "vga_controller.v", "lcd_ctrl.sv", "lcd_cmd.qip", "Screens_dispaly.sv"],
    "gamepad": ["adc/synthesis/adc.qip", "analog_input.sv", "gamepad.sv"],
    "debug": ["jtag_uart.sv", "debug_link.sv"],
    "font": ["font8x8.sv"],
    "sevenseg": ["seven_segment.sv"],
    "pll": ["pll_de10.v"],
    "print": ["jtag_uart.sv", "line_printer.sv"],
    "bcd": ["bin2bcd.sv"],
    "freq": ["freq_counter.sv"],
    "rom": ["rom_ip.v"],
    "ram": ["ram_sp.sv", "ram_dp.sv", "ram_tdp.sv"],
    "mux": ["tx_mux.sv"],
    "cdc": ["byte_cdc.sv"],
    "debounce": ["debounce.sv"],
    "seg7": ["seg7_char.sv"],
    "spi": ["spi_master.sv"],
    "accel": ["spi_master.sv", "adxl345.sv"],
    "bcdseq": ["bin2bcd_seq.sv"],
    "sdram": ["sdram_ctrl.sv"],
    "loader": ["sdram_ctrl.sv", "sdram_loader.sv"],
    "burst": ["sdram_burst_ctrl.sv"],
    "memtest": ["sdram_burst_ctrl.sv", "sdram_memtest.sv"],
    "jtagregs": ["jtag_regs.sv"],
    "dps": ["pll_de10_dps.v", "pll_phase_step.sv"],
}
KIND = {".v": "VERILOG_FILE", ".sv": "SYSTEMVERILOG_FILE", ".vhd": "VHDL_FILE", ".qip": "QIP_FILE",
        ".sdc": "SDC_FILE", ".mif": "MIF_FILE", ".hex": "HEX_FILE"}


def top_ports(path, top):
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"//.*", "", text)
    m = re.search(r"\bmodule\s+" + re.escape(top) + r"\b\s*(?:#\s*\((?:[^()]|\([^()]*\))*\))?\s*\((.*?)\);",
                  text, re.S)
    if not m:
        sys.exit(f"FAIL: module {top} not found in {path}")
    ports = []
    for decl in re.split(r",", m.group(1)):
        words = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", re.sub(r"\[[^\]]*\]", " ", decl))
        words = [w for w in words if w not in ("input", "output", "inout", "wire", "logic", "reg", "signed")]
        if words:
            ports.append(words[-1])
    return ports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project_dir")
    ap.add_argument("top")
    ap.add_argument("--lib", nargs="*", default=[])
    ap.add_argument("--file", nargs="*", default=[], help="extra source files (relative to the project dir)")
    a = ap.parse_args()
    pdir = os.path.abspath(a.project_dir)
    src = os.path.join(pdir, "src")
    top_file = next((os.path.join(src, a.top + e) for e in (".sv", ".v") if os.path.exists(os.path.join(src, a.top + e))), None)
    if not top_file:
        sys.exit(f"FAIL: {src}/{a.top}.sv not found")

    with open(PINS) as f:
        pins = list(csv.DictReader(f))
    ports = top_ports(top_file, a.top)
    used = [p for p in pins if re.sub(r"\[\d+\]$", "", p["port"]) in ports]
    unknown = [p for p in ports if not any(re.sub(r"\[\d+\]$", "", q["port"]) == p for q in pins)]
    if unknown:
        print("note: ports with no board pin (left unassigned):", ", ".join(unknown))

    files = []
    for part in a.lib:
        if part not in LIB_PARTS:
            sys.exit(f"FAIL: unknown --lib {part}; choose from {', '.join(LIB_PARTS)}")
        for f in LIB_PARTS[part]:
            rel = os.path.relpath(os.path.join(LIB, f), pdir).replace("\\", "/")
            if rel not in files:
                files.append(rel)
    for f in sorted(os.listdir(src)):
        ext = os.path.splitext(f)[1]
        if ext in KIND and ext not in (".sdc", ".mif", ".hex"):
            files.append(f"src/{f}")
    files += a.file

    rev = os.path.basename(pdir.rstrip("/\\"))
    rev = re.sub(r"^\d+_", "", rev)
    lines = [
        f"# {rev}: generated by scripts/new_project.py, re-run it instead of editing (extras go in src/extra.qsf)",
        'set_global_assignment -name FAMILY "MAX 10"',
        "set_global_assignment -name DEVICE 10M50DAF484C7G",
        f"set_global_assignment -name TOP_LEVEL_ENTITY {a.top}",
        "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files",
        "set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0",
        "set_global_assignment -name MAX_CORE_JUNCTION_TEMP 85",
        'set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"',
        "# every array written as a RAM goes into M9K. With this On (the MAX 10 default) Quartus guesses the M9Ks are",
        "# running out (e.g. next to debug_link's 114-block frame buffer) and silently builds small RAMs from",
        "# flip-flops: fft_lab used 19,381 LEs instead of about 8,100. A design that really needs too many M9Ks",
        "# now stops in the fitter with a clear error.",
        "set_global_assignment -name SYNTH_RESOURCE_AWARE_INFERENCE_FOR_BLOCK_RAM OFF",
        f"set_global_assignment -name SDC_FILE {rev}.sdc",
    ]
    lines += [f"set_global_assignment -name {KIND[os.path.splitext(f)[1]]} {f}" for f in files]
    for p in used:
        lines.append(f"set_location_assignment {p['pin']} -to {p['port']}")
        lines.append(f'set_instance_assignment -name IO_STANDARD "{p["io_standard"]}" -to {p["port"]}')
    extra = os.path.join(src, "extra.qsf")
    if os.path.exists(extra):
        lines += ["", "# ---- src/extra.qsf", open(extra).read().rstrip()]
    with open(os.path.join(pdir, rev + ".qsf"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(pdir, rev + ".qpf"), "w", newline="\n") as f:
        f.write(f'PROJECT_REVISION = "{rev}"\n')
    sdc = os.path.join(src, "timing.sdc")
    with open(os.path.join(pdir, rev + ".sdc"), "w", newline="\n") as f:
        if os.path.exists(sdc):
            f.write(open(sdc).read())
        else:
            if "MAX10_CLK1_50" in ports:
                f.write("create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]\n")
            if "MAX10_CLK2_50" in ports:
                f.write("create_clock -name clk50_2 -period 20.000 [get_ports MAX10_CLK2_50]\n")
            if "ADC_CLK_10" in ports:
                f.write("create_clock -name adc_clk10 -period 100.000 [get_ports ADC_CLK_10]\n")
            f.write("derive_pll_clocks\nderive_clock_uncertainty\n")
    print(f"OK: {rev}.qpf/.qsf/.sdc in {pdir}: {len(used)} pins, {len(files)} source files")


if __name__ == "__main__":
    main()
