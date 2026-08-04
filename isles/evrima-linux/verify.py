#!/usr/bin/env python3
"""verify.py - prove every extracted file matches what ships (the judge).

Gates, each earned elsewhere in this repo:
  1. Every base64 blob in install.sh decodes byte-identically to its loose
     file, and the sha256 recorded beside the blob matches (the installer
     re-checks that sha at decode time - a corrupted blob fails the install).
  2. egg-evrima-linux.json scripts.installation.script == install.sh verbatim.
  3. start-evrima.sh and install.sh parse under `bash -n` (a wrapper that does
     not parse is a server that does not boot - and via the self-update lane,
     a FLEET that does not boot).
  4. No CR bytes in the shell/tmpl sources (a CR in Engine.ini lands inside
     the token -> 401; egg 40's LF rule, load-bearing).
  5. Rule 10 secret scan: no phsk_/phdk_/ptlc_/ptla_/whsec_ VALUES, and the
     RCON fallback stays 'CHANGEME'.
  6. Query-port bake: the wrapper must not read a QUERY_PORT variable and the
     egg must not define one (Ice's rule, 2026-08-04).
"""
import base64
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FAILS = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILS.append(name)


def main() -> int:
    install = (HERE / "install.sh").read_text(encoding="utf-8")
    egg = json.loads((HERE / "egg-evrima-linux.json").read_text(encoding="utf-8"))

    # 1. blobs decode to the loose files, recorded shas correct
    blobs = {
        "B64_START_EVRIMA": "start-evrima.sh",
        "B64_GAME_TMPL": "Game.ini.tmpl",
        "B64_ENGINE_TMPL": "Engine.ini.tmpl",
    }
    for marker, fname in blobs.items():
        m = re.search(rf"<<'{marker}'\n(.*?)\n{marker}\n", install, re.DOTALL)
        if not m:
            check(f"blob {fname} present", False, "heredoc marker missing")
            continue
        try:
            decoded = base64.b64decode(m.group(1))
        except Exception as e:  # noqa: BLE001
            check(f"blob {fname} decodes", False, str(e))
            continue
        loose = (HERE / fname).read_bytes()
        check(f"blob {fname} == loose file", decoded == loose,
              f"{len(decoded)} B vs {len(loose)} B")
        sha = hashlib.sha256(loose).hexdigest()
        rec = re.search(rf"# BLOB:{re.escape(fname)} sha256=([0-9a-f]{{64}})", install)
        check(f"recorded sha for {fname}", bool(rec) and rec.group(1) == sha)
        arg = re.search(
            rf'write_blob "\$PRIM/{re.escape(fname)}" "([0-9a-f]{{64}})"', install
        )
        check(f"write_blob sha arg for {fname}", bool(arg) and arg.group(1) == sha)

    # 2. egg JSON carries install.sh verbatim
    check(
        "egg JSON script == install.sh",
        egg["scripts"]["installation"]["script"] == install,
    )

    # 3. bash -n both shell files (skipped only if no bash on PATH)
    bash = shutil.which("bash")
    for f in ("start-evrima.sh", "install.sh"):
        if bash:
            r = subprocess.run([bash, "-n", str(HERE / f)], capture_output=True)
            check(f"bash -n {f}", r.returncode == 0, r.stderr.decode()[:200])
        else:
            check(f"bash -n {f}", False, "bash not on PATH - cannot verify")

    # 4. LF-only sources
    for f in ("start-evrima.sh", "install.sh", "Game.ini.tmpl", "Engine.ini.tmpl"):
        check(f"{f} has no CR bytes", b"\r" not in (HERE / f).read_bytes())

    # 5. secret scan (values, not variable names)
    secret_pat = re.compile(
        r"(phsk_[0-9a-fA-F]{8,}|phdk_[0-9a-fA-F]{8,}|ptlc_\w{8,}|ptla_\w{8,}|whsec_\w{8,})"
    )
    for f in ("start-evrima.sh", "install.sh", "Game.ini.tmpl", "Engine.ini.tmpl",
              "egg-evrima-linux.json", "README.md"):
        p = HERE / f
        if not p.exists():
            continue
        hits = [
            h for h in secret_pat.findall(p.read_text(encoding="utf-8", errors="replace"))
            # the wrapper's shape-extraction regex literal is the one allowed hit
            if "0-9a-fA-F" not in h
        ]
        check(f"no secret values in {f}", not hits, ", ".join(h[:12] for h in hits))
    wrapper = (HERE / "start-evrima.sh").read_text(encoding="utf-8")
    check(
        "RCON fallback stays CHANGEME",
        '"${RCON_PASSWORD:-}" "CHANGEME"' in wrapper,
    )

    # 6. query port == game port is BAKED
    # an actual env READ ($QUERY_PORT / ${QUERY_PORT...}), not the word in a
    # comment explaining why there isn't one
    check(
        "wrapper never reads QUERY_PORT",
        not re.search(r"\$\{?QUERY_PORT", wrapper),
    )
    env_vars = [
        v["env_variable"] for v in egg.get("variables", [])
    ]
    check("egg defines no QUERY_PORT variable", "QUERY_PORT" not in env_vars)
    check(
        "launch line pins -QueryPort to the game port",
        '-QueryPort="$GAME_PORT" -Port="$GAME_PORT"' in wrapper,
    )

    print()
    if FAILS:
        print(f"VERIFY FAILED: {len(FAILS)} gate(s): " + "; ".join(FAILS))
        return 1
    print("VERIFY PASS - loose files, install.sh and the egg JSON all agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
