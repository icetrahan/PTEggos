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

`git push` on this repo does not touch egg 40 — but it **does** trigger
`.github/workflows/isles.yml` on any `isles/**` change, which rebuilds and pushes
`ghcr.io/icetrahan/isles:{deathmatch,survival,legacy-survival,evrima-survival}`.
Those four are live images for the Linux eggs. Push deliberately.

## Files

| File | What |
|---|---|
| `egg-evrima-windows-feathers.json` | PTDL_v2 export of egg 40, importable into the panel |
| `start-evrima.ps1` | the boot wrapper, extracted from the install script's base64 |
| `Game.ini.tmpl` / `Engine.ini.tmpl` | the two config templates, likewise extracted |
| `verify.py` | proves each extracted file is byte-identical to its embedded blob |

The three loose files are **not** read from here by anything — the install script
writes them from base64. They exist so a wrapper change is diffable in review
instead of being a 37,872-character opaque token. `verify.py` is what keeps the
two representations from drifting:

```bash
python isles/evrima-windows-feathers/verify.py
```

## Scrubbed values (rule 10)

The live export carries the RCON password literal in two places. Both are
replaced here and **nowhere else** — the committed wrapper differs from the live
one by exactly one line:

| Where | Live | Committed |
|---|---|---|
| `RCON_PASSWORD` variable default | *(the real value)* | `""` |
| `start-evrima.ps1` line 56 `RconPassword` fallback | *(the same literal)* | `'CHANGEME'` |

Restore both from `primal-credentials.env` before importing this egg for real
use. sha256 of the wrapper: live `03479537eced420aa0f5a2317c3e41d63139f940ebcda04794e39d0c1d194cbf`
(28,403 B) → committed `2c1a8aa395d0ff017fa1fd1c940d2d73f21c9f3ae2a177071ef6ce2b8a4c8c51`
(28,396 B).

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
