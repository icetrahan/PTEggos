#!/usr/bin/env python3
"""Assemble the importable Pterodactyl egg (PTDL_v2) for The Isle: Legacy.
Base64-embeds _primal/start-legacy.ps1 into the install script, exactly like the
Evrima egg embeds start-evrima.ps1."""
import base64, json, datetime, pathlib

here = pathlib.Path(__file__).parent
# The wrapper lives at the repo dir root (the old _primal/ staging copy is gone —
# reading a path that doesn't exist would fail loudly, but don't resurrect it).
wrapper_b64 = base64.b64encode((here / "start-legacy.ps1").read_bytes()).decode()

install = r'''$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$game = Join-Path $root 'server'
$sc   = Join-Path $root 'steamcmd'
$prim = Join-Path $root '_primal'
foreach ($d in $game, $sc, $prim) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

Write-Output 'Downloading SteamCMD...'
$zip = Join-Path $sc 'steamcmd.zip'
Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $sc -Force
$steam = Join-Path $sc 'steamcmd.exe'

Write-Output 'Bootstrapping SteamCMD (self-update)...'
& $steam +quit

# The Isle Legacy = app 412680, branch `public` (~2.3GB). First app_update can fail
# with "Missing configuration" (app-config not cached) OR leave a wedged steamapps
# folder; either way we retry, and after a miss we NUKE steamapps to self-heal (the
# 2026-07-09 update outage — a stale appmanifest/`downloading` blocked every retry).
$serverExe = Join-Path $game 'TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe'
$steamApps = Join-Path $game 'steamapps'
$maxTries  = 5
for ($i = 1; $i -le $maxTries; $i++) {
  Write-Output "Installing The Isle: Legacy (app 412680, public) - attempt $i/$maxTries (~2.3GB)..."
  & $steam +force_install_dir $game +login anonymous +app_update 412680 -beta public validate +quit
  if (Test-Path $serverExe) { Write-Output 'Legacy server files present.'; break }
  Write-Output '(self-heal) app not installed yet - deleting steamapps and retrying in 10s...'
  if (Test-Path $steamApps) { Remove-Item -Recurse -Force $steamApps -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 10
}

$prereq = Join-Path $game 'Engine\Extras\Redist\en-us\UE4PrereqSetup_x64.exe'
if (Test-Path $prereq) {
  Write-Output 'Installing UE4 prerequisites (VC++ redistributables)...'
  Start-Process -FilePath $prereq -ArgumentList '/quiet','/norestart' -Wait
}

Write-Output 'Writing Primal startup wrapper (_primal\start-legacy.ps1)...'
[IO.File]::WriteAllBytes((Join-Path $prim 'start-legacy.ps1'), [Convert]::FromBase64String('__WRAPPER_B64__'))

if (Test-Path $serverExe) { Write-Output 'OK: Legacy server binary present.' } else { Write-Output 'WARNING: Legacy server binary NOT found - verify the install.' }
Write-Output 'Install complete.'
'''.replace("__WRAPPER_B64__", wrapper_b64)

def _v(name, env, default, rules, desc):
    return {"name": name, "description": desc or f"{name} (rendered into the Legacy Game.ini / launch each boot).",
            "env_variable": env, "default_value": default, "user_viewable": True,
            "user_editable": True, "rules": rules, "field_type": "text"}

egg = {
    "_comment": "PRIMAL HOSTED — The Isle: Legacy (UE4.25, app 412680 -beta public). Sibling of the Evrima egg; feathers/Windows node. Import via Nests -> Import Egg.",
    "meta": {"version": "PTDL_v2", "update_url": None},
    "exported_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
    "name": "The Isle: Legacy (Windows / feathers)",
    "author": "admin@primalhosted.com",
    "description": "The Isle LEGACY dedicated server (SteamCMD app 412680, branch public, UE4.25). Installs ONCE (frozen build, no updates). Every boot: renders the Legacy Game.ini (igamesession/GameSession/igamemode) + MOTD, syncs server mods (grouping-aware, install/uninstall), then launches Shipping directly with ?game={mode}?listen. Map: Isle_V3 / Thenyaw / TestLevel.",
    "features": None,
    "docker_images": {"Windows SteamCMD": "windows/steamcmd"},
    "file_denylist": [],
    "startup": "powershell -NoProfile -ExecutionPolicy Bypass -File _primal\\start-legacy.ps1",
    "config": {
        "files": "{}",
        "startup": "{\"done\": [\"Bringing World\", \"Match State Changed\", \"InProgress\"]}",
        "logs": "{}",
        "stop": "^C",
    },
    "scripts": {
        "installation": {
            "script": install,
            "container": "windows/steamcmd",
            "entrypoint": "powershell",
        }
    },
    "variables": [_v(*a) for a in [
        # (name, env, default, rules, desc)
        ("Server Name", "SERVER_NAME", "Primal Hosted - Legacy", "nullable|string|max:120", None),
        ("Max Players", "MAX_PLAYERS", "100", "required|integer|min:1|max:300", None),
        ("Game Mode", "GAME_MODE", "Survival", "required|string|in:Survival,Sandbox", None),
        ("Map", "MAP", "Isle_V3", "required|string|in:Isle_V3,Thenyaw,TestLevel", "Isle_V3 / Thenyaw / TestLevel"),
        ("Server Password", "SERVER_PASSWORD", "", "nullable|string|max:64", None),
        ("Admin Steam64 IDs", "ADMIN_STEAM_IDS", "", "nullable|string", "Comma-separated Steam64 IDs -> ServerAdmins"),
        ("Disabled Dinos", "DISABLED_DINOS", "", "nullable|string", "Comma-separated Character Classes to remove, e.g. UtahAdultS"),
        ("MOTD", "MOTD", "", "nullable|string|max:500", "Message of the day (empty = none)"),
        ("Allow Chat", "ALLOW_CHAT", "1", "required|string|in:0,1", None),
        ("Global Chat", "GLOBAL_CHAT", "1", "required|string|in:0,1", None),
        ("Name Tags", "NAME_TAGS", "1", "required|string|in:0,1", None),
        ("Growth", "GROWTH", "1", "required|string|in:0,1", None),
        ("Fall Damage", "FALL_DAMAGE", "1", "required|string|in:0,1", None),
        ("Turn In Place", "TURN_IN_PLACE", "1", "required|string|in:0,1", None),
        ("Allow Replay", "ALLOW_REPLAY", "1", "required|string|in:0,1", None),
        ("Dead Body Time (s)", "DEAD_BODY_TIME", "200", "required|integer|min:0", None),
        ("Respawn Time (s)", "RESPAWN_TIME", "30", "required|integer|min:0", None),
        ("Logout Time (s)", "LOGOUT_TIME", "60", "required|integer|min:0", None),
        ("Footprint Lifetime (s)", "FOOTPRINT_LIFETIME", "60", "required|integer|min:0", None),
        ("Nesting", "NESTING", "1", "required|string|in:0,1", None),
        ("Scent", "SCENT", "0", "required|string|in:0,1", None),
        ("Enable AI", "ENABLE_AI", "1", "required|string|in:0,1", None),
        ("AI Max", "AI_MAX", "100", "required|integer|min:0|max:500", None),
        ("AI Rate", "AI_RATE", "1.5", "required|numeric", None),
        ("AI Player Spawns", "AI_PLAYER_SPAWNS", "1", "required|string|in:0,1", None),
        ("Starting Time", "STARTING_TIME", "341", "required|integer|min:0|max:1440", None),
        ("Dynamic Time Of Day", "DYNAMIC_TIME", "0", "required|string|in:0,1", None),
        ("Day Length (min)", "DAY_LENGTH", "30", "required|integer|min:1", None),
        ("Grouping Mod", "GROUPING_MOD", "none", "required|string|in:none,universal,diet,herbie", "Mutually-exclusive grouping mod"),
        ("Enabled Mods", "ENABLED_MODS", "", "nullable|string", "CSV: UniversalDevColors,EnhancedPara,EnhancedAustro,EnhancedBary,ExtremeUtah,UtahGore,PachyBoneBreak,AnkyBonebreak"),
        ("Primal Mod (DLL)", "ENABLE_PRIMAL_MOD", "0", "required|string|in:0,1", "Install + inject the Primal DLL mod (version-checked from R2 each boot)"),
        ("Primal Mod Manifest", "PRIMAL_MOD_MANIFEST", "", "nullable|string", "Override the DLL manifest URL (blank = default R2 latest.json)"),
        ("Server Key (phsk_)", "PHSK_KEY", "", "nullable|string", "Per-server data-plane key — set automatically at provision time. The mod authenticates + fetches ONLY this server's commands with it."),
        ("Multihome IP", "MULTIHOME_IP", "", "nullable|string", "Opt-in: bind/advertise a specific public IP (per-server DDoS isolation). Blank = bind all interfaces (default). Test on a spare server first."),
    ]],
}

# Ops/infra variables the CUSTOMER must not see or edit (per-server key, mod controls,
# multihome IP). Pterodactyl has no partial-mask, so admin-only = fully hidden + locked
# in the customer UI; admin/AI still manage them from the panel admin area.
ADMIN_ONLY = {"PHSK_KEY", "ENABLE_PRIMAL_MOD", "PRIMAL_MOD_MANIFEST", "MULTIHOME_IP"}
for v in egg["variables"]:
    if v["env_variable"] in ADMIN_ONLY:
        v["user_viewable"] = False
        v["user_editable"] = False

out = here / "egg-isle-legacy.json"
out.write_text(json.dumps(egg, indent=4), encoding="utf-8")
print(f"wrote {out} ({out.stat().st_size} bytes)")
print(f"wrapper base64: {len(wrapper_b64)} chars")
print(f"install script: {len(install)} chars")
print(f"startup: {egg['startup']}")
print(f"done-regex: {egg['config']['startup']}")
print(f"variables: {[v['env_variable'] for v in egg['variables']]}")
