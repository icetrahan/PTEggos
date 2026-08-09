# The Isle: Legacy — Windows / feathers egg (source)

The Windows-node Legacy egg (`"The Isle: Legacy (Windows / feathers)"`), sibling of
`isles/evrima-windows-feathers/`. Legacy = SteamCMD app **412680**, branch `public`
(UE 4.25.4) — **install once, never update**; the build is frozen.

⚠️ **Not built by CI.** Like `evrima-windows-feathers/` and `evrima-linux/`, this egg has
no `Dockerfile` and no entry in the `isles.yml` matrix — it runs on a native-Windows
Wings node, not in a container. Nothing here is published by a push; the egg JSON is
imported into the panel by hand.

## Provenance

Imported **2026-08-09** (bug **#1063**) from `C:\CodingC\PrimalEverything\isle_legacy_egg`,
which was **not a git repo and not tracked by the meta repo** — every file below had
**zero history and zero backup coverage** (BackupSync snapshots *repos*). Nine of these
filenames existed nowhere in PTEggos.

| file | what |
|---|---|
| `start-legacy.ps1` | the boot wrapper — renders `Game.ini` from egg variables |
| `build_egg.py` | builds `egg-isle-legacy.json` |
| `egg-isle-legacy.json` | the panel egg |
| `PRIMAL_MOD_PIPELINE.md` | the mod/pak pipeline notes |
| `test_mods.py`, `test_dll_pipeline.ps1` | pipeline tests |

## ⛔ Deliberately NOT imported

1. **76 `.pak`/`.sig` mod binaries (~84 MB).** They do not belong in a 2.3 MB repo that
   CI checks out on every build. They live in the source folder and need an R2/blob home,
   **not git** — tracked as **#1065**.
2. **Rendered runtime state** — `server/TheIsle/Saved/**` (`Game.ini`, `MOTD.txt`). That is
   *output*, not source; it is re-rendered from egg variables every boot.

⭐ **This repo is PUBLIC.** Every file here passed an explicit secret gate before import
(no `phsk_`/`phdk_`/`ptlc_`/live passwords). Keep it that way: defaults for any credential
variable are `""` — **never a live value**. See **#1064** for the one that had to be
sanitised on the Evrima side.
