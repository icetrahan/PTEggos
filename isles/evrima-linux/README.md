# The Isle: Evrima (Linux / Primal) — the egg-40 surface on standard Wings

Built 2026-08-04 so Dino Vibes (and later Dry Reef) can move onto node 1
(`172.93.100.254`) — the only IP warphosting reliably ingests into the in-game
community list (BUGS #652). Reproduces everything egg 40
(`isles/evrima-windows-feathers`) does, on Linux.

| | |
|---|---|
| Startup | `bash _primal/start-evrima.sh` |
| Image | `ghcr.io/icetrahan/steamcmd:debian` (standard yolk: skips its own steamcmd when `SRCDS_APPID` is unset, then evals the panel STARTUP — that is how the wrapper gets control). It carries `python3` for the binary patcher (`steamcmd/debian/Dockerfile`) |
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
3. **SteamCMD** app 412680 `-beta evrima` validate. When Steam's evrima build
   differs from `_primal/primal-clean-build.txt` (the build last pulled clean), the
   boot pulls clean: `Binaries` set aside, `steamapps` deleted, files the pull does
   not bring back carried over, the previous build restored if the pull fails
   (A702, `test_cleanupdate.sh`). `FORCE_CLEAN_UPDATE=1` forces one; the
   stale-appmanifest self-heal stays (Steam-reachability-gated, #346).
4. **The stock binary, patched in place** by our pattern patcher; the Primal
   binary lane is the fallback — see below. Mandatory.
5. **Render `Game.ini`** from egg variables (defaults byte-matched to egg 40's;
   regenerated every boot, the customer edits variables, #356 T1(a)).
6. **Render `Engine.ini`** + the pak session block
   (`ApiToken`/`PollURL`/`ForceDinoList`/`BodySweep*` + `PRIMAL_MOD_INI`
   overrides), LF-only — a CR lands inside the token → 401 (#411/#436).
7. **Mod pak from R2** (`primal-mod-evrima-pak/latest.json`, stage → sha-verify
   every file → place atomically; never a partial triplet; fail-soft).
8. Confirm-startup report (best-effort), then `exec` the binary.

## 🔴 The binary: patched in place, the lane as fallback — vanilla is FORBIDDEN

**Ice's rule (2026-08-04): we cannot use the vanilla Linux binary.** The mod
needs two bytes changed at the engine's pak-signature gate. Every boot:

1. **Local patch (first).** The wrapper reads the Linux voice tool's manifest
   (`<R2>/primal-voice-linux-tool/latest.json`, the same one the panel's `/voice`
   Linux download serves), fetches `patch_worker.py` + `patches_linux.json`, checks
   each against the manifest's sha256 and keeps them in `_primal/patcher/` with
   that manifest. It runs the patcher on the binary SteamCMD just installed. The
   patterns find the two sites in any game build, so a game update needs no new
   binary from us. Exit 0 is not believed alone: the report must say `success`,
   the output must exist at the binary's size, and the installed file must read
   back as the patcher's output. A binary already in patched form is left as it
   is (nothing written). The boot says `binary: PATCHED LOCALLY (tool vN): <stock>
   -> <modded>` or `binary: already patched`, then asks the lane whether its own
   build for this vanilla is the same bytes (log only; it cannot stop the boot).
2. **The binary lane (fallback).** If the local patch cannot run (no `python3` in
   the image, no manifest and no kept copy, a sha256 mismatch, a build the
   patterns do not cover), the boot says `LOCAL PATCH NOT APPLIED - <why>` and
   does what it always did: `POST /commands/binary/check` at
   `binaries.primalhosted.com` (keyed on the stock md5) and installs the modded
   binary the lane serves — the same bytes, built upstream by the same patcher,
   but only for game builds the lane already holds.
3. **Refused.** If neither path gives a modded binary, the boot **fails loudly**
   (`MOD-BINARY-UNAVAILABLE`, naming the local reason too) instead of degrading — a
   vanilla boot would silently ship a server with no mod surface at all.
   `PRIMAL_ALLOW_VANILLA=1` exists for diagnostics only and shouts.

The kept copy is used only when R2 cannot be read, and only while it still
matches the manifest it came with. `PRIMAL_PATCHER_MANIFEST` (not an egg
variable) points the lookup elsewhere for off-box tests. `test_localpatch.sh`
runs this whole section against a stand-in patcher, R2 and lane (CI:
`verify-eggs`).

### A refused start is reported

Every exit that leaves the server down (`refuse` in `start-evrima.sh`: no modded
binary, no or a short game binary, a missing template) prints its `FATAL` line and
then tells the data plane with the server's own `PHSK_KEY`:
`POST {PRIMAL_DATA_BASE}/v1/boot-report` with `stage: "start"`, `ok: false`, a
`code` and the FATAL line as `reason`. The plane pages from that row
(`boot_refused:<server>`). The report is bounded (two tries, 10 s each) and the
log says whether it was `RECORDED` or `NOT reported`; a 200 counts only when its
body says `recorded: true`. The next boot that does launch sends `ok: true`, which
clears the page; `_primal/boot-refused.pending` is how it knows to. A server that
never refused sends nothing. `render_test.sh` section 4 is the proof, and its
pre-fix control is the wrapper before `refuse` existed.

### The sigbypass verdict (the question the session brief asked)

**No separate sigbypass artifact exists or is needed on Linux — the lane is
deliberately absent from this egg.** On Windows, egg 40 places `dsound.dll` +
`UniversalSigBypasser.asi` beside the exe or the engine refuses to mount our
unsigned `pakchunk50`. On Linux the equivalent is the two patched sites **inside
the binary**, applied by the wrapper itself (or pre-applied by the lane). Evidence:

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

## The game's own mass check (`PRIMAL_MASS_MIGRATION_TIME`, BUGS #3604)

No comm-ban DLL loads on this egg, so nothing here starts a mass migration of its
own: the game's own check is the only mass there is. It runs `MassMigrationTime`
after boot, 12 h by default. On a 12 h restart schedule it lands on the restart
itself: a run that lives a few seconds past 12 h starts a mass in its last moment,
the save keeps it, and the next run opens inside it with every sanctuary closed
for the whole run (#3600).

`PRIMAL_MASS_MIGRATION_TIME` is an ops-only egg variable (the customer can neither
see nor edit it). The wrapper writes it as the first line of
`[/script/theisle.tigamesession]`, replacing any other `MassMigrationTime` line:

| Value | Game.ini | Players get |
|---|---|---|
| `172800` (the egg default) | `MassMigrationTime=172800` | no mass migration: 48 h is above the longest daily restart gap (24 h), so every migration zone and sanctuary stays open all run |
| empty | no `MassMigrationTime` line | the game's own check at 12 h |
| another whole number, 86401 to 31536000 | that number | the game's check that long after boot |
| anything else | no line, and a `REFUSED` warning naming the value | the game's own check at 12 h |

Every boot says which, read back from the rendered file, never from the variable:

- `Game.ini: MassMigrationTime=172800 (PRIMAL_MASS_MIGRATION_TIME) - the game's own mass-migration check is 172800 s after boot`
- `Game.ini: MassMigrationTime left to the game (12 h) - PRIMAL_MASS_MIGRATION_TIME is empty`
- `WARN: PRIMAL_MASS_MIGRATION_TIME='…' REFUSED (want a whole number of seconds, 86401 to 31536000) - …`

The wrapper half ships with `publish_wrapper.py`; the variable reaches a server
only when the egg JSON is re-imported. A new wrapper on the old egg sees the
variable unset and says `left to the game`. `render_test.sh` section 4 and
`verify.py` gate 8 cover it.

### The fleet's two timing constants (BUGS #3631)

The wrapper also writes two constants into the same section on every boot, the
values egg 40 writes: `MassMigrationDisableTime=2700` (a mass migration lasts
45 min) and `IndividualPatrolTime=300` (a predator is handed a patrol zone every
5 min; the game's default is 20). They are fleet constants: no variable, no
owner field, and a line of either key already in the template is replaced.

- `Game.ini: MassMigrationDisableTime=2700 IndividualPatrolTime=300`, read back
  from the rendered file.
- `WARN: … NOT WRITTEN (no [/script/theisle.tigamesession] section) - …` when the
  template has no such section.

They need no egg import: the wrapper alone carries them. `verify.py` gate 9
holds the two eggs to the same values.

## Files

| File | What |
|---|---|
| `egg-evrima-linux.json` | PTDL_v2 egg, importable into the panel |
| `install.sh` | the install script (also embedded in the JSON), #346 fail-gate ported: exits 1 with a greppable class, never reports a dead install as complete |
| `start-evrima.sh` | the boot wrapper (also embedded in `install.sh` as base64) |
| `Game.ini.tmpl` / `Engine.ini.tmpl` | config templates (likewise embedded) |
| `embed.py` | puts the loose files back into install.sh + the egg JSON (the fixer). `embed.py --check` reports drift, writes nothing and exits 1 on drift |
| `embed_test.py` | proves `--check` never writes, on a copy of this folder |
| `test_localpatch.sh` | the binary section (local patch, lane fallback, refusals) against a stand-in patcher, R2 and lane |
| `test_multihome.sh` | the `MULTIHOME_IP` block: binds an address the container has; on a multi-IP node behind host SNAT (primal_hosted_data `ops/node-egress-snat.sh`) advertises the address only when an outside echo shows it is the egress |
| `verify.py` | proves loose files == blobs == egg JSON, parse + LF + secret + query-port gates, and that both Evrima wrappers' no-plane fallbacks equal the plane's defaults (gate 10) (the judge) |
| `publish_wrapper.py` | publishes wrapper+templates to the R2 self-update manifest |

Never hand-edit the blobs. Edit loose files → `embed.py` → `verify.py`.

## Provisioning notes

- `MULTIHOME_IP` (admin-only): leave empty on a single-IP node. On a multi-IP Linux node (eu1), set it to the
  server's allocation address only after the node runs `primalhosted-egress-snat`; the wrapper then advertises it
  (`EOS_OVERRIDE_HOST_IP`) once the container's egress reads that address, and warns otherwise (#4223).
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
