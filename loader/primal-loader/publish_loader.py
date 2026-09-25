#!/usr/bin/env python3
"""Publish primal-loader to R2 as the sha-pinned manifest the Windows wrappers read (A230).

    python loader/primal-loader/publish_loader.py --version 1.0.0            # dry run: build facts only
    python loader/primal-loader/publish_loader.py --version 1.0.0 --apply    # upload + read back

Manifest: {PUBLIC_BASE}/primal-loader/latest.json
    {version, source_commit, files: [{name, url, sha256, size}, ...]}
Files:
    primal-loader.asi  - build/primal-loader.asi, built by build.bat from a CLEAN tree at HEAD
    dsound.dll         - Ultimate ASI Loader x64, byte-for-byte the SAME binary the Evrima sigbypass
                         lane pins (primal-sigbypass/latest.json, UniversalSigBypasser v1.2) - fetched
                         from there and refused unless its sha256 is the pinned one below.
Refuses: a dirty loader/ tree, a build older than the source, a dsound.dll that is not the pinned one.
After upload every file is re-downloaded from the PUBLIC url and its sha compared (never trust the put).
Nothing reads this manifest until a wrapper that names it boots, so publishing changes no live server.
Requires wrangler + CLOUDFLARE_API_TOKEN/ACCOUNT_ID (from the Primal creds env if unset), never printed.
"""
import argparse, hashlib, json, os, pathlib, subprocess, sys, tempfile, time

BUCKET = "primal-legacy-mods"
PREFIX = "primal-loader"
PUBLIC_BASE = "https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev"
SIGBYPASS_MANIFEST = PUBLIC_BASE + "/primal-sigbypass/latest.json"
DSOUND_SHA = "f4abc8a2371978e4114f267fc77fb8bb2ae94c0143f755eb5e6f113ce1bc187d"   # UAL x64, sigbypass v1.2
SECRETS = pathlib.Path.home() / ".claude" / ".secrets" / "primal-credentials.env"
HERE = pathlib.Path(__file__).resolve().parent


def sha(b):
    return hashlib.sha256(b).hexdigest()


def get(url):
    # curl, not urllib: on the build workstation Python's TLS chain for r2.dev fails ("certificate has
    # expired", 2026-09-25) while curl (schannel) verifies it. Cache-busted so a read-back is the live object.
    u = url + ("&" if "?" in url else "?") + f"nocache={int(time.time())}"
    return subprocess.run(["curl", "-sSfL", "--max-time", "60", "-A", "primal-loader-publish/1", u], capture_output=True, check=True).stdout


def cf_env():
    if os.getenv("CLOUDFLARE_API_TOKEN") and os.getenv("CLOUDFLARE_ACCOUNT_ID"):
        return
    for line in SECRETS.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith(("CLOUDFLARE_API_TOKEN=", "CLOUDFLARE_ACCOUNT_ID=")):
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


def put(key, path, ctype):
    subprocess.run(["npx", "wrangler", "r2", "object", "put", f"{BUCKET}/{key}", "--file", str(path),
                    "--content-type", ctype, "--remote"], check=True, shell=(os.name == "nt"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--asi", default=str(HERE / "build" / "primal-loader.asi"))
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    dirty = subprocess.run(["git", "status", "--porcelain", "--", str(HERE)], capture_output=True, text=True, cwd=HERE).stdout.strip()
    if dirty:
        sys.exit(f"REFUSED: loader/ has uncommitted changes - build from a commit:\n{dirty}")
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=HERE).stdout.strip()
    asi = pathlib.Path(a.asi)
    if asi.stat().st_mtime < (HERE / "primal_loader.cpp").stat().st_mtime:
        sys.exit("REFUSED: the .asi is older than primal_loader.cpp - run build.bat")
    asi_b = asi.read_bytes()

    sb = json.loads(get(SIGBYPASS_MANIFEST))
    ds = next(f for f in sb["files"] if f["name"].lower() == "dsound.dll")
    ds_b = get(ds["url"])
    if sha(ds_b) != DSOUND_SHA or ds["sha256"].lower() != DSOUND_SHA:
        sys.exit(f"REFUSED: sigbypass dsound.dll is not the pinned UAL ({sha(ds_b)[:12]} / manifest {ds['sha256'][:12]})")

    files = [("dsound.dll", ds_b), ("primal-loader.asi", asi_b)]
    manifest = {"version": a.version, "source_commit": head,
                "notes": "A230 - the game loads its own Primal DLLs: Ultimate ASI Loader (dsound.dll, = sigbypass v1.2) + primal-loader.asi",
                "files": [{"name": n, "url": f"{PUBLIC_BASE}/{PREFIX}/{a.version}/{n}", "sha256": sha(b), "size": len(b)} for n, b in files]}
    print(json.dumps(manifest, indent=1))
    if not a.apply:
        print("dry run - nothing uploaded (--apply to publish)")
        return 0

    cf_env()
    with tempfile.TemporaryDirectory() as td:
        for n, b in files:
            p = pathlib.Path(td) / n
            p.write_bytes(b)
            put(f"{PREFIX}/{a.version}/{n}", p, "application/octet-stream")
        mp = pathlib.Path(td) / "latest.json"
        mp.write_text(json.dumps(manifest, indent=1), encoding="ascii")
        put(f"{PREFIX}/latest.json", mp, "application/json")
    rc = 0
    back = json.loads(get(f"{PUBLIC_BASE}/{PREFIX}/latest.json"))
    print(f"read back latest.json: version={back.get('version')} commit={back.get('source_commit', '')[:12]}")
    if back != manifest:
        print("MISMATCH: latest.json read back differs from what was put"); rc = 1
    for f in manifest["files"]:
        got = sha(get(f["url"]))
        ok = got == f["sha256"]
        print(f"read back {f['name']}: {got[:12]} {'VERIFIED' if ok else 'MISMATCH'}")
        rc |= 0 if ok else 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
