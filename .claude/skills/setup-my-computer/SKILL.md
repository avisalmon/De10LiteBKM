---
name: setup-my-computer
description: >
  Get the user's computer ready for this BKM: Python, the project's `env` virtualenv, the tools in requirements.txt,
  and anything else the domain needs. Fixes "command not found", PATH and pip trouble. Windows first; macOS/Linux
  adapted (say when a step is untested).
  TRIGGER: "set up my computer", "install", "python not found", "command not found", "pip error",
  "התקנה", "תתקין", "לא מוצא את פייתון", or the guide's setup phase.
---

# Set up my computer

Goal: `.\env\Scripts\python.exe scripts\doctor.py` prints no FAIL. Do every step yourself; the user only approves
installers (Windows asks "Do you want to allow this app to make changes?": they click **Yes**). One sentence per step on why.

## 1. Python (3.12)

* Check: `python --version` and `py -3 --version`. **Beware** a `python` that opens the Microsoft Store or prints
  nothing: that is Windows' "App execution alias", not Python.
* Install if missing: `winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements`,
  then **open a new terminal** (PATH changes only reach new ones) or call it by full path
  (`$env:LOCALAPPDATA\Programs\Python\Python312\python.exe`).
* No winget? The user installs from python.org, ticking **"Add python.exe to PATH"** on the first screen.

## 2. The env and the tools

```powershell
python -m venv env
.\env\Scripts\python.exe -m pip install --upgrade pip
.\env\Scripts\python.exe -m pip install -r requirements.txt
```

Always `env`, never `.venv`/`venv` (CLAUDE.md rule 2).
The pins in `requirements.txt` need **Python 3.12 to 3.15** (numpy publishes a Windows wheel for each; a Python
outside that range makes pip try to build numpy from source and fail with a C compiler error, gotcha 40). If `python`
on PATH is another version, make the env from the right one: `py -3.12 -m venv env`. The maintainer (running
`pytest`) installs `requirements-dev.txt` instead, which adds pytest; CI uses it too.

## 3. Quartus Prime Lite 17.1, ModelSim, MAX 10 support

1. **Account (human, once):** the user opens https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-17-1-windows , clicks a Download, enters their email, fills the
   short profile and ticks "I'm not a robot". Later sign-ins: email + a one-time code sent by email (they type it).
2. **Download** (Individual Files): `QuartusLiteSetup-17.1.0.590-windows.exe` (sha1 e6185f220de33432f352cfcb3088be7ee0971af8),
   `ModelSimSetup-17.1.0.590-windows.exe` (f0b4520cd766bfffe4373465e1dc7b819d1176f1), `max10-17.1.0.590.qdz`
   (fdf2e0306b5adc6d8e2e2acf65962ae1d8b36d32) into one folder. Edge may leave them as "Unconfirmed *.crdownload":
   check the SHA-1, then rename.
3. **Install** (silent, no admin prompt; ~70 min): in PowerShell, `$env:__COMPAT_LAYER = "RunAsInvoker"`, then
   `QuartusLiteSetup-17.1.0.590-windows.exe --mode unattended --unattendedmodeui none --installdir C:/intelFPGA_lite/17.1
   --accept_eula 1 --disable-components quartus_help,arria_lite,cyclone,cyclone10lp,cyclonev,max,quartus_update,modelsim_ae`.
   If the USB-Blaster driver is missing, the user installs it once from `C:\intelFPGA_lite\17.1\quartus\drivers` (admin).
4. **Check:** `scripts/doctor.py`; `scripts/de10.py jtag` lists `USB-Blaster` and `10M50DA`.
5. **Simulator without ModelSim (optional):** OSS CAD Suite from github.com/YosysHQ/oss-cad-suite-build (Icarus, GTKWave).
Pitfalls: docs/gotchas.md 2-4.

## Check

`.\env\Scripts\python.exe scripts\doctor.py` -> no FAIL. Record "computer ready" in `my_designs/PROGRESS.md`.

## macOS / Linux

Same steps with `python3 -m venv env` and `env/bin/python`. If the maintainer has not tested this platform, say so,
and record what you had to change with `improve-this-guide`.
