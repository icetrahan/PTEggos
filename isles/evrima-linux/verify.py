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
  7. Game.ini.tmpl never writes bSpawnAmbientFauna (#3542).
  8. The mass-check lever (#3604) is ops-only and its panel range is the
     wrapper's.
  9. The two fleet timing constants (#3631) are the wrapper's, with egg 40's
     values, and the template carries neither.
 10. The no-plane fallbacks of BOTH Evrima wrappers equal the plane's defaults
     (#3326, #3331). A server renders them only when it boots with no plane and
     no cached settings, so nothing else notices when one drifts.
 11. render_test.sh keeps every fixture under one folder per run and removes
     it on exit (#3909): each case writes a 160 MB binary.
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

# The data plane's CONFIG_DEFAULTS.server_settings, as each wrapper spells them:
# plane field -> (egg 40 `$cfg` key and egg 42 `CFG_` name, rendered value).
# ⛔ A row changes only when the plane's default changes.
PLANE_DEFAULTS = {
    "maxPlayers": ("MaxPlayers", "150"),
    "serverPasswordEnabled": ("ServerPasswordEnabled", "False"),
    "rconEnabled": ("RconEnabled", "False"),
    "corpseDecay": ("CorpseDecay", "1"),
    "enableHumans": ("EnableHumans", "True"),
    "dayLengthMin": ("DayLength", "45"),
    "nightLengthMin": ("NightLength", "20"),
    "growthMultiplier": ("GrowthMultiplier", "1"),
    "enableGlobalChat": ("EnableGlobalChat", "True"),
    "enableAi": ("EnableAI", "True"),
    "aiDensity": ("AIDensity", "0.25"),
    "aiSpawnInterval": ("AISpawnInterval", ""),
    "spawnFish": ("SpawnFish", "True"),
    "enableMutations": ("EnableMutations", "True"),
    "enableDiets": ("EnableDiets", "True"),
    "fallDamage": ("FallDamage", "True"),
    "allowReplay": ("AllowReplay", "True"),
    "dynamicWeather": ("DynamicWeather", "False"),
    "whitelistEnabled": ("WhitelistEnabled", "False"),
    "spawnPlants": ("SpawnPlants", "True"),
    "plantMultiplier": ("PlantMultiplier", "1"),
    "enableMigration": ("EnableMigration", "True"),
    "enableMassMigration": ("EnableMassMigration", "True"),
    "enablePatrolZones": ("EnablePatrolZones", "True"),
    "useRegionSpawning": ("UseRegionSpawning", "False"),
    "useRegionSpawnCooldown": ("UseRegionSpawnCooldown", "False"),
    "regionSpawnCooldownSeconds": ("RegionSpawnCooldownSeconds", "150"),
    "mapName": ("MapName", "Gateway"),
    "queueEnabled": ("QueueEnabled", "True"),
}


def fallbacks_egg40(text):
    """The `$cfg = @{ ... }` table of start-evrima.ps1: key -> value."""
    m = re.search(r"^\$cfg = @\{\n(.*?)^\}", text, re.DOTALL | re.MULTILINE)
    return dict(re.findall(r"^\s+(\w+)\s+=\s+'([^']*)'", m.group(1), re.MULTILINE)) if m else {}


def fallbacks_egg42(text):
    """The top-level CFG_ assignments of start-evrima.sh: name -> value."""
    return dict(re.findall(r'^CFG_(\w+)="([^"]*)"', text, re.MULTILINE))


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
    # The first-boot fallback (the plane's rconPassword overrides it). The shape
    # changed with the 2026-09-05 boot-config port; the rule did not.
    check(
        "RCON fallback stays CHANGEME",
        'CFG_RconPassword="CHANGEME"' in wrapper,
    )

    # 7. THE BOOT-CONFIG LANE EXISTS. Egg 42 rendered Game.ini from egg
    # variables until 2026-09-05 while the panel wrote the data plane, so all 42
    # canonical fields saved green and changed nothing. This gate is the thing
    # that notices if the lane is ever removed or refactored away.
    check("wrapper fetches /v1/boot-config", "/v1/boot-config" in wrapper)
    check("wrapper caches the canonical config", "boot-config.cache.json" in wrapper)
    for rung in ("fetched", "cache", "defaults"):
        check(f"fail-safe rung '{rung}' is distinguishable", f'CFG_SOURCE="{rung}"' in wrapper)
    check(
        "the two controls Ice ruled in are rendered",
        "PAK_EXTRA[AIMaxCount]" in wrapper and "speciesCapEvery" in wrapper
        and "speciesCapList" in wrapper,
    )
    # #1071: a numeric pak key without its paired sentinel silently does nothing.
    check(
        "#1071 sentinels are derived beside their numeric",
        'PAK_EXTRA[BodyHoldSet]="True"' in wrapper and 'PAK_EXTRA[BSLiftSet]="True"' in wrapper,
    )
    # #1094: a generic pak key setter is the panel's authority with no allowlist.
    check(
        "no generic PRIMAL_MOD_INI key setter",
        "PAK_EXTRA[$K]=" not in wrapper,
    )
    # jq must be pinned by sha256 and mirrored on OUR R2, never fetched from a
    # third party at boot.
    check("jq is pinned by sha256", 'JQ_SHA256="' in wrapper)
    check(
        "jq comes from our R2, not GitHub",
        '$R2_BASE/primal-wrapper-evrima-linux/jq/' in wrapper
        and "github.com" not in wrapper.lower(),
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

    # 7. ⛔ #3542: the key turns on the game's ambient bird, which cannot
    # animate. The game's default is off, and fish have their own key.
    check(
        "Game.ini.tmpl never writes bSpawnAmbientFauna",
        b"bspawnambientfauna" not in (HERE / "Game.ini.tmpl").read_bytes().lower(),
    )

    # 8. #3604: the mass-check lever is ops-only, and the panel accepts exactly
    # the range the wrapper writes (two copies of one range must not drift).
    mass = next((v for v in egg.get("variables", [])
                 if v["env_variable"] == "PRIMAL_MASS_MIGRATION_TIME"), None)
    check(
        "PRIMAL_MASS_MIGRATION_TIME is an ops-only egg variable",
        bool(mass) and not mass["user_viewable"] and not mass["user_editable"],
    )
    check(
        "its panel range is the wrapper's (86401 to 31536000)",
        bool(mass) and mass["rules"] == "nullable|integer|between:86401,31536000"
        and '[ "$MASS_ASKED" -gt 86400 ]' in wrapper
        and '[ "$MASS_ASKED" -le 31536000 ]' in wrapper,
    )
    check(
        "Game.ini.tmpl carries no MassMigrationTime of its own",
        b"massmigrationtime=" not in (HERE / "Game.ini.tmpl").read_bytes().lower(),
    )

    # 9. #3631: one ruling, two eggs. The wrapper writes both constants, and
    # their values are the ones egg 40 writes (two copies must not drift).
    loop = re.search(r"^for FLEET_KV in (.+); do$", wrapper, re.MULTILINE)
    mine = dict(kv.split("=", 1) for kv in loop.group(1).split()) if loop else {}
    check(
        "the wrapper writes MassMigrationDisableTime and IndividualPatrolTime",
        set(mine) == {"MassMigrationDisableTime", "IndividualPatrolTime"},
        f"found {sorted(mine)}",
    )
    egg40 = HERE.parent / "evrima-windows-feathers" / "start-evrima.ps1"
    theirs = dict(re.findall(
        r"Set-SessionKey \$gi '(MassMigrationDisableTime|IndividualPatrolTime)' '(\d+)'",
        egg40.read_text(encoding="utf-8", errors="replace") if egg40.exists() else "",
    ))
    check(
        "their values are egg 40's",
        len(theirs) == 2 and mine == theirs,
        f"egg 42 {mine} vs egg 40 {theirs}",
    )
    tmpl = (HERE / "Game.ini.tmpl").read_bytes().lower()
    check(
        "Game.ini.tmpl carries neither fleet timing key",
        b"massmigrationdisabletime=" not in tmpl and b"individualpatroltime=" not in tmpl,
    )

    # 10. the no-plane fallbacks of both wrappers are the plane's defaults
    for label, path, read in (
        ("egg 40", egg40, fallbacks_egg40),
        ("egg 42", HERE / "start-evrima.sh", fallbacks_egg42),
    ):
        got = read(path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")) if path.exists() else {}
        off = [
            f"{key}={got.get(key)!r} (plane {field}: {want!r})"
            for field, (key, want) in PLANE_DEFAULTS.items()
            if got.get(key) != want
        ]
        check(
            f"{label}'s no-plane fallbacks are the plane's defaults ({len(PLANE_DEFAULTS)} values)",
            bool(got) and not off,
            "; ".join(off) if got else f"{path.name} not found or its fallback table not read",
        )

    # 11. render_test.sh: one fixture folder per run, removed on exit
    rt = (HERE / "render_test.sh").read_text(encoding="utf-8").replace("\r\n", "\n")
    code = "\n".join(line for line in rt.split("\n") if not line.lstrip().startswith("#"))
    check(
        "render_test.sh makes one fixture folder per run and removes it on exit",
        'RUN_T="$(mktemp -d "${TMPDIR:-/tmp}/render-test.XXXXXX")"' in code
        and re.search(r"^trap 'rm -rf \"\$RUN_T\"' EXIT$", code, re.MULTILINE) is not None,
    )
    roots = re.findall(r'^\s*(?:local T|RT_SHIM)="([^"]*)"', code, re.MULTILINE)
    check(
        "every render_test.sh fixture root is inside it",
        bool(roots) and all(r.startswith("$RUN_T/") for r in roots) and '"/tmp/' not in code,
        f"roots {roots}",
    )

    print()
    if FAILS:
        print(f"VERIFY FAILED: {len(FAILS)} gate(s): " + "; ".join(FAILS))
        return 1
    print("VERIFY PASS - loose files, install.sh and the egg JSON all agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
