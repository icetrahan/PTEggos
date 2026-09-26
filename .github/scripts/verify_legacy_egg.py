#!/usr/bin/env python3
"""Egg 41 (Legacy / Windows feathers): prove the wrapper blob embedded in egg-isle-legacy.json is byte-for-byte
the loose start-legacy.ps1 (BACKLOG A255). Egg 40 and egg 42 have their own verify.py; egg 41 is assembled by
build_egg.py and had no judge, so a loose-file edit without a rebuild would ship the OLD wrapper to every new
Legacy server and read green everywhere.

    python .github/scripts/verify_legacy_egg.py        (exit 0 = agree, 1 = drift, 2 = cannot tell)
"""
import base64
import hashlib
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parents[2] / "isles" / "legacy-windows-feathers"


def main():
    try:
        egg = json.loads((HERE / "egg-isle-legacy.json").read_text(encoding="utf-8"))
        loose = (HERE / "start-legacy.ps1").read_bytes()
    except (OSError, ValueError) as e:
        print("CANNOT TELL: %s" % e)
        return 2
    install = ((egg.get("scripts") or {}).get("installation") or {}).get("script") or ""
    runs = re.findall(r"[A-Za-z0-9+/]{400,}={0,2}", install)
    if len(runs) != 1:
        print("CANNOT TELL: expected exactly ONE embedded base64 blob in the install script, found %d" % len(runs))
        return 2
    blob = base64.b64decode(runs[0])
    b, l = hashlib.sha256(blob).hexdigest(), hashlib.sha256(loose).hexdigest()
    print("embedded start-legacy.ps1 %d B sha256=%s" % (len(blob), b))
    print("loose    start-legacy.ps1 %d B sha256=%s" % (len(loose), l))
    if blob != loose:
        print("VERIFY FAILED: the egg installs a DIFFERENT wrapper than the loose file - run build_egg.py and commit the egg")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
