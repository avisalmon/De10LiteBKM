#!/usr/bin/env python
"""Check GitHub for updates to this guide and pull them in when it is safe. Run at the start of every session.

    python scripts/check_updates.py           # fetch, and pull in what is safe
    python scripts/check_updates.py --check   # fetch and report only, change nothing

The guide keeps getting better (new skills, fixes, examples), so every session starts here.
The user's own work lives in my_designs/, which git ignores, so an update never touches it.

Safety rules (the AI follows the same ones by hand if Python is not installed yet):
  * Changes to the guide's own files in this folder -> pull nothing; say which files (the chat moves
    the user's edits into my_designs/ or puts them aside with `git stash`, then runs this again).
  * Only fast-forwards or clean merges are applied. A conflict is undone at once (`git merge --abort`),
    so the folder is never left half-updated.
  * No network -> report and carry on; never block the session.
  * Never pushes.

Exit code 0 = up to date or updated; 2 = something needs attention (the message says what).
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE_URL = "https://github.com/avisalmon/De10LiteBKM"


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)


def normalise(url):
    url = url.strip().rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def remotes():
    out = {}
    for line in git("remote", "-v").stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1] == "(fetch)":
            out[parts[0]] = normalise(parts[1])
    return out


def changed_tracked_files():
    return [line[3:] for line in git("status", "--porcelain", "--untracked-files=no").stdout.splitlines()]


def update(remote, apply):
    """(status, report lines). status 0 = fine, 2 = needs attention."""
    fetch = git("fetch", remote, "--quiet")
    if fetch.returncode != 0:
        return 2, [f"Could not reach GitHub ({fetch.stderr.strip()[:120]}). Carrying on offline."]
    ref = f"{remote}/main"
    if git("rev-parse", "--verify", "--quiet", ref).returncode != 0:
        return 2, [f"No branch main on {remote}."]
    counts = git("rev-list", "--left-right", "--count", f"{ref}...HEAD").stdout.split()
    behind, ahead = (int(counts[0]), int(counts[1])) if len(counts) == 2 else (0, 0)
    if behind == 0:
        return 0, ["The guide is up to date."]
    subjects = git("log", "--format=%s", f"HEAD..{ref}").stdout.splitlines()
    lines = [f"{behind} update(s) to the guide on GitHub:"]
    lines += [f"    - {subject}" for subject in subjects[:15]]
    if len(subjects) > 15:
        lines.append(f"    ... and {len(subjects) - 15} more")
    if not apply:
        return 0, lines + ["  (--check: nothing changed)"]
    edited = changed_tracked_files()
    if edited:
        return 2, lines + [
            "  Not pulled: these guide files were changed in this folder: " + ", ".join(edited[:10]),
            "  Keep the user's work in my_designs/ (or `git stash`), then run this again.",
        ]
    before = git("rev-parse", "HEAD").stdout.strip()
    result = git("merge", "--ff-only", ref) if ahead == 0 else git("merge", "--no-edit", ref)
    if result.returncode != 0:
        conflicts = git("diff", "--name-only", "--diff-filter=U").stdout.split()
        git("merge", "--abort")
        detail = ", ".join(conflicts) if conflicts else result.stderr.strip()[:160]
        return 2, lines + [f"  Not pulled: the update clashes with local commits in: {detail}. Nothing was changed."]
    files = git("diff", "--name-only", before, "HEAD").stdout.splitlines()
    lines.append(f"  Pulled in. {len(files)} file(s) changed.")
    if any(f.startswith((".claude/skills/", ".github/skills/", "CLAUDE.md", "AGENTS.md")) for f in files):
        lines.append("  Playbooks changed: re-read CLAUDE.md and the skills you are using before continuing.")
    if any(f.endswith(("requirements.txt", "requirements-dev.txt")) for f in files):
        lines.append("  Tools changed: reinstall them (pip install -r requirements.txt in env).")
    return 0, lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="fetch and report only; change nothing")
    args = parser.parse_args(argv)

    if git("rev-parse", "--is-inside-work-tree").returncode != 0:
        print("Not a git repository: this folder was downloaded, not cloned, so it cannot update itself.")
        print(f"Clone it instead: git clone {GUIDE_URL}.git")
        return 2
    known = remotes()
    remote = next((name for name, url in known.items() if url == normalise(GUIDE_URL)), None)
    if remote is None:
        print(f"No remote points at {GUIDE_URL}, so there is nothing to check.")
        return 0
    status, lines = update(remote, apply=not args.check)
    print("\n".join(lines))
    return status


if __name__ == "__main__":
    sys.exit(main())
