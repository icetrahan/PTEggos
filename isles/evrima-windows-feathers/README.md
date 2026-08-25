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
`ghcr.io/icetrahan/isles:{deathmatch,survival,legacy-survival,evrima-survival}`.
Those four are live images for the Linux eggs. Push deliberately.

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

None of the loose files are read from here by anything — `install.ps1` lives in the
panel DB, and it writes the other three from base64. They exist so a change is
diffable in review instead of being an 80,232-character opaque token. There are
**two levels of nesting**: the three blobs live inside `install.ps1`, which in turn
lives inside the JSON. `embed.py` walks both, `verify.py` gates both:

```bash
python isles/evrima-windows-feathers/embed.py     # after editing any loose file
python isles/evrima-windows-feathers/verify.py    # the gate
python isles/evrima-windows-feathers/gate_test.py # the install gate's own test
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

⚠️ **Do not hand-edit the base64 in the egg JSON.** Change the loose files, then:

```
python isles/evrima-windows-feathers/embed.py    # re-embed + refresh verify.py's sha
python isles/evrima-windows-feathers/verify.py   # the gate
```

sha256 of the committed wrapper: **`e1e5a5f90810547b34d284e84ddbb9e8e7c69ea2d3c2a73b4e4dc112efa4e26d`**
(61,364 B), recorded in `verify.py` as `WRAPPER_SHA` and refreshed by `embed.py`.
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
