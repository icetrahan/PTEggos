# The Isle: Evrima (Windows / feathers) — egg 40

The egg every **Evrima server we host** runs on (Red's `93da0534`, the fixture
`9ef0f72e`). It runs on the native-Windows *feathers* node against the stock
`windows/steamcmd` image — there is **no Dockerfile here and nothing in this repo
builds it**.

| | |
|---|---|
| Panel | nest 6, egg **40**, uuid `b179ba1d-1c9d-4f98-9214-af631306341d` |
| Startup | `powershell -NoProfile -ExecutionPolicy Bypass -File _primal\start-evrima.ps1` |
| Image | `windows/steamcmd` (stock; not built from this repo) |
| Not on this egg | the mod box `fdff8b30` |

## ⚠️ Which direction wins: **panel → repo**

For the four Linux eggs in `isles/`, truth flows repo → ghcr → node. **Egg 40 is
the opposite.** It has no image to build, and the panel DB holds the only copy
the daemon ever reads. So:

- **The panel is authoritative at runtime. This folder is the reviewable record
  and the re-import source — editing files here deploys NOTHING.**
- A wrapper change ships by editing the panel, in **three** places, or it
  regresses:
  1. `_primal\start-evrima.ps1` on each live volume (existing servers), **and**
  2. the base64 blob inside the egg's install script (new provisions and
     reinstalls), **and**
  3. this folder, re-exported afterwards — see *Re-exporting* below.
- Steps 1 and 2 are the ones that go live. Step 3 is what stops this folder
  rotting into a lie.

An **install-script** change (`install.ps1`) is simpler — it ships in **one**
place, the panel's egg 40 *Install script* field — but it only takes effect on a
**new provision or a reinstall**. Existing volumes already ran the old one, so a
fix like #346 protects the next customer, not the servers already installed.

`git push` on this repo does not touch egg 40 — but it **does** trigger
`.github/workflows/isles.yml` on any `isles/**` change, which rebuilds and pushes
`ghcr.io/icetrahan/isles:{deathmatch,survival,legacy-survival}`.
Those three are the images the Linux eggs build from. Push deliberately.

## Files

| File | What |
|---|---|
| `egg-evrima-windows-feathers.json` | PTDL_v2 export of egg 40, importable into the panel |
| `install.ps1` | the **install script** (`scripts.installation.script`), extracted |
| `start-evrima.ps1` | the boot wrapper, extracted from the install script's base64 |
| `Game.ini.tmpl` / `Engine.ini.tmpl` | the two config templates, likewise extracted |
| `embed.py` | puts the loose files back into the egg JSON (the fixer) |
| `verify.py` | proves every extracted file matches what ships (the judge) |
| `gate_test.py` | drives `install.ps1`'s failure gate through 9 real states (#346) |
| `test_carryforward.ps1` | runs the wrapper's real hand-set pak key lines through 20 states (#1137, #3363) |
| `test_noinject.ps1` | runs the wrapper's real comm-ban "not injecting" lines and its report job against a local listener (#3499) |
| `test_bootreport.ps1` | runs the wrapper's real signature-bypass and server-binary lines; each failure reaches a local listener as a boot report (#4288) |
| `test_animalroster.ps1` | runs the whole wrapper in render-only mode against a local stand-in for the plane and reads the Engine.ini the game would read (A431) |
| `test_regionspawn.ps1` | the same render-only run for the three region spawning keys in Game.ini (A836) |

None of the loose files are read from here by anything — `install.ps1` lives in the
panel DB, and it writes the other three from base64. They exist so a change is
diffable in review instead of being an 80,232-character opaque token. There are
**two levels of nesting**: the three blobs live inside `install.ps1`, which in turn
lives inside the JSON. `embed.py` walks both, `verify.py` gates both:

```bash
python isles/evrima-windows-feathers/embed.py     # after editing any loose file
python isles/evrima-windows-feathers/verify.py    # the gate
python isles/evrima-windows-feathers/gate_test.py # the install gate's own test
powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_carryforward.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_animalroster.ps1
```

## 🔴 The install script must FAIL when there is no bootable binary (#346)

On 2026-07-28 this egg printed **`Install complete.`** and exited **0** after all
five steamcmd attempts failed at connect with no game files on disk. Red got a
permanently unbootable server that *reported success*. Ice made it an explicit
**customer-#3 onboarding gate**. Three defects produced it, all now fixed in
`install.ps1` and each **pinned by an assertion in `verify.py`** — a comment saying
"don't undo this" has already failed elsewhere in this workspace:

1. **No failing exit path.** The missing-exe branch logged
   `WARNING: TheIsleServer.exe NOT found` — it already knew the terminal state —
   then fell through to `Install complete.` and exit 0.
2. **⭐ It checked the wrong file.** `server\TheIsleServer.exe` is a **0.23 MB thin
   launcher**. The wrapper's own LAUNCH block says it deliberately does *not* run
   it, and instead launches
   `server\TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe`, throwing
   without it. Measured on live `93da0534` on 2026-07-30: **242,176 B vs
   185,213,952 B**, a 765× difference.
3. **The retry loop broke on that same wrong file.** The thin launcher lands in the
   first seconds of a ~70 GB pull, so the loop stopped retrying while the install
   had barely started — the five attempts were spent, not used.

The gate is now the binary the wrapper launches, and a failure exits 1 with a
greppable class: `NO-OUTBOUND`, `STEAM-UNREACHABLE`, `DNS-BROKEN`, `DISK-FULL`,
`STEAMCMD-FAILED`, `INCOMPLETE-PULL`, `TRUNCATED-BINARY`, `STEAMCMD-MISSING`.
`INCOMPLETE-PULL` is the exact state the old script called complete.

⚠️ **Why the classes matter, not just the exit code.** steamcmd is a native exe, so
its non-zero exit does **not** throw under `$ErrorActionPreference='Stop'` — which
is why five failures passed unnoticed. Nothing in the script now infers success
from the absence of an exception; the terminal gate reads the filesystem the
wrapper reads, and every non-success path names itself.

⛔ **This does NOT close #347.** `feathers` failing to notify the panel is a defect
in the Go Wings fork on win1, whose source is not in this workspace. When the box
has no outbound, the notify dies too and the panel stays wedged on *installing*
regardless of our exit code — so the `NO-OUTBOUND` message names that explicitly
and points at the live recovery (admin **Toggle Install Status → Reinstall**). That
is documentation of #347, not a fix for it.

The one-time cause on the day was **ReliableSite's DDoS mitigation false-positiving
on steamcmd's pull** and cutting the box's outbound. Protection is off on the box
until they fix detection; the egg must hard-fail regardless of the cause.

### Wasted egress, fixed with it

The old self-heal deleted `steamapps` from attempt 2 on **unconditionally**, so the
4.4 GB partial was re-fetched on every one of five attempts that could not reach
Steam at all. The self-heal now probes first and **announces the skip** when Steam
is unreachable — a partial download is only suspect if the pull could actually
reach Steam.

## Scrubbed values (rule 10)

The live export carries the RCON password literal in two places. Both are
replaced here and **nowhere else** — the committed wrapper differs from the live
one by exactly one line:

| Where | Live | Committed |
|---|---|---|
| `RCON_PASSWORD` variable default | *(the real value)* | `""` |
| `start-evrima.ps1` `RconPassword` fallback in the DEFAULTS block | *(the same literal)* | `'CHANGEME'` |

Restore both from `primal-credentials.env` before importing this egg for real use.

## Comm-ban DLL lane (`PRIMAL_COMMBAN`, 2026-09-18 — BACKLOG A38, DECISIONS 09-17 R5)

An ops-only egg variable (`user_viewable`/`user_editable` false, default **empty = off**).
`1` makes the wrapper place `commban.dll` into `TheIsle\Binaries\Win64` from the sha-pinned
R2 manifest `primal-commban/latest.json` (same shape as sigbypass: `{version, files:[{name,url,
sha256,size}]}`, re-verified every boot), write `commban.ini` beside it from the server's own
`PHSK_KEY` (`plane_base_url` / `server_key` / `server_id`), and arm a job that waits for THIS
boot's `Bringing World` line, sleeps 10 s, then `LoadLibraryW`-injects it. Result →
`_primal/primal-commban-inject.log`; the DLL's own verdict → `Win64\commban.log`
(`[COMMBAN BOOT] … state=ARMED|REFUSED at <gate>`) and its first heartbeat off-box.

- ⛔ **Independent of `ENABLE_PRIMAL_MOD`** by ruling — the pak lane's flag never arms an
  injector. ⛔ **Not the owner's switch**: that is the panel's comm-ban card, which the DLL
  reads from the plane on every poll. Placed + panel OFF = hooks nothing.
- Fail-soft everywhere: a bad sha, a missing key or a 404 manifest boots the server with
  **no injection** — and says so off-box by name (next section). `commban_silent` stays the
  backstop for a DLL that loaded and then went quiet.
- The bench harnesses that exercised the two blocks out of context live in
  `PrimalEverything/docs/audits/2026-09-17_commban-delivery/` (`egg_block_test.ps1` 19/19,
  `egg_inject_test.ps1` — the verbatim job armed the DLL on the isolated server).
- ⚠️ This egg has no CI matrix entry — it reaches the panel only by a **hand-import** of the
  JSON. ⚠️ Any push touching `isles/**` still rebuilds the 4 ghcr images (rule 5).

⚠️ **Do not hand-edit the base64 in the egg JSON.** Change the loose files, then:

```
python isles/evrima-windows-feathers/embed.py    # re-embed + refresh verify.py's sha
python isles/evrima-windows-feathers/verify.py   # the gate
```

sha256 of the committed wrapper: **`202bfd238a140e8393df4b66a991423cfd8ba810cbc7aa0b34f9f92e7f387db1`**
(111,903 B — the region spawning keys, A836), recorded in `verify.py` as `WRAPPER_SHA` and refreshed by `embed.py`.
⚠️ **This line was stale by two wrapper versions when it was corrected on 2026-08-12** (it still
named 46,224 B while the committed wrapper was 59,366 B). `embed.py` refreshes `verify.py` but
**not this README**, so the drift is silent and recurs — check the byte count against the file,
not just the prose, and re-read it whenever `verify.py` prints `-> update WRAPPER_SHA here and
the shas in README.md`.
The live wrapper differs by the one RCON line above, so its sha will not match —
that is expected, and `verify.py` compares the *committed* file only.

⚠️ The line references and shas in this section have gone stale twice (they still
named the pre-BUILD-39 28 KB wrapper as of 2026-07-29). Anchor on block names, not
line numbers, and let `embed.py` own the sha.

## An armed boot that does not inject says so (BUGS #3499)

With `PRIMAL_COMMBAN=1`, every branch that boots the game WITHOUT the DLL sets a code and a
reason, prints a banner, and posts them to the plane with the server's own key
(`POST /v1/boot-report`, `ok:false`, `attempts:0`, `skipped:<code>`). The post runs in a job
(`primal-commban-skip`), so a slow plane never holds the launch, and repeats every 60 s until the
plane answers: a 2xx, or a 4xx no retry can change.

| `skipped` | The boot did not inject because |
|---|---|
| `prepare_failed` | the manifest read, a download, a sha check or the ini write threw — the reason names the step and the error |
| `sha_mismatch` | a downloaded file failed its manifest sha256 |
| `dll_missing` | the manifest placed its files and `commban.dll` is still not on disk |
| `no_key` | `PHSK_KEY` is missing. ⛔ Not postable — there is no key to post with; the console and the history say so |

- The manifest read and each download are tried **3 times** (2 s, then 5 s apart) before a boot
  gives up on them.
- ⛔ `PRIMAL_COMMBAN` empty is **off, not a skip**: an unarmed server reports nothing.
- `_primal/primal-commban-history.log` keeps one line per boot (which way it went and why, the
  verify job's verdicts, the report's outcome), the last 200. ⛔ It is the only log here that
  survives a boot — `primal-commban-inject.log`, `primal-loader.log` and `wrapper-debug.log` are
  truncated at every start, so they answer for the current boot only.
- A plane that predates `skipped` records the same post as a failed inject (`reason` carries the
  code in words), so the wrapper and the plane can ship in either order.

`powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_noinject.ps1`
runs the wrapper's real lines through 13 boots and posts to a local listener over real HTTP (32 checks).

## A boot without the signature bypass, or without the server binary, reports it (BUGS #4288)

The pak mounts only with the bypass (`dsound.dll` + `UniversalSigBypasser.asi`) in place. A boot
that cannot place it still launches, unmodded, and now says so: a console banner and
`POST /v1/boot-report` with the server's own key, as the inject verdict the plane already reads:

| What happened | Body | Plane |
|---|---|---|
| manifest read or a download failed | `stage:"inject"`, `dll:"UniversalSigBypasser.asi"`, `ok:false`, `skipped:"prepare_failed"` | pages; one automatic restart re-fetches |
| a downloaded file failed its sha256 | same, `skipped:"sha_mismatch"`, the file named | pages at once (a restart reads the same file) |
| the next boot places it | same `dll`, `ok:true` | resolves |
| `TheIsleServer-Win64-Shipping.exe` missing | `stage:"start"`, `platform:"windows"`, `ok:false`, `code:"binary_missing"`, sent before the stop | `boot_refused` page |
| the next boot that launches | `stage:"start"`, `ok:true` | clears `boot_refused` |

- `primal-sigbypass.version` is written only when every file passed its sha256, and removed on any
  failure, so it never claims a version that is not on disk.
- The clearing reports are sent only after a failure (`_primal/primal-sigbypass-report.pending`,
  `_primal/boot-refused.pending`); a healthy boot sends nothing.
- The bypass report runs in a job like the comm-ban one (never holds the launch, repeats until the
  plane records it, stops on a 4xx). The refusal is sent in line, 3 tries, before the wrapper stops.
- Not covered: a bypass that is in place but no longer hooks a new game exe. That boot is
  unmodded with the files sha-verified; the off-box witness is the plane's `mod_absent_after_boot`
  with `OPS_MOD_ABSENT_SCOPE=all`.

`powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_bootreport.ps1`
(34 checks).

## Mass migration and patrol timing (BUGS #3328, #3362)

Ice's ruling: one mass migration per run, 15 minutes after every boot, started by `commban.dll`'s mass
rung (1.3.0+). The game's own mass check runs `MassMigrationTime` after boot, 12 h by default. On a
12 h restart schedule it lands on the restart itself: a run that lives a few seconds past 12 h starts a
mass in its last moment, the save keeps it, and the next run opens inside it (#3600). The Linux egg has
no DLL and parks the check with an egg variable instead (`isles/evrima-linux`, #3604).

The wrapper writes three `[/script/theisle.tigamesession]` keys into the rendered Game.ini:

| Key | Value | When |
|---|---|---|
| `MassMigrationDisableTime` | `2700` (45 min) | every boot |
| `IndividualPatrolTime` | `300` (a patrol zone handed out every 5 min, not 20) | every boot |
| `MassMigrationTime` | `172800` (48 h, above every restart gap, so the game's own check never fires) | only when THIS boot loads a commban.dll whose manifest version is 1.3.0 or newer |

⛔ `MassMigrationTime` must never be parked on a server whose DLL does not start the mass: that server
would never get one. The game also requires T > 1.1 × D, or a mass never ends; `test_masstiming.ps1`
asserts both.

A mass that is running at a restart comes back from the save with no end timer. The DLL replaces it at
+15 min (`[MASS] … loaded from the last run's save … replacing it`); without the DLL it stays open until
the game's own next check.

Every boot says which way it went:

- `(config) Game.ini: MassMigrationDisableTime=2700 IndividualPatrolTime=300`
- `(config) Game.ini: MassMigrationTime=172800 - commban v<x> starts this run's mass itself`, or
  `(config) Game.ini: MassMigrationTime left to the game (12 h) - no commban mass rung this boot (...)`
- the DLL's own `[MASS]` lines in `Win64\commban.log` (`started at +<s> s … zone=…`, `ended by …`, or
  `SKIPPED` / `FAILED` / `NO SEAM` with the reason).

`powershell -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_masstiming.ps1` runs the
real lines lifted from the wrapper (42 checks).

## 🔴 ASCII ONLY in `start-evrima.ps1` **and `install.ps1`**

The wrapper is UTF-8 **without a BOM**, so PowerShell 5.1 on the feathers node
decodes it as CP1252. Several multi-byte characters (`—`, `🔴`, `⛔`) decode to
byte `0x94`, which PowerShell treats as a **quote character** — enough of them and
the script stops parsing, which means the server does not boot. Adding five emoji
to comments broke it exactly this way on 2026-07-29 (BUGS #448).

⛔ Keep comments and strings inside this file to plain ASCII. Before committing:

```
powershell -NoProfile -Command "$e=$null; [System.Management.Automation.Language.Parser]::ParseFile('isles/evrima-windows-feathers/start-evrima.ps1',[ref]$null,[ref]$e); $e"
```

Silence means it parses. Do the same for `install.ps1` — it runs on the same node
under the same decode. `verify.py` now enforces the ASCII half of this for both
files automatically; the parse check above is still a manual step.

(The remaining files in this directory are not executed by PowerShell and are
unaffected.)

Swept clean for `phsk_` / `phdk_` / `ptlc_` / `ptla_` values — the two `phsk_`
hits are the *name* of the `PHSK_KEY` variable ("Server Key (phsk_)"), whose
default is empty.

**Deliberately kept:** `Engine.ini.tmpl` carries The Isle's public EOS
`DedicatedServerClientId`/`Secret`. Those are the game vendor's, identical on
every Isle server, already committed twice elsewhere in this repo
(`isles/deathmatch/entrypoint.sh`, `testing/deathmatch/entrypoint.sh`), and
required verbatim to boot. Blanking them would also break the byte-equality
`verify.py` checks.

## Hand-set pak keys survive a clean exit (#1137, #3363)

The wrapper rewrites the pak's `BP_TIGameSession_C` section of `Engine.ini` on every boot and
carries forward any key in it that the wrapper does not own (an operator's `IrisCensusEvery`,
`WireVersion`, `TestKit`...). A clean game exit **deletes**
`Saved/Config/WindowsServer/Engine.ini` (lab-proven: RCON `exit` deleted it every time; a hard
kill never does). So the live file is not the only source:

- `_primal/engine-carry.ini` holds the last known hand-set keys. It is written at every render,
  and by the supervise loop the moment the live file changes while the server runs. It never
  holds an owned key, so never the `ApiToken`.
- The copy is read **only** when the live file, or its pak section, is missing. A live file wins,
  so an operator who deletes a key line has cleared it.
- Every boot prints one line naming the source. Grep the console for these:

| Console line starts | Meaning |
|---|---|
| `(config) Engine.ini: carried forward N hand-set pak key(s) (#1137/#1071)` | read from the live file |
| `(config) Engine.ini: carry-forward ran, no hand-set pak keys present` | live file, nothing hand-set |
| `(config) Engine.ini is MISSING at boot ... from _primal/engine-carry.ini` | a clean exit deleted it; keys came from the copy |
| `(config) Engine.ini has no pak section ... from _primal/engine-carry.ini` | a mod-off boot or a hand-rewritten file; keys came from the copy |
| `... and there is no _primal/engine-carry.ini` | nothing to carry from (first boot, or keys set before this change shipped) |
| `(config) Engine.ini changed while running - saved N ...` | an edit made mid-run is kept for the next boot |

⚠️ On feathers the panel's `^C` stop is **not** a clean exit: winproc's `Stop` terminates the job
object for every stop type except a console command, so a restart is a hard kill and the live file
survives. The copy covers the exits that are clean: an RCON or console `exit`, the game quitting
by itself, or a future daemon that sends a real Ctrl+C.

## `AnimalRoster` is the panel's pick (A431)

Play as an animal: the owner picks the animals in the panel. The plane serves the pick as ONE csv
string, `mod_settings.animalRoster` in `/v1/boot-config`, and only while animals are picked. The
wrapper writes it into the pak section as `AnimalRoster=<csv>`, byte for byte. The pak reads the
key at boot, so a change applies at the server's next restart.

- No field, or an empty one: no line, and the game's own roster stands.
- The wrapper **owns** the key. A hand-set `AnimalRoster` line is not carried forward; the animals
  are set in the panel.
- The wrapper holds no list of animals. The plane's write gate decides which animals are offered.
  The wrapper only refuses a value that is not a plain comma-separated list of names (a line break
  in it would inject an Engine.ini line), and then it renders no line at all.
- With the plane unreachable, the boot-config cache renders the last fetched pick.

Every boot with the mod on prints one line:

| Console line starts | Meaning |
|---|---|
| `(config) Engine.ini: AnimalRoster Boar,Deer (the panel's pick)` | the line was written |
| `(config) Engine.ini: AnimalRoster not rendered - this boot's config carries no animal pick` | no line |
| `(config) Engine.ini: AnimalRoster SKIPPED - the plane's value (length N) is not a plain ...` | the value was refused, no line |

`test_animalroster.ps1` runs the real wrapper through 39 checks of the above.
⚠️ The Linux egg (`evrima-linux`) does not write this key.

## `PRIMAL_FORCE_DINO` (id 296)

Per-server species force-enable, shipped 2026-07-29 on Ice's order. Empty ⇒ the
flag is omitted entirely; non-empty ⇒ `-PrimalForceDino=<csv>` is appended to the
launch line (wrapper lines 347–355).

`user_viewable 1` / `user_editable 0` — **admin-only on purpose.** A customer
typing `Compsognathus` or `Pterodactylus` crashes the client and bricks the
character (live-proven 2026-07-26). Exposing it in the panel needs a species
allowlist guard designed first.

⚠️ Per mod bug **#387**, `-PrimalForceDino=A,B` silently enables only `A` — the
roster push republishes `AllowedClasses` from `AvailableClasses`, so forcing the
second species wipes the first. Treat the variable as single-species until #387
lands.

## Verifying the flag actually reached the command line

Only provable at boot. The wrapper prints, when the variable is non-empty:

```
(start) PrimalForceDino=<csv> (force-enabled species)
```

No such line ⇒ the variable was empty or never reached the process. As of
2026-07-29 `93da0534` is under Ice's **NO-BOOT hold**, so this is unverified on
the live server by design — it is on the boot-runway checklist, not skipped.

## Re-exporting

```bash
curl -H "Authorization: Bearer $PTERO_APPLICATION_API_KEY" -H "Accept: application/json" \
  "$PTERO_APPLICATION_API_URL/api/application/nests/6/eggs/40?include=variables"
```

Then rebuild this folder from that payload — **never hand-edit the base64.**
Decode the blob, scrub at the byte level, re-encode, and splice it back through a
real JSON parser (read the object, set `scripts.installation.script`, write it
back); a string splice through PowerShell corrupts the JSON. Finish by running
`verify.py`.

Two fields are not exposed by the application API and are reconstructed here:
`features` (read as `null` off the client API's `egg_features` for a server on
this egg) and `field_type` (always `text`). `config.*` are re-serialised from the
API's decoded objects back into the raw JSON strings the export format uses.
