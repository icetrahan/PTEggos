# primal-loader — the game loads its own Primal DLLs (A230)

**Why.** A Windows Isle server used to get its DLL (`LegacyMod.dll`, Evrima's `commban.dll`) from a
PowerShell job that found the game's process from outside and `CreateRemoteThread`-injected it. That
outside step failed two different ways in two days, and each time a server ran for hours without its mod:

- 2026-09-24: it picked ANOTHER server's pid (#2700);
- 2026-09-25: it refused the RIGHT pid, because feathers runs the game as `pt_<volume>` (#2724).

**What.** Both server exes (Legacy UE4.25 and Evrima UE5) statically import `DSOUND.dll`.
Ultimate ASI Loader, renamed `dsound.dll` and placed beside the exe, loads every `*.asi` in that
directory when the process starts. It is the same sha-pinned binary (`f4abc8a2…`) that the Evrima
sigbypass lane has run on every Windows Evrima server since 2026-08.

`primal-loader.asi` therefore runs **inside this server's own process, on every start** (crash
restarts included). That makes three failures impossible:

- it cannot be in the wrong process;
- it needs no rights over anyone else's process;
- there is no one-shot job that can give up.

On its own thread, it:

1. reads `primal-loader.ini` beside itself (the wrapper rewrites it every boot);
2. waits for **this boot's** world line in `TheIsle.log`:
   - `LogWorld: Bringing World` or `to LoadMap(` (a live Evrima log has only the second, #2551);
   - the log must have been written after this process started, so a previous boot's log never counts;
3. waits `settle_s` (10 s), then `LoadLibraryW`s each `load=` path and verifies it by module handle;
4. retries a failed load `retries` times, every `retry_s`;
5. logs every decision to `log=` (`_primal/primal-loader.log`). Every outcome names itself: `NOTHING TO LOAD`, `NOT LOADED: the world never came up`, `LOADED`, `FAILED`.

It does no networking. The wrapper's verify+heal job is the second line of defense:

- it confirms the DLL from the process's module list;
- it injects if the DLL is absent;
- it never stops retrying while the process lives;
- it re-injects if the DLL disappears;
- it reports to the plane.

**Files.**

| file | what |
|---|---|
| `primal_loader.cpp` | the loader (one file, kernel32 only, `/MT` so it needs no VC runtime) |
| `build.bat` | `build\primal-loader.asi` (x64, VS 2022). `set EXTRA=/DLOADER_MUTANT_NO_STALE_GUARD` builds the harness mutant |
| `publish_loader.py` | R2 `primal-loader/<ver>/` + `latest.json` (sha-pinned; refuses a dirty tree; reads back from the public URL) |
| `test/test_loader.ps1` | 7 cases against the REAL UAL `dsound.dll` + a stand-in exe that imports DSOUND. The mutant fails 2 of them |

**ini keys.**

| key | meaning |
|---|---|
| `log` | where the loader logs |
| `world_log` | the game log it watches |
| `world_match` | a world-up substring; repeatable |
| `world_timeout_s` | how long to wait for the world |
| `settle_s` | wait after the world line before loading |
| `retry_s` | seconds between retries of a failed load |
| `retries` | how many retries |
| `load` | a DLL path to load; repeatable |

**Off means off.** The wrapper *removes* `primal-loader.asi` + `.ini` when the mod is disabled
(`ENABLE_PRIMAL_MOD != 1` / comm-ban not ready / `PRIMAL_LOADER=0`). `dsound.dll` alone loads nothing.
