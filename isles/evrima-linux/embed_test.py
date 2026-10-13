#!/usr/bin/env python3
"""embed_test.py - `embed.py --check` looks and never writes (#3574).

Runs on a COPY of this folder in a temp dir; the tree itself is only read.

    python isles/evrima-linux/embed_test.py
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILES = ["embed.py", "install.sh", "egg-evrima-linux.json", "start-evrima.sh", "Game.ini.tmpl", "Engine.ini.tmpl"]
FAILS = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  {detail}" if detail and not ok else ""))
    if not ok:
        FAILS.append(name)


def shas(d):
    return {f: hashlib.sha256((d / f).read_bytes()).hexdigest() for f in FILES}


def run(d, *args):
    p = subprocess.run([sys.executable, str(d / "embed.py"), *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def copy():
    d = Path(tempfile.mkdtemp(prefix="embed-test-"))
    for f in FILES:
        shutil.copyfile(HERE / f, d / f)
    return d


def main() -> int:
    d = copy()
    try:
        was = shas(d)
        rc, out = run(d, "--check")
        check("a tree that agrees: --check exits 0", rc == 0, out)
        check("...and writes nothing", shas(d) == was)

        with open(d / "start-evrima.sh", "ab") as f:
            f.write(b"# a hand edit\n")
        edited = shas(d)
        rc, out = run(d, "--check")
        check("a hand-edited loose file: --check exits 1", rc == 1, f"rc {rc}: {out}")
        check("...names both generated files", "install.sh" in out and "egg-evrima-linux.json" in out, out)
        check("...and writes nothing", shas(d) == edited)

        rc, out = run(d, "--chekc")
        check("an argument it does not know is an error, not a write", rc == 2 and shas(d) == edited, f"rc {rc}")

        rc, out = run(d)
        after = shas(d)
        check("no argument: writes install.sh and the egg JSON", rc == 0
              and after["install.sh"] != edited["install.sh"]
              and after["egg-evrima-linux.json"] != edited["egg-evrima-linux.json"]
              and after["start-evrima.sh"] == edited["start-evrima.sh"], out)
        rc, out = run(d, "--check")
        check("...after which --check exits 0", rc == 0 and shas(d) == after, out)

        (d / "Game.ini.tmpl").write_bytes((d / "Game.ini.tmpl").read_bytes().replace(b"\n", b"\r\n"))
        crlf = shas(d)
        rc, out = run(d, "--check")
        check("a loose file with CR line endings: --check exits 1 and names it", rc == 1 and "Game.ini.tmpl" in out, out)
        check("...and leaves the CR in place", shas(d) == crlf)
        shutil.copyfile(HERE / "Game.ini.tmpl", d / "Game.ini.tmpl")

        with open(d / "install.sh", "ab") as f:
            f.write(b"# a hand edit of the generated file\n")
        hand = shas(d)
        rc, out = run(d, "--check")
        check("a hand-edited install.sh: --check exits 1", rc == 1 and "install.sh" in out, out)
        check("...and writes nothing", shas(d) == hand)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print()
    if FAILS:
        print(f"EMBED TEST FAILED: {len(FAILS)}: " + "; ".join(FAILS))
        return 1
    print("EMBED TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
