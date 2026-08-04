#!/usr/bin/env python3
"""publish_wrapper.py - publish the Linux wrapper + templates to R2 so the
fleet's self-update lane picks them up (key prefix: primal-wrapper-evrima-linux/).

The Linux analog of the Windows wrapper's primal-wrapper-evrima/ manifest, and
the same shape publish_pak.py uses: upload the versioned artifacts FIRST, the
manifest LAST, so a reader can never see a manifest pointing at files that are
not there yet.

Usage:
  python publish_wrapper.py --version 1 --dry-run   # print the manifest only
  python publish_wrapper.py --version 1             # upload

Requires wrangler + CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID in the
environment (read them from the Primal credentials file; never echo them).
Run verify.py FIRST - a broken wrapper published here bricks every server on
this egg at its next boot (the lane parse-checks before applying, but do not
lean on that).
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
BUCKET = "primal-legacy-mods"
PREFIX = "primal-wrapper-evrima-linux"
PUBLIC_BASE = "https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev"
FILES = ["start-evrima.sh", "Game.ini.tmpl", "Engine.ini.tmpl"]


def r2_put(key: str, file: pathlib.Path, content_type: str) -> None:
    subprocess.run(
        ["npx", "wrangler", "r2", "object", "put", f"{BUCKET}/{key}",
         "--file", str(file), "--content-type", content_type, "--remote"],
        check=True, shell=(sys.platform == "win32"),
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    gate = subprocess.run([sys.executable, str(HERE / "verify.py")])
    if gate.returncode != 0:
        print("verify.py FAILED - refusing to publish a wrapper that fails its own gate.")
        return 1

    manifest = {"version": str(args.version), "build": f"linux wrapper {args.version}", "files": []}
    for name in FILES:
        p = HERE / name
        data = p.read_bytes()
        if b"\r" in data:
            print(f"REFUSING: {name} contains CR bytes (a CR lands inside the token -> 401).")
            return 1
        manifest["files"].append({
            "name": name,
            "url": f"{PUBLIC_BASE}/{PREFIX}/{args.version}/{name}",
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        })

    print(json.dumps(manifest, indent=2))
    if args.dry_run:
        print("\n--dry-run: nothing uploaded.")
        return 0

    for f in manifest["files"]:
        print(f"uploading {PREFIX}/{args.version}/{f['name']} ...")
        r2_put(f"{PREFIX}/{args.version}/{f['name']}", HERE / f["name"], "text/plain")
    mpath = HERE / ".manifest.tmp.json"
    mpath.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    r2_put(f"{PREFIX}/latest.json", mpath, "application/json")
    mpath.unlink()
    print(f"published {PREFIX} v{args.version} ({len(FILES)} files + latest.json)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
