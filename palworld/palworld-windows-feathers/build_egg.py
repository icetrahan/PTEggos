#!/usr/bin/env python3
"""Build egg-palworld-windows-feathers.json from install.ps1 + start-palworld.ps1.

The wrapper is carried inside the install script as base64 and decoded to
_primal\\start-palworld.ps1 on install. base64 rather than a here-string because
the wrapper contains every quote character PowerShell cares about, and a
here-string that survives JSON escaping but not PS parsing fails at INSTALL time
on the box, where nobody is watching.

ASCII gate: PowerShell 5.1 on the feathers node decodes these scripts as CP1252.
Several multi-byte characters decode to byte 0x94, which PS treats as a quote -
enough of them and the script silently stops parsing. See BUGS #448. A non-ASCII
byte is a build failure here, not a runtime surprise there.
"""
import base64
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
INSTALL = HERE / "install.ps1"
WRAPPER = HERE / "start-palworld.ps1"
OUT = HERE / "egg-palworld-windows-feathers.json"

EXPORTED_AT = "2026-08-11T00:00:00+00:00"


def read_ascii(path: pathlib.Path) -> str:
    raw = path.read_bytes()
    bad = [(i, b) for i, b in enumerate(raw) if b > 0x7F]
    if bad:
        print(f"FAIL: {path.name} has {len(bad)} non-ASCII byte(s). See BUGS #448.")
        for i, b in bad[:10]:
            line = raw[:i].count(b"\n") + 1
            print(f"  line {line}, offset {i}: 0x{b:02X}")
        sys.exit(1)
    return raw.decode("ascii")


def main() -> None:
    install = read_ascii(INSTALL)
    wrapper = read_ascii(WRAPPER)

    b64 = base64.b64encode(wrapper.encode("ascii")).decode("ascii")
    chunks = [b64[i:i + 76] for i in range(0, len(b64), 76)]
    lines = ["'" + c + "'," for c in chunks]
    lines[-1] = lines[-1].rstrip(",")

    emit = "\n".join([
        "",
        "# --- write the supervisor wrapper -------------------------------------------",
        "# Emitted by build_egg.py from start-palworld.ps1. Do not hand-edit here; edit",
        "# the .ps1 in the repo and rebuild, or the two silently diverge.",
        "$wrapperB64 = @(",
        *["    " + ln for ln in lines],
        ") -join ''",
        "$wrapperPath = Join-Path $prim 'start-palworld.ps1'",
        "[System.IO.File]::WriteAllBytes($wrapperPath, [Convert]::FromBase64String($wrapperB64))",
        "if (-not (Test-Path $wrapperPath)) {",
        "    Fail-Install -Class 'WRAPPER_MISSING' `",
        "        -Summary 'The supervisor wrapper could not be written to _primal.' `",
        "        -WhatToDo @('Check the volume is writable, then reinstall.')",
        "}",
        "Write-Output ('Wrapper written: ' + $wrapperPath + ' (' + (Get-Item $wrapperPath).Length + ' B)')",
        "",
    ])

    # The wrapper must land BEFORE the verdict block exits 0 - an install that
    # reports success without the wrapper is exactly the #346 failure again.
    marker = "# --- verdict ---"
    if marker not in install:
        print("FAIL: verdict marker not found in install.ps1 - refusing to guess placement.")
        sys.exit(1)
    install = install.replace(marker, emit + marker, 1)

    egg = {
        "_comment": (
            "Primal - Palworld dedicated server for the feathers native-Windows node "
            "(node 2, win1.primalhosted.com). Windows because official Palworld mod "
            "loading is Windows-server-only. Lives outside isles/** on purpose: a push "
            "touching isles/** rebuilds four production ghcr images (BUGS #398)."
        ),
        "meta": {"version": "PTDL_v2", "update_url": None},
        "exported_at": EXPORTED_AT,
        "name": "Palworld (Windows / feathers)",
        "author": "admin@primalhosted.com",
        "description": (
            "Palworld dedicated server on the native-Windows feathers node. Supervises "
            "the real Shipping binary (UE servers self-detach), pumps Pal.log to the "
            "console, exposes RCON through the panel console, stops gracefully with a "
            "Save first, and supports the official Windows-only mod loader."
        ),
        "features": None,
        "docker_images": {"Windows SteamCMD": "windows/steamcmd"},
        "file_denylist": [],
        "startup": "powershell -NoProfile -ExecutionPolicy Bypass -File _primal\\start-palworld.ps1",
        "config": {
            # Structural readiness emitted by the wrapper itself once the game PID
            # actually holds the UDP port. NEVER a vendor log string - a reworded
            # vendor line is what made both OVH deathmatch boxes self-kill while UP.
            "files": "{}",
            "startup": '{\r\n    "done": "[PRIMAL] PALWORLD READY"\r\n}',
            "logs": "{}",
            "stop": "stop",
        },
        "scripts": {
            "installation": {
                "script": install,
                "container": "windows/steamcmd",
                "entrypoint": "powershell",
            }
        },
        "variables": [
            {
                "name": "Server Name",
                "description": "Shown in the Palworld server browser.",
                "env_variable": "SERVER_NAME",
                "default_value": "A Primal hosted Palworld server",
                "user_viewable": True, "user_editable": True,
                "rules": "required|string|max:64",
            },
            {
                "name": "Server Description",
                "description": "Shown under the server name in the browser.",
                "env_variable": "SERVER_DESCRIPTION",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|string|max:128",
            },
            {
                "name": "Admin Password",
                "description": (
                    "REQUIRED. Palworld refuses RCON without it, and this egg stops the "
                    "server over RCON so the world is saved first. An empty value fails "
                    "the boot on purpose rather than starting a server that cannot be "
                    "stopped cleanly."
                ),
                "env_variable": "ADMIN_PASSWORD",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "required|string|between:6,30",
            },
            {
                "name": "Server Password",
                "description": "Leave empty for an open server.",
                "env_variable": "SERVER_PASSWORD",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|string|between:1,30",
            },
            {
                "name": "Max Players",
                "description": "Palworld's own ceiling is 32.",
                "env_variable": "MAX_PLAYERS",
                "default_value": "32",
                "user_viewable": True, "user_editable": True,
                "rules": "required|numeric|between:1,32",
            },
            {
                "name": "Save Folder (DedicatedServerName)",
                "description": (
                    "Folder under Pal/Saved/SaveGames/0/ this server binds to. Leave EMPTY "
                    "to let the server generate a fresh world. Set it to an existing folder "
                    "name to adopt a migrated save - see MIGRATION.md."
                ),
                "env_variable": "SAVE_FOLDER",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|string|alpha_num|max:64",
            },
            {
                "name": "Public IP",
                "description": "Advertised address. Leave empty to auto-detect.",
                "env_variable": "PUBLIC_IP",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|string|max:64",
            },
            {
                "name": "Multihome (bind IP)",
                "description": (
                    "Bind the listen socket to ONE address on the box instead of every "
                    "interface. win1 carries eleven IPs; leave this empty and the server "
                    "answers on all of them. Must match the IP of the attached allocation."
                ),
                "env_variable": "MULTIHOME",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|ip",
            },
            {
                "name": "UE4SS Zip URL",
                "description": (
                    "Optional. Direct link to a UE4SS release zip whose ROOT holds "
                    "dwmapi.dll; fetched into Pal/Binaries/Win64 at install. Needed only "
                    "for Lua/Blueprint mods that must run server-side. Deliberately not "
                    "pinned in the egg: UE4SS rebuilds per game patch and a baked URL "
                    "rots into a silently-wrong version."
                ),
                "env_variable": "UE4SS_ZIP_URL",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|url|max:512",
            },
            {
                "name": "Public Lobby",
                "description": "1 = list in the community server browser, 0 = unlisted.",
                "env_variable": "PUBLIC_LOBBY",
                "default_value": "1",
                "user_viewable": True, "user_editable": True,
                "rules": "required|boolean",
            },
            {
                "name": "Auto Update",
                "description": "Run steamcmd app_update before every boot.",
                "env_variable": "AUTO_UPDATE",
                "default_value": "1",
                "user_viewable": True, "user_editable": True,
                "rules": "required|boolean",
            },
            {
                "name": "Enable Mods",
                "description": (
                    "1 writes Mods/PalModSettings.ini with bGlobalEnableMod=true. Mods only "
                    "load on Windows servers, and only if their Info.json InstallRule has "
                    "IsServer: true."
                ),
                "env_variable": "ENABLE_MODS",
                "default_value": "0",
                "user_viewable": True, "user_editable": True,
                "rules": "required|boolean",
            },
            {
                "name": "Active Mods",
                "description": (
                    "Comma separated PackageName values taken from each mod's Info.json - "
                    "NOT the folder names. Mods go in Mods/Workshop/<folder>/."
                ),
                "env_variable": "ACTIVE_MODS",
                "default_value": "",
                "user_viewable": True, "user_editable": True,
                "rules": "nullable|string|max:512",
            },
            {
                "name": "RCON Port (fallback)",
                "description": (
                    "Only used when no second allocation is attached. With one attached the "
                    "wrapper prefers SERVER_PORT_1. RCON is reached on loopback either way."
                ),
                "env_variable": "RCON_PORT",
                "default_value": "25575",
                "user_viewable": True, "user_editable": False,
                "rules": "required|numeric",
            },
            {
                "name": "Extra Launch Args",
                "description": "Appended verbatim to the command line. Leave empty unless you know why.",
                "env_variable": "EXTRA_ARGS",
                "default_value": "",
                "user_viewable": True, "user_editable": False,
                "rules": "nullable|string|max:256",
            },
        ],
    }

    OUT.write_text(json.dumps(egg, indent=4) + "\n", encoding="ascii")
    print(f"wrote {OUT.name}")
    print(f"  install script : {len(install):,} chars")
    print(f"  wrapper        : {len(wrapper):,} chars -> {len(b64):,} b64")
    print(f"  variables      : {len(egg['variables'])}")


if __name__ == "__main__":
    main()
