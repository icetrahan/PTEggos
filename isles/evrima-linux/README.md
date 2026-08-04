# The Isle: Evrima (Linux / Primal) — the egg-40 surface on standard Wings

Built 2026-08-04 so Dino Vibes (and later Dry Reef) can move onto node 1
(`172.93.100.254`) — the only IP warphosting reliably ingests into the in-game
community list (BUGS #652). Reproduces everything egg 40
(`isles/evrima-windows-feathers`) does, on Linux.

| | |
|---|---|
| Startup | `bash _primal/start-evrima.sh` |
| Image | `ghcr.io/icetrahan/steamcmd:debian` (standard yolk: skips its own steamcmd when `SRCDS_APPID` is unset, then evals the panel STARTUP — that is how the wrapper gets control) |
| Done string | `Session started succesfully!` (the EOS session line — the ingestion trigger) |
| Install container | `ghcr.io/parkervcp/installers:debian` |

## Which direction wins: **repo → panel** (the opposite of egg 40)

This egg was authored here first. Import `egg-evrima-linux.json` into the panel;
after that, **runtime changes ship through the R2 wrapper manifest**
(`primal-wrapper-evrima-linux/latest.json`, published with `publish_wrapper.py`),
NOT by re-importing the egg — the install script materialises `_primal/` exactly
once, and the self-update lane exists precisely so a wrapper change is a publish,
not a fleet walk (the lesson egg 40 learned the hard way, #435).

Editing files here still deploys nothing by itself. The full chain for a wrapper
change: edit loose file → `python embed.py` → `python verify.py` →
`python publish_wrapper.py --version N` (bumps the fleet at next boot) → commit.
Re-import the egg JSON only for variable/startup/install-script changes.

⚠️ `git push` on this repo rebuilds and re-pushes all four
`ghcr.io/icetrahan/isles:*` prod images (#398, fixed matrix in `isles.yml`).
This egg's images are NOT in that matrix — but push deliberately anyway.

## Boot sequence (`_primal/start-evrima.sh`)

1. **Wrapper self-update** from R2 (sha-verified, `bash -n` parse-gated,
   `.prev` rollback copy, `PRIMAL_WRAPPER_PIN` / `PRIMAL_WRAPPER_AUTOUPDATE=0`
   escape hatches; any failure boots the current version).
2. **Update gate** — `api.primalheaven.com/api/updates/server-status` (fail-open;
   needs `SERVER_ID` + `API_KEY`).
3. **SteamCMD** app 412680 `-beta evrima` validate, with `FORCE_CLEAN_UPDATE`
   and the stale-appmanifest self-heal (Steam-reachability-gated, #346).
4. **Modded Linux binary from the Primal API** — see below. Mandatory.
5. **Render `Game.ini`** from egg variables (defaults byte-matched to egg 40's;
   regenerated every boot, the customer edits variables, #356 T1(a)).
6. **Render `Engine.ini`** + the pak session block
   (`ApiToken`/`PollURL`/`ForceDinoList`/`BodySweep*` + `PRIMAL_MOD_INI`
   overrides), LF-only — a CR lands inside the token → 401 (#411/#436).
7. **Mod pak from R2** (`primal-mod-evrima-pak/latest.json`, stage → sha-verify
   every file → place atomically; never a partial triplet; fail-soft).
8. Confirm-startup report (best-effort), then `exec` the binary.

## 🔴 The binary: Primal Heaven API ONLY — vanilla is FORBIDDEN

**Ice's rule (2026-08-04): we cannot use the vanilla Linux binary.** Every boot
the wrapper asks `POST /commands/binary/check` (`platform:linux`, keyed on the
vanilla md5 that SteamCMD just produced) and installs the sha-verified modded
`TheIsleServer-Linux-Shipping` the backend serves. If the backend has no build
for today's vanilla hash the boot **fails loudly** (`MOD-BINARY-UNAVAILABLE`)
instead of degrading — a vanilla boot would silently ship a server with no mod
surface at all. `PRIMAL_ALLOW_VANILLA=1` exists for diagnostics only and shouts.

### The sigbypass verdict (the question the session brief asked)

**No separate sigbypass artifact exists or is needed on Linux — the lane is
deliberately absent from this egg.** On Windows, egg 40 places `dsound.dll` +
`UniversalSigBypasser.asi` beside the exe or the engine refuses to mount our
unsigned `pakchunk50`. On Linux the equivalent patch ships **inside the modded
binary** the Primal API serves. Evidence:

- The 2026-08-04 listing-test clone (`fc664bbc`, egg 17 lane on
  `testing:deathmatch`) booted `[PrimalMod] [BOOT] : BUILD 78 ... tokenlen=53`
  with the pak mounted — and that image's entrypoint downloads the API's modded
  binary before launch, so the mount was proven **on the modded binary**.
- Vanilla + our pak has never been tested on Linux, and per the rule above it
  never will be in production. If a diagnostic vanilla boot ever shows the pak
  mounting anyway, that changes nothing — the modded binary is mandatory for
  its own sake.

## 🔴 Query port == game port, BAKED

There is **no `QUERY_PORT` variable on this egg** — the wrapper always launches
`-QueryPort=$SERVER_PORT -Port=$SERVER_PORT` and renders `Game.ini`'s
`QueryPort` to the same value. Ice's rule from the warphosting listing work:
both working Linux references (Skin Creator 9999/9999, Dino Vibes 7777/7777)
agree, and the clone that split them stayed off the community list until
corrected. `verify.py` enforces this. `QUEUE_PORT` / `RCON_PORT` are admin
variables (standard Wings injects only `SERVER_PORT`; there are no
`SERVER_PORT_1/_2` here — that is a feathers-ism) defaulting to game+1 / game+2.

## The overlay is NOT supported here

Egg 40 honours `_primal/server-config.json` as an admin escape hatch and shouts
about every field it overrides. This egg does not apply it at all: egg variables
are the single source of truth (#356 T1(a), `FIELD_SPEC.md:49-51`), nothing on
the platform writes the overlay, and the image has no JSON parser — a homegrown
half-parser that could misread a field silently is worse than an honest refusal.
If the file exists the wrapper says so LOUDLY and applies nothing (rule 13).

## Files

| File | What |
|---|---|
| `egg-evrima-linux.json` | PTDL_v2 egg, importable into the panel |
| `install.sh` | the install script (also embedded in the JSON), #346 fail-gate ported: exits 1 with a greppable class, never reports a dead install as complete |
| `start-evrima.sh` | the boot wrapper (also embedded in `install.sh` as base64) |
| `Game.ini.tmpl` / `Engine.ini.tmpl` | config templates (likewise embedded) |
| `embed.py` | puts the loose files back into install.sh + the egg JSON (the fixer) |
| `verify.py` | proves loose files == blobs == egg JSON, parse + LF + secret + query-port gates (the judge) |
| `publish_wrapper.py` | publishes wrapper+templates to the R2 self-update manifest |

Never hand-edit the blobs. Edit loose files → `embed.py` → `verify.py`.

## Provisioning notes

- `PHSK_KEY`: ⚠️ **two servers on one phsk_ key split the command queue**
  (`/v1/commands/text` resolves the server from the token and the poll DRAINS
  the queue). Migrating an existing server onto this egg is a **stop-first
  cutover**, never a parallel run. Use a TEST key for any proving server.
- Rule 10: no secret ships in this egg — `PHSK_KEY`, `API_KEY`,
  `RCON_PASSWORD` all default empty; the wrapper's `CHANGEME` fallback is a
  placeholder `verify.py` pins. The EOS id/secret defaults are the game
  vendor's public dedicated-server pair, identical on every Isle server and
  already committed elsewhere in this repo.
- `SRCDS_APPID` must stay UNDEFINED on this egg — defining it would wake the
  image entrypoint's own steamcmd (no `-beta evrima` → a Legacy pull).
