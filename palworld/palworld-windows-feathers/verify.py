#!/usr/bin/env python3
"""Verify egg-palworld-windows-feathers.json before it is imported anywhere.

Checks, in order of what has actually bitten this repo:

  1. The egg JSON parses and carries the fields Pterodactyl requires.
  2. Both scripts are pure ASCII (BUGS #448 - CP1252 decodes some multi-byte
     characters to 0x94, which PowerShell treats as a quote).
  3. The base64 wrapper embedded in the install script decodes BYTE-FOR-BYTE to
     start-palworld.ps1. A rebuilt egg that quietly carries a stale wrapper is
     the readback-is-not-evidence failure: the file on disk looks right, the
     thing that ships is old.
  4. BOTH scripts parse under the real PowerShell parser. A script that fails to
     parse does not half-run - it does nothing, and on the Evrima egg that shape
     of defect passed every other check.
  5. The startup command points at the file the install script actually writes.
"""
import base64
import json
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).parent
EGG = HERE / "egg-palworld-windows-feathers.json"
WRAPPER = HERE / "start-palworld.ps1"

fails: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


def ps_parse(source: str, label: str) -> None:
    """Parse with the real PowerShell parser; report every syntax error."""
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False,
                                     encoding="ascii", newline="\r\n") as fh:
        fh.write(source)
        tmp = fh.name
    probe = (
        "$e=$null;$t=$null;"
        f"[void][System.Management.Automation.Language.Parser]::ParseFile('{tmp}',[ref]$t,[ref]$e);"
        "if($e.Count -eq 0){'PARSE_OK'}else{"
        "$e|ForEach-Object{'PARSE_ERR line '+$_.Extent.StartLineNumber+': '+$_.Message}}"
    )
    res = subprocess.run(["powershell", "-NoProfile", "-Command", probe],
                         capture_output=True, text=True)
    out = (res.stdout or "").strip()
    if "PARSE_OK" in out:
        ok(f"{label} parses under PowerShell")
    else:
        fail(f"{label} does NOT parse:")
        for line in out.splitlines()[:12]:
            print(f"          {line}")
    pathlib.Path(tmp).unlink(missing_ok=True)


print("== egg structure")
if not EGG.exists():
    print("  FAIL  egg JSON missing - run build_egg.py")
    sys.exit(1)
raw = EGG.read_bytes()
bad = [b for b in raw if b > 0x7F]
if bad:
    fail(f"egg JSON has {len(bad)} non-ASCII byte(s)")
else:
    ok("egg JSON is pure ASCII")

egg = json.loads(raw.decode("ascii"))
for key in ("meta", "name", "author", "docker_images", "startup", "config", "scripts", "variables"):
    if key not in egg:
        fail(f"missing required key: {key}")
if egg.get("meta", {}).get("version") != "PTDL_v2":
    fail("meta.version is not PTDL_v2")
else:
    ok("meta.version = PTDL_v2")

for key in ("files", "startup", "logs", "stop"):
    v = egg.get("config", {}).get(key)
    if not isinstance(v, str):
        fail(f"config.{key} must be a JSON *string*, got {type(v).__name__}")
for key in ("files", "startup", "logs"):
    try:
        json.loads(egg["config"][key])
    except Exception as exc:
        fail(f"config.{key} is not valid embedded JSON: {exc}")
ok("config blocks are strings holding valid JSON")

install = egg["scripts"]["installation"]["script"]
if egg["scripts"]["installation"]["container"] != "windows/steamcmd":
    fail("install container is not windows/steamcmd")
if egg["scripts"]["installation"]["entrypoint"] != "powershell":
    fail("install entrypoint is not powershell")
ok("install container/entrypoint match the feathers pattern")

print("== readiness gate")
done = json.loads(egg["config"]["startup"]).get("done", "")
if not done.startswith("[PRIMAL]"):
    fail(f"done-string {done!r} is not wrapper-owned - vendor strings get reworded "
         "and the server self-kills while UP")
else:
    ok(f"done-string is wrapper-owned: {done!r}")
if done not in WRAPPER.read_text(encoding="ascii"):
    fail(f"the wrapper never prints {done!r} - the server would never mark started")
else:
    ok("the wrapper actually prints the done-string")

print("== embedded wrapper matches source")
m = re.search(r"\$wrapperB64 = @\((.*?)\) -join ''", install, re.S)
if not m:
    fail("no base64 wrapper block found in the install script")
else:
    b64 = "".join(re.findall(r"'([A-Za-z0-9+/=]*)'", m.group(1)))
    embedded = base64.b64decode(b64)
    on_disk = WRAPPER.read_bytes()
    if embedded != on_disk:
        fail(f"embedded wrapper DIFFERS from start-palworld.ps1 "
             f"({len(embedded)} B vs {len(on_disk)} B) - rebuild with build_egg.py")
    else:
        ok(f"embedded wrapper is byte-identical to source ({len(on_disk):,} B)")

print("== startup command points at what install writes")
startup = egg["startup"]
if "start-palworld.ps1" not in startup:
    fail("startup command does not reference start-palworld.ps1")
elif "_primal" not in startup:
    fail("startup command does not reference the _primal directory")
elif "Join-Path $prim 'start-palworld.ps1'" not in install:
    fail("install script does not write _primal\\start-palworld.ps1")
else:
    ok("startup -> _primal\\start-palworld.ps1, which install writes")

print("== install gate (hard rule 13 / BUGS #346)")
if "PalServer-Win64-Shipping.exe" not in install:
    fail("install script never checks the real Shipping binary")
else:
    ok("install gates on PalServer-Win64-Shipping.exe")
if install.count("exit 1") < 1:
    fail("install script has no failing exit path")
else:
    ok(f"install script has {install.count('exit 1')} failing exit path(s)")
tail = install[install.index("# --- verdict ---"):]
if "Install complete." in tail and tail.index("Install complete.") < tail.index("exit 0"):
    ok("'Install complete.' is only reachable inside the success branch")

print("== PowerShell parse")
ps_parse(install, "install script (as embedded in the egg)")
ps_parse(WRAPPER.read_text(encoding="ascii"), "start-palworld.ps1")

print("== variables")
names = [v["env_variable"] for v in egg["variables"]]
for required in ("SERVER_NAME", "ADMIN_PASSWORD", "MAX_PLAYERS", "SAVE_FOLDER",
                 "ENABLE_MODS", "ACTIVE_MODS"):
    if required not in names:
        fail(f"variable {required} is missing")
dupes = {n for n in names if names.count(n) > 1}
if dupes:
    fail(f"duplicate env_variable(s): {sorted(dupes)}")
ok(f"{len(names)} variables, no duplicates")
admin = next(v for v in egg["variables"] if v["env_variable"] == "ADMIN_PASSWORD")
if not admin["rules"].startswith("required"):
    fail("ADMIN_PASSWORD must be required - RCON stop depends on it")
else:
    ok("ADMIN_PASSWORD is required")

print()
if fails:
    print(f"VERIFY FAILED - {len(fails)} problem(s)")
    sys.exit(1)
print("VERIFY OK")
for n in notes:
    print(f"  note: {n}")
