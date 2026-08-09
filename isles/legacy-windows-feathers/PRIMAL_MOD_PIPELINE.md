# Primal DLL Mod — Deployment Pipeline

How the Primal server-side DLL mod gets from a build on your machine onto every
game server that has it enabled. **Both Isle variants use the identical pipeline**,
differing only in DLL name, config filename, and R2 manifest key:

| | Legacy | Evrima |
| --- | --- | --- |
| DLL | `LegacyMod.dll` | `IsleModRebuild.dll` |
| config file (beside DLL) | `legacy_anticheat.cfg` | `isle_mod.ini` |
| R2 manifest | `primal-mod/latest.json` | `primal-mod-evrima/latest.json` |
| publish | `isle_mod_legacy/publish_dll.py` | `isle_mod_rebuild/publish_dll.py` |
| wrapper | `isle_legacy_egg/_primal/start-legacy.ps1` | `isle_evrima_egg/_primal/start-evrima.ps1` |
| egg builder | `build_egg.py` | `build_egg40_update.py` |

The pipeline is **built end-to-end for both mods**. Legacy delivery is proven; the
only step left is the final live test (§5) — inject + command-fetch against a
running server with the finished DLL. Below, examples use Legacy paths; swap in the
Evrima column for the Evrima server.

```
  build LegacyMod.dll                 (mod session — isle_mod_legacy)
        │  publish_dll.py --version X.Y.Z
        ▼
  R2: primal-legacy-mods/primal-mod/           (versioned artifact + manifest)
    ├─ LegacyMod-X.Y.Z.dll
    └─ latest.json  { version, dll_url, sha256, size }
        │  (served at pub-…​.r2.dev/primal-mod/latest.json)
        ▼
  Legacy egg wrapper  _primal/start-legacy.ps1   (every server boot)
    1. ENABLE_PRIMAL_MOD=1?  → fetch latest.json
    2. version != local?     → download dll_url, verify sha256, pin version
    3. arm injector job      → wait for TheIsleServer process, LoadLibraryW-inject
        ▼
  Server runs with the mod loaded.
```

Nothing here touches the OVH box (135.148.52.82). The DLL is hosted in Cloudflare
R2 and pulled by the servers themselves.

---

## 1. One-time setup (already done)

- **R2 bucket**: `primal-legacy-mods` (public via the managed `pub-fb6…​.r2.dev`
  domain, shared with the Legacy pak mods).
- **Manifest key**: `primal-mod/latest.json`. **DLL keys**: `primal-mod/LegacyMod-<version>.dll`.
- **Egg var**: `ENABLE_PRIMAL_MOD` (0/1) + optional `PRIMAL_MOD_MANIFEST` URL
  override, in egg 41 (Isle Legacy). Rebuild with `python build_egg.py`.
- **Panel toggle**: "Primal mod" in the server config **Mods** group
  (`ServerConsole.tsx`), which writes `ENABLE_PRIMAL_MOD`.
- **Wrapper logic**: download-by-version + sha256 verify + injector job, in
  `_primal/start-legacy.ps1`.

## 2. Publishing a new DLL version  ← the "get it there" step

From `isle_mod_legacy/` after building the DLL:

```bash
python publish_dll.py --version 0.2.0 --notes "adds proximity chat positions"
# --dll defaults to build/LegacyMod.dll
```

This uploads `LegacyMod-0.2.0.dll` to R2 and rewrites `latest.json` (with the new
version + sha256). Requires `wrangler` and `CLOUDFLARE_API_TOKEN` /
`CLOUDFLARE_ACCOUNT_ID` (auto-read from the Primal secrets store if unset).

Evrima is identical from `isle_mod_rebuild/` (writes the `primal-mod-evrima/`
manifest, so it versions independently of Legacy):

```bash
python publish_dll.py --version 0.1.0   # --dll defaults to build/IsleModRebuild.dll
```

> ✅ **Evrima go-live DONE (2026-07-10):** `IsleModRebuild.dll` **v0.1.0** is built +
> published; `primal-mod-evrima/latest.json` is live and the download+sha256 path is
> verified end-to-end. `ENABLE_PRIMAL_MOD=1` Evrima servers install+inject on restart.
> Bump `--version` and re-publish for each new build.

Use **semver** and bump every publish — the wrapper keys re-downloads off the
version string, so a new build under the same version will NOT roll out.

## 3. How it reaches servers

On the next **restart** of any Legacy server with `ENABLE_PRIMAL_MOD=1`, the
wrapper fetches `latest.json`, compares `version` to its local
`_primal/primal-mod.version`, and if different downloads the DLL, verifies its
sha256, pins the new version, and injects it after the server process comes up.
Servers already on the current version do nothing (no re-download).

To push an update to a live fleet: publish (§2), then restart the servers (panel
power → restart, or the panel bulk action).

## 4. Enabling it on a server

Panel → server → **Config → Mods → Primal mod** (toggle on) → save → restart.
Under the hood that sets `ENABLE_PRIMAL_MOD=1`. Off by default.

## 4b. Per-server command routing (multi-server isolation)

A customer with several servers (e.g. 2 Evrima + 1 Legacy) gets **one `phsk_` key per
server**, and the data plane scopes every command queue by `serverId` — so each
server only ever polls **its own** commands. That isolation is enforced in the
backend (`server_commands WHERE server_id = …`), not by convention.

Delivery of the key is now automatic:
- Both eggs carry a `PHSK_KEY` variable (set at provision time, not by the customer).
- `syncServerKeyToPanel()` in `primal_billing/lib/provisioning.ts` pushes the minted
  key into the server's env on **provision**, on **/admin/keys → Mint**, and on
  **key rotation** — no manual paste.
- The Legacy wrapper renders `_primal/legacy_anticheat.cfg` from `PHSK_KEY` each boot
  with `command_poll_url=<data>/v1/commands`, `command_key`/`license_key=<phsk_>`,
  `rt_base_url`, `server_id`. The URL is identical for all servers; the **key** is
  what scopes it per-server (backend resolves key → serverId; no ids in the URL).

✅ **Both mod-side reconciliations RESOLVED (2026-07-10):**
1. `LegacyMod.dll` now resolves its config **beside the DLL** via `resolve_paths()`
   (`GetModuleFileNameW` → module dir → `legacy_anticheat.cfg`), matching where the
   wrapper writes it. The old hardcoded `C:\Users\admin\Desktop\TestLegacy\…` path is
   gone. (Evrima's `IsleModRebuild.dll` already read `module_directory()/isle_mod.ini`.)
2. `MOD_CONTRACT.md` reconciled to the code: canonical auth key is `bearer_token`
   (Legacy aliases it to `license_key`; `command_key` defaults to it). Config files
   documented per mod (`isle_mod.ini` Evrima / `legacy_anticheat.cfg` Legacy); the
   phantom `server_key=`/`api_base` keys were removed. Wrapper matches code.

## 5. Remaining step — the last bit of testing

The **delivery** half is verified (see `test_dll_pipeline.ps1`: fresh download,
sha256 verify, version pin, no-op re-run, version-change re-download, missing-DLL
self-heal — all green against live R2). What still needs a live run:

1. **Inject actually loads the DLL** — enable the mod on the test Legacy server,
   restart, and confirm `_primal/primal-inject.log` shows
   `inject call complete` and the DLL's own logging shows it initialized.
2. **Command-fetch contract** — confirm the mod polls/receives commands from the
   backend as designed (this contract comes from the mod session; wire the poll
   URL/key into the wrapper env or the DLL config once finalized).

When those two pass with the finished DLL, bump to `1.0.0`, publish, and flip the
default. No pipeline changes needed.

## 6. Troubleshooting

| Symptom | Check |
| --- | --- |
| Mod didn't update | Did you bump `--version`? Same version = no re-download. |
| `sha256 MISMATCH` in boot log | Re-run `publish_dll.py` (partial/corrupt upload); the wrapper discards the bad file and keeps the old one. |
| No inject | `_primal/primal-inject.log` — "no server process appeared" (server never started) vs. an API failure line. |
| Want to pin/rollback | Re-publish the older DLL under a new higher version, or point one server at a pinned manifest via `PRIMAL_MOD_MANIFEST`. |

## 7. Files

**Legacy:**
- `isle_mod_legacy/publish_dll.py` — publish a version to R2 + `primal-mod/` manifest.
- `isle_legacy_egg/_primal/start-legacy.ps1` — download + verify + inject (search `primal-mod`).
- `isle_legacy_egg/build_egg.py` — egg vars `ENABLE_PRIMAL_MOD`, `PRIMAL_MOD_MANIFEST`.
- `isle_legacy_egg/test_dll_pipeline.ps1` — delivery synth test.

**Evrima:**
- `isle_mod_rebuild/publish_dll.py` — publish a version to R2 + `primal-mod-evrima/` manifest.
- `isle_evrima_egg/_primal/start-evrima.ps1` — download + verify + inject (search `primal-mod`).
- `isle_evrima_egg/build_egg40_update.py` — egg vars `ENABLE_PRIMAL_MOD`, `PRIMAL_MOD_MANIFEST`, `PHSK_KEY`.

**Shared:**
- `primal_billing/app/panel/servers/[id]/ServerConsole.tsx` — panel toggle → `ENABLE_PRIMAL_MOD`.
- `primal_billing/lib/provisioning.ts` `syncServerKeyToPanel()` — pushes `PHSK_KEY` to server env.
