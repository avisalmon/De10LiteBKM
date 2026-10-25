#!/usr/bin/env python
"""Package and install the course's VS Code extension (tools/vscode-course): the lesson slides inside VS Code.

    python scripts/course_extension.py install     build the .vsix and install it with VS Code's own command line
    python scripts/course_extension.py build       only build logs/de10-course.vsix

After installing, VS Code must reload once (Ctrl+Shift+P > "Developer: Reload Window"), then
`python scripts/lesson.py open <N> [slide]` shows the slides in a VS Code tab. Standard library only: a .vsix is a
zip with a manifest, so no Node.js tools are needed.
"""

import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tools" / "vscode-course"
OUT = ROOT / "logs" / "de10-course.vsix"

CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/>
<Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
"""


def manifest(pkg):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="{pkg['name']}" Version="{pkg['version']}" Publisher="{pkg['publisher']}"/>
    <DisplayName>{pkg['displayName']}</DisplayName>
    <Description xml:space="preserve">{pkg['description']}</Description>
    <Categories>Education</Categories>
    <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="{pkg['engines']['vscode']}"/></Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>
"""


def build():
    pkg = json.loads((SRC / "package.json").read_text(encoding="utf-8"))
    OUT.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("extension.vsixmanifest", manifest(pkg))
        for f in ("package.json", "extension.js"):
            z.write(SRC / f, "extension/" + f)
    print(f"OK: built {OUT.relative_to(ROOT)} ({pkg['publisher']}.{pkg['name']} {pkg['version']})")
    return 0


def install():
    build()
    code = shutil.which("code") or shutil.which("code.cmd")
    if not code:
        print("FAIL: VS Code's 'code' command was not found (reinstall VS Code with 'Add to PATH' ticked)")
        return 1
    done = subprocess.run([code, "--install-extension", str(OUT), "--force"], capture_output=True, text=True)
    print((done.stdout + done.stderr).strip())
    if done.returncode:
        print("FAIL: VS Code did not install the extension")
        return 1
    print("OK: installed. Reload VS Code once: Ctrl+Shift+P > Developer: Reload Window")
    return 0


if __name__ == "__main__":
    commands = {"build": build, "install": install}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        print(__doc__)
        sys.exit(2)
    sys.exit(commands[sys.argv[1]]())
