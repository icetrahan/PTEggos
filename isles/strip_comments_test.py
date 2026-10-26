#!/usr/bin/env python3
"""strip_comments_test.py - the wrapper copies the eggs ship carry no comments,
and stripping them changed nothing the interpreter runs.

For each wrapper:
  1. the ship copy parses (PowerShell's parser / `bash -n`);
  2. it is the same program: PowerShell's tokens minus comments are identical,
     and bash's `declare -f` prints the identical body;
  3. the copy embedded in the egg holds no comment line and no bug number.
Then each check is shown to fail on a planted bad case, so a pass means
something.

    python isles/strip_comments_test.py        (exit 0 = pass, 1 = fail)

Needs bash and PowerShell (`pwsh`, or Windows PowerShell) on PATH; a missing
one is a FAIL, never a skip.
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from strip_comments import ship_copy  # noqa: E402

FAILS = []
BUG_NUMBER = re.compile(r"#[0-9]{3,}")
# One string literal changed: the equivalence checks must call it a different program.
MUTATE = {".ps1": (b"Write-Host \"(", b"Write-Host \"X("), ".sh": (b"log \"", b"log \"X")}


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILS.append(name)
    return ok


def egg40_blob():
    egg = json.loads((HERE / "evrima-windows-feathers" / "egg-evrima-windows-feathers.json").read_text(encoding="utf-8"))
    blobs = re.findall(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", egg["scripts"]["installation"]["script"])
    return base64.b64decode(blobs[2]) if len(blobs) == 3 else b""


def egg41_blob():
    egg = json.loads((HERE / "legacy-windows-feathers" / "egg-isle-legacy.json").read_text(encoding="utf-8"))
    runs = re.findall(r"[A-Za-z0-9+/]{400,}={0,2}", egg["scripts"]["installation"]["script"])
    return base64.b64decode(runs[0]) if len(runs) == 1 else b""


def egg42_blob():
    egg = json.loads((HERE / "evrima-linux" / "egg-evrima-linux.json").read_text(encoding="utf-8"))
    m = re.search(r"<<'B64_START_EVRIMA'\n(.*?)\nB64_START_EVRIMA\n", egg["scripts"]["installation"]["script"], re.DOTALL)
    return base64.b64decode(m.group(1)) if m else b""


WRAPPERS = [
    ("egg 40", HERE / "evrima-windows-feathers" / "start-evrima.ps1", egg40_blob),
    ("egg 41", HERE / "legacy-windows-feathers" / "start-legacy.ps1", egg41_blob),
    ("egg 42", HERE / "evrima-linux" / "start-evrima.sh", egg42_blob),
]


class Tools:
    def __init__(self, tmp):
        self.tmp = Path(tmp)
        self.bash = shutil.which("bash")
        self.ps = shutil.which("pwsh") or shutil.which("powershell")
        self.n = 0

    def _file(self, data, suffix):
        self.n += 1
        p = self.tmp / f"t{self.n}{suffix}"
        p.write_bytes(data)
        return p

    def ps_view(self, data):
        """PowerShell's parse of `data`: {errors, comments, tokens}."""
        src = self._file(data, ".ps1")
        out = self.tmp / f"t{self.n}.json"
        r = subprocess.run([self.ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", str(HERE / "ps_tokens.ps1"), "-Path", str(src), "-Out", str(out)],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0 or not out.exists():
            raise RuntimeError(f"ps_tokens.ps1 failed: {(r.stderr or r.stdout)[:300]}")
        v = json.loads(out.read_text(encoding="utf-8-sig"))
        # ConvertTo-Json writes a one-element array as a bare value.
        view = {k: (v.get(k) if isinstance(v.get(k), list) else [v[k]] if v.get(k) else []) for k in ("errors", "comments", "tokens")}
        # Newlines before the first statement mean nothing; a header comment leaves one.
        while view["tokens"][:1] == ["NewLine"]:
            view["tokens"].pop(0)
        return view

    def bash_n(self, data):
        p = self._file(data, ".sh")
        r = subprocess.run([self.bash, "-n", str(p)], capture_output=True, text=True)
        return r.returncode == 0, r.stderr[:300]

    def bash_body(self, data):
        """bash's canonical print of the script as a function body (comments are gone from it)."""
        p = self._file(b"__ship_copy_body() {\n" + data + b"\n}\ndeclare -f __ship_copy_body\n", ".sh")
        r = subprocess.run([self.bash, str(p)], capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(f"bash could not load the body: {r.stderr[:300]!r}")
        return r.stdout


def sh_comment_lines(data):
    lines = data.decode("utf-8").split("\n")
    return [(i, l) for i, l in enumerate(lines, 1) if l.lstrip().startswith("#") and not (i == 1 and l.startswith("#!"))]


def ps_comments(view):
    return [c for c in view["comments"] if not c["text"].lower().startswith("#requires")]


def plant(data, line):
    lines = data.split(b"\n")
    mid = len(lines) // 2
    return b"\n".join(lines[:mid] + [line] + lines[mid:])


def main():
    with tempfile.TemporaryDirectory(prefix="strip-comments-") as tmp:
        t = Tools(tmp)
        check("bash is on PATH", bool(t.bash))
        check("PowerShell is on PATH", bool(t.ps))
        if not (t.bash and t.ps):
            print("\nSTRIP TEST FAILED: cannot run without both interpreters")
            return 1

        for label, path, shipped in WRAPPERS:
            print(f"{label}: {path.relative_to(HERE)}")
            loose = path.read_bytes()
            ship = ship_copy(path.name, loose)
            embedded = shipped()
            loose_lines, ship_lines = loose.count(b"\n"), ship.count(b"\n")
            check("the ship copy is a real script, not an empty one",
                  ship_lines > loose_lines // 3, f"{ship_lines} of {loose_lines} lines kept")
            check("the egg embeds the ship copy", embedded == ship,
                  f"{len(embedded)} B embedded vs {len(ship)} B ship copy")

            if path.suffix == ".ps1":
                src_view, ship_view = t.ps_view(loose), t.ps_view(ship)
                check("it parses (PowerShell parser)", not ship_view["errors"], "; ".join(ship_view["errors"][:3]))
                check("same tokens as the source, minus comments", src_view["tokens"] == ship_view["tokens"],
                      f"{len(src_view['tokens'])} vs {len(ship_view['tokens'])} tokens")
                emb_view = t.ps_view(embedded)
                left = ps_comments(emb_view)
                check("the embedded copy holds no comment", not left,
                      "; ".join(f"line {c['line']}: {c['text'][:60]}" for c in left[:3]))
                planted = ps_comments(t.ps_view(plant(embedded, b"# planted note #1234")))
                check("a planted comment is caught", len(planted) == len(left) + 1, f"{len(planted) - len(left)} found")
                bad = embedded.replace(MUTATE[path.suffix][0], MUTATE[path.suffix][1], 1)
                check("a changed string is caught as a different program",
                      bad != embedded and t.ps_view(bad)["tokens"] != ship_view["tokens"])
            else:
                ok, err = t.bash_n(ship)
                check("it parses (bash -n)", ok, err)
                check("same program as the source (declare -f)", t.bash_body(loose) == t.bash_body(ship))
                left = sh_comment_lines(embedded)
                check("the embedded copy holds no comment line", not left,
                      "; ".join(f"line {i}: {l.strip()[:60]}" for i, l in left[:3]))
                planted = sh_comment_lines(plant(embedded, b"    # planted note #1234"))
                check("a planted comment is caught", len(planted) == len(left) + 1, f"{len(planted) - len(left)} found")
                bad = embedded.replace(MUTATE[path.suffix][0], MUTATE[path.suffix][1], 1)
                check("a changed string is caught as a different program",
                      bad != embedded and t.bash_body(bad) != t.bash_body(ship))

            hits = BUG_NUMBER.findall(embedded.decode("utf-8", errors="replace"))
            check("the embedded copy carries no bug number", not hits, ", ".join(hits[:5]))
            check("a planted bug number is caught",
                  bool(BUG_NUMBER.findall(plant(embedded, b'Write-Host "(x) see #1234"').decode("utf-8"))))

    print()
    if FAILS:
        print(f"STRIP TEST FAILED: {len(FAILS)} check(s): " + "; ".join(FAILS))
        return 1
    print("STRIP TEST PASS - every shipped wrapper is comment-free and the same program as its source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
