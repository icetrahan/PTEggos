# Palworld (Windows / feathers)

Palworld dedicated server for the **native-Windows feathers node** — node 2,
`win1.primalhosted.com` (`199.127.62.3`).

## Why Windows

Official Palworld mod loading is **Windows-server-only**. A Linux Palworld server
gets pak mods and PalSchema and nothing else; UE4SS needs Proton or a community
Linux port, both finicky. Since we already run a native-Windows Wings fork, the
Windows build is the honest answer rather than the fought-for one.

## Why this lives outside `isles/**`

A push touching `isles/**` rebuilds **four production ghcr images** regardless of
what actually changed (workspace BUGS **#398**). This egg is not an Isle and has
no container to build, so it sits in its own top-level `palworld/` directory,
which no workflow watches. Confirmed against `.github/workflows/*.yml`: the
triggers are `isles/**`, `steamcmd/**`, `testing/**` and `testing/signoz/**`.

> ⚠️ **PTEggos is a PUBLIC repo.** No live credential may ever be a default here.
> `ADMIN_PASSWORD` ships empty and the server refuses to boot without one.

## Files

| File | What |
|---|---|
| `install.ps1` | SteamCMD pull of app `2394010`, scaffolding, and the install gate |
| `start-palworld.ps1` | Supervisor wrapper: config render, launch, log pump, RCON, stop |
| `build_egg.py` | Embeds the wrapper into the install script (base64) and emits the egg JSON |
| `verify.py` | Pre-import gate — run it after every build |
| `egg-palworld-windows-feathers.json` | **Generated.** Do not hand-edit |

Edit the `.ps1` files, then:

```bash
python build_egg.py && python verify.py
```

`verify.py` parses both scripts with the real PowerShell parser and proves the
base64 wrapper embedded in the egg is byte-identical to `start-palworld.ps1`. A
rebuilt egg silently carrying a stale wrapper is the readback-is-not-evidence
failure — the file on disk looks right, the thing that ships is old.

## ASCII ONLY

Same constraint as the Evrima egg. PowerShell 5.1 on the feathers node decodes
these scripts as CP1252, and several multi-byte characters decode to byte `0x94`,
which PS treats as a quote — enough of them and the script stops parsing. See
workspace BUGS **#448**. `build_egg.py` fails the build on any non-ASCII byte
rather than letting it surprise you on the box.

## Design notes, each earned somewhere

**The install gate is the binary the wrapper launches.** `server\PalServer.exe` is
a thin launcher that lands early in the pull; the wrapper never touches it. The
gate is `server\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe`, and a failed
install exits `1` with a class (`NO_OUTBOUND`, `NO_DNS`, `DISK_FULL`,
`STEAM_NO_FILES`, `PARTIAL_PULL`, `WRAPPER_MISSING`). Nothing infers success from
the absence of an exception — steamcmd is a native exe whose non-zero exit does
not throw under `$ErrorActionPreference='Stop'`. Hard rule 13 / BUGS **#346**.

**Readiness is structural, never a vendor log string.** The wrapper polls
`netstat` until the game PID actually holds the UDP port, then prints its own
`[PRIMAL] PALWORLD READY`, and *that* is the egg's done-string. Gating on a
vendor phrase is what made both OVH deathmatch boxes self-kill while UP after a
patch reworded their ready line.

**The wrapper supervises a real PID.** UE dedicated servers self-detach — `& $exe`
returns in milliseconds while the server keeps running, and feathers would mark
the server stopped. It waits on the process and pumps `Pal\Saved\Logs\Pal.log`
to the console, handling rotation and truncation.

**Config is merged, never replaced.** Palworld keeps every world option in one
`OptionSettings=(...)` list. The wrapper owns nine keys (name, description,
passwords, ports, player cap, RCON) and **carries every other key forward
untouched**. A wrapper that re-emits only its own keys silently resets rates,
difficulty and breeding to stock. Same rule as the Evrima egg (**#1137**).

**Stop saves first.** `config.stop` is `stop`, which the wrapper turns into RCON
`Save`, a pause, then `Shutdown 1`, with a 60s grace before it kills. Palworld
rolls back to its last autosave on an ungraceful kill. `ADMIN_PASSWORD` is
`required` for exactly this reason — Palworld refuses RCON without one, so an
empty value fails the boot rather than producing a server that cannot stop
cleanly.

Any other line typed into the panel console is forwarded to RCON, so
`ShowPlayers`, `Broadcast <msg>` and `KickPlayer <steamid>` work from the panel.

## Ports

Primary allocation = the game port (UDP, Palworld default 8211). If a **second**
allocation is attached the wrapper uses it for RCON (`SERVER_PORT_1`); otherwise
RCON falls back to `25575` on loopback, which is all the wrapper itself needs.

## Mods

Set `ENABLE_MODS=1` and list mod **`PackageName`** values — from each mod's
`Info.json`, *not* the folder names — in `ACTIVE_MODS`, comma separated. The
wrapper writes `Mods/PalModSettings.ini` with `bGlobalEnableMod=true` and one
`+ActiveModList=` line per entry. Mod folders go in `Mods/Workshop/<folder>/`
with `Info.json` directly inside.

A mod only runs server-side if its `Info.json` `InstallRule` contains
`"IsServer": true`. Mods that change **assets** (Pals, models, textures, UI) must
also be installed by every client; mods that change **numbers** (rates, spawns,
loot) are server-side only.

If mod folders are present but `ACTIVE_MODS` is empty the wrapper says so loudly
rather than booting a vanilla server that looks modded.

## Migrating a single-player / co-op save

The host's player file in a local save is the placeholder UID
`00000000000000000000000000000001`. A dedicated server keys your character to a
UID derived from your Steam ID, so an untouched upload loads the world, bases and
Pals but leaves **your** character orphaned — you spawn fresh at level 1.

1. Back the local save up first. This server has `backups: 0`, so the panel
   cannot snapshot it for you.
2. Upload the world folder to `Pal/Saved/SaveGames/0/<folder>/`.
3. Boot with `SAVE_FOLDER` **empty**, join once, stop. Your new UID is the new
   `<hex>.sav` filename in that world's `Players/`.
4. Run [`palworld-host-save-fix`](https://github.com/xNul/palworld-host-save-fix):
   ```
   python -m pip install palworld-save-tools==0.17.1
   python fix_host_save.py "<save>" <new_uid> 00000000000000000000000000000001 False
   ```
   The trailing `False` is the guild fix — it stays `False` for a co-op migration.
5. **Delete `WorldOption.sav`** from the uploaded folder. If it is present the
   server obeys it and ignores `PalWorldSettings.ini`, freezing your world
   settings at whatever single-player had.
6. Set `SAVE_FOLDER` to the world folder name and boot.

Known quirk from the tool's own docs: if a Pal misbehaves after the fix, drop it
and pick it back up once.
