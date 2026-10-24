import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The scripts import each other by name (they sit side by side), so the tests do the same.
sys.path.insert(0, str(ROOT / "scripts"))
