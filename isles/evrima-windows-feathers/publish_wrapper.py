#!/usr/bin/env python3
"""Publish the Evrima startup wrapper (+ its .tmpl files) to R2 for fleet self-update.

WHY THIS EXISTS
---------------
`_primal/start-evrima.ps1` is materialised exactly ONCE, by the egg's
*installation* script, from a base64 blob. Pterodactyl runs installation scripts
only on install/reinstall, and nothing in the boot path ever re-reads the file.
So the one component that renders Engine.ini was the one component frozen at
install time: every wrapper change meant hand-editing the file on every Evrima
server in the fleet.

The wrapper already pulls two OTHER artifacts from R2 manifests on every boot
(the pak, and the sigbypass binaries). This publisher gives the wrapper the same
treatment as those, using the identical manifest shape, so a change ships by
publishing instead of by walking the fleet.

Manifest shape the wrapper consumes (same as publish_pak.py):
  {
    "version": "1",
    "build":   "wrapper 1 2026-08-01",
    "files": [
      {"name": "start-evrima.ps1", "url": "...", "sha256": "...", "size": 47086}
    ]
  }

Every file listed is placed into the server's `_primal\\` directory. sha256 is the
authority - a file is refreshed whenever it is missing or its hash differs, so a
mislabelled version cannot serve a stale wrapper (#410).

🔴 BLAST RADIUS - READ BEFORE PUBLISHING
   The pak and sigbypass lanes fail soft: a bad artifact means the mod does not
   mount, and the server still boots. This one does not. A broken wrapper is a
   server that does not start, on EVERY Evrima server at once, because they all
   read this single manifest. Mitigations, in the wrapper and here:
     * the wrapper PARSE-CHECKS every .ps1 before letting it replace a live file,
       and discards the update on a syntax error;
     * this publisher refuses to upload a .ps1 that does not parse (needs
       PowerShell on PATH; --skip-parse-check overrides, and says so loudly);
     * every version is uploaded under its OWN key and kept, so rolling back is
       re-publishing an old manifest, not recovering a deleted object;
     * PRIMAL_WRAPPER_PIN=<version> holds a single server on a single version;
     * PRIMAL_WRAPPER_AUTOUPDATE=0 opts a server out entirely.
   Publishing is inert until a server restarts. It does not restart anything.

Usage:
  python publish_wrapper.py --version 1 --dry-run
  python publish_wrapper.py --version 1
  python publish_wrapper.py --version 2 --files start-evrima.ps1 Engine.ini.tmpl

Requires wrangler + CLOUDFLARE_API_TOKEN/ACCOUNT_ID (read from the Primal secrets
store if the env vars aren't already set).
"""
import argparse, hashlib, json, os, pathlib, subprocess, sys

BUCKET = "primal-legacy-mods"          # shared bucket; the wrapper gets its own prefix
PREFIX = "primal-wrapper-evrima"
PUBLIC_BASE = "https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev"
SECRETS = pathlib.Path.home() / ".claude" / ".secrets" / "primal-credentials.env"
DEFAULT_FILES = ["start-evrima.ps1"]
HERE = pathlib.Path(__file__).resolve().parent


def _load_cf_env() -> None:
    if os.getenv("CLOUDFLARE_API_TOKEN") and os.getenv("CLOUDFLARE_ACCOUNT_ID"):
        return
    if SECRETS.exists():
        for line in SECRETS.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("CLOUDFLARE_API_TOKEN=") or line.startswith("CLOUDFLARE_ACCOUNT_ID="):
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())


def _r2_put(key: str, file: pathlib.Path, content_type: str) -> None:
    subprocess.run(
        ["npx", "wrangler", "r2", "object", "put", f"{BUCKET}/{key}",
         "--file", str(file), "--content-type", content_type, "--remote"],
        check=True, shell=(os.name == "nt"),
    )


def _parse_check(fp: pathlib.Path) -> tuple[bool, str]:
    """Reject a .ps1 that does not parse. The wrapper checks this too, but a bad
    publish should be stopped here rather than discovered by 30 servers."""
    ps = (
        "$e=$null;"
        f"[System.Management.Automation.Language.Parser]::ParseFile('{fp}',[ref]$null,[ref]$e);"
        "if($e.Count){$e[0].Extent.StartLineNumber.ToString()+': '+$e[0].Message;exit 1}else{'OK'}"
    )
    for exe in ("powershell", "pwsh"):
        try:
            r = subprocess.run([exe, "-NoProfile", "-Command", ps],
                               capture_output=True, text=True, timeout=90)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        return r.returncode == 0, (r.stdout or r.stderr).strip()
    return False, "no PowerShell on PATH (use --skip-parse-check to override)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="version token, e.g. 1 (fast-path compare)")
    ap.add_argument("--build", default="", help='human stamp, e.g. "wrapper 1 2026-08-01"')
    ap.add_argument("--src", default=str(HERE / "_primal"),
                    help="dir holding the wrapper + templates (default: ./_primal)")
    ap.add_argument("--files", nargs="+", default=DEFAULT_FILES,
                    help=f"files to publish into the server's _primal dir (default: {' '.join(DEFAULT_FILES)})")
    ap.add_argument("--dry-run", action="store_true", help="build + print the manifest, upload nothing")
    ap.add_argument("--skip-parse-check", action="store_true", help="🔴 publish a .ps1 without verifying it parses")
    args = ap.parse_args()

    build = args.build or f"wrapper {args.version}"
    src = pathlib.Path(args.src)

    files = []
    for name in args.files:
        fp = src / name
        if not fp.is_file():
            print(f"missing artifact: {fp}", file=sys.stderr)
            return 1
        if name.lower().endswith(".ps1"):
            if args.skip_parse_check:
                print(f"🔴 --skip-parse-check: {name} is being published UNVERIFIED")
            else:
                ok, msg = _parse_check(fp)
                if not ok:
                    print(f"PARSE CHECK FAILED for {name}: {msg}", file=sys.stderr)
                    print("refusing to publish - this would brick every Evrima server", file=sys.stderr)
                    return 1
                print(f"parse check {name}: OK")
        data = fp.read_bytes()
        if name.lower().endswith(".ps1") and b"\r" in data:
            # The wrapper writes Engine.ini LF-only on purpose (a CR inside ApiToken
            # gives valueLen=54 and a 401 on every data-plane call). Keep the script
            # itself LF too so an editor round-trip cannot reintroduce them.
            print(f"⚠️  {name} contains CR bytes - publishing anyway, but it should be LF-only")
        key = f"{PREFIX}/{args.version}/{name}"
        files.append({
            "name": name,
            "url": f"{PUBLIC_BASE}/{key}",
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
            "_key": key,
            "_path": str(fp),
        })

    manifest = {
        "version": args.version,
        "build": build,
        "files": [{k: f[k] for k in ("name", "url", "sha256", "size")} for f in files],
    }

    print(f"\nwrapper {args.version}  ({build})")
    for f in files:
        print(f"  {f['name']:<24} {f['size']:>8} bytes  sha256 {f['sha256'][:16]}...")
    print("manifest:")
    print(json.dumps(manifest, indent=2))

    if args.dry_run:
        print("\n--dry-run: nothing uploaded.")
        return 0

    _load_cf_env()

    # Artifacts first, manifest last, so the manifest never points at a key that
    # is not up yet.
    for f in files:
        print(f"uploading {f['_key']} ...")
        _r2_put(f["_key"], pathlib.Path(f["_path"]), "text/plain")

    mpath = src / f"latest-wrapper-{args.version}.json"
    mpath.write_text(json.dumps(manifest, indent=2))
    _r2_put(f"{PREFIX}/latest.json", mpath, "application/json")
    mpath.unlink(missing_ok=True)

    print(f"\nPUBLISHED wrapper {args.version}")
    print(f"  manifest: {PUBLIC_BASE}/{PREFIX}/latest.json")
    print("Every Evrima server picks this up on its next FULL stop->start.")
    print("Rollback = re-publish an older --version; every version's objects are kept.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
