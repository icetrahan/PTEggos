# win1 scaling: memory, port/IP layout, staggered restarts, reboot cadence

_Investigated 2026-07-14 with live data from both boxes._

## 1. The 8 GB (win1) vs 2 GB (OVH) "mystery" — SOLVED, and it's not what it looks like

Measured per-server memory, **resident (WorkingSet) vs committed (Private)**:

| Box | Server | WorkingSet (resident) | Private (committed) |
|---|---|---|---|
| **win1** (128 GB, 19 GB auto pagefile) | each Isle server | **~8,750 MB** | **~9,010 MB** |
| **OVH** (64 GB, **2 GB fixed** pagefile) | DM (11111) | 2,061 MB | **14,730 MB** |
| OVH | DryReef (9999) | 1,262 MB | 3,227 MB |
| OVH | Survival (8888) | 1,473 MB | **9,027 MB** |

**The "2 GB" on OVH is a lie of measurement.** Those servers actually *commit* 3–15 GB —
same ballpark as win1 (or more). Their **resident** set is small because Windows **trimmed
their working sets** after they sat idle for days (idle pages get reclaimed even with free
RAM). win1's servers were freshly restarted tonight, so their working sets are still fully
resident (~9 GB). Same server, same real footprint (~9 GB) — win1 just shows the honest
number, OVH shows the trimmed-idle number.

**Answers to your questions:**
- *"Is OVH better so they use less?"* No. Hardware quality doesn't change a UE server's
  memory need. OVH isn't using less — it commits the same/more, it just keeps less resident.
- *"Is it a setting limiting them?"* The only relevant setting is the **pagefile**, and OVH's
  is the *worse* config: fixed 2 GB, **100% used (2047/2048 MB)**, commit at 35 GB / 65.6 GB
  limit. If OVH load spiked, it would hit the commit limit and servers would crash with
  "paging file too small" — the exact error win1 hit earlier. So OVH's small pagefile is a
  latent risk, not an optimization. **Recommend raising OVH's pagefile too** (it's manually
  pinned at 2 GB).
- *"Should they be limited?"* No. Let UE servers use what they need. A hard cap below ~11 GB
  = OOM crash on boot (we saw it at 8 GB). win1's servers at 16 GB feature-limit + big
  pagefile + `oom_disabled` is right.
- *"Would they run better unlimited?"* win1 is effectively unlimited already (128 GB, big
  pagefile, fully resident) — that's the *best* case: zero page faults. OVH's trimmed servers
  would page-fault back in when a player joins (a small hitch). So win1 already runs *better*.

**Real number to plan with: ~9 GB committed idle, ~10.3 GB peak (boot). Budget ~10 GB/server.**

## 2. Density on win1 — the commit limit is the ceiling

- win1 **commit limit = 146.9 GB** (128 GB RAM + ~19 GB pagefile).
- 14 servers × ~10 GB ≈ **140 GB** — *fits*, but tight, and only because idle servers get
  trimmed. Simultaneous boot (all peaking 10 GB) ≈ 140 GB is dangerously close to 146.9 GB.
- **Action: pin a larger pagefile on win1** — set a fixed 48 GB pagefile → commit limit
  ~176 GB, comfortable headroom for 14 servers + OS + feathers + the backend services.
  (Auto-managed works but a fixed floor removes the "growing under pressure at the worst
  moment" risk.)

## 3. Port / IP layout (your spec: port-separated, 2 servers per IP, spare IPs for DDoS)

11 IPs total (1 primary + 10 secondary). Layout:

- **7 secondary IPs = "in use", 2 servers each = 14 servers.** Each IP runs two port blocks:
  - Block A: `7777` game / `7778` queue / `7779` rcon
  - Block B: `7780` game / `7781` queue / `7782` rcon
  - The two servers on one IP are port-separated (no collision); with the EOS override each
    advertises its own IP, so this is belt-and-suspenders safe.
- **3 secondary IPs + the primary = spares** held back for **DDoS hot-swap**: if a
  customer's IP gets null-routed, re-point their server (change its allocation) to a spare IP
  and it comes back on a clean IP. Keep these unallocated/clean.
- Firewall per in-use IP: `7777,7778,7780,7781` public; `7779,7782` (rcon) restricted to
  panel + backend + admin IPs.

> Note: you mentioned "14 *sets* of ports" (globally-unique blocks) — that's an even stricter
> option (blocks 7777-79 … 7816-18, never reused across IPs). It's not needed for correctness
> once the EOS override works, but if you want maximum paranoia we can switch to unique
> box-wide blocks. Current plan reuses A/B per IP, which is simpler and fully safe.

## 4. Staggered restart (don't let 15 servers demand ~10 GB each at once)

Simultaneous boot of 14 servers = ~140 GB peak commit = would blow the commit limit → OOM
cascade. So **do not let feathers cold-start them all at once.** Plan:

- Servers set to **not auto-start on boot**; a **staggered starter** brings them up in waves.
- `infra/staggered-start.ps1` (deployed to win1): starts servers **N at a time** (default 3),
  and only starts the next wave once the current wave each reports **"Session started
  succesfully!"** (or a timeout). 3 servers booting = ~30 GB peak — safe. 14 servers come up
  over ~5–8 minutes instead of all at once.
- Run it as a scheduled task **On Startup** (with a short delay so feathers/wings is up first).

## 5. Do you need to reboot the machine every Tuesday? — No.

- **Windows Server runs for months without a reboot.** There is no weekly-reboot requirement.
  Reboot the *machine* only for: (a) **Windows Updates** (Patch Tuesday is **monthly**, second
  Tuesday), or (b) an actual observed problem (driver, leak, instability).
- What game servers *do* benefit from is periodic **game-server** restarts (UE dedis slowly
  grow/heap-fragment over days; most Isle communities restart servers every 6–24 h for a fresh
  world). That's the *server process*, not the OS.
- **Recommended cadence:**
  - **Game servers:** restart on a rolling, staggered schedule (e.g., daily at low-pop hours,
    or per-community). Rolling = never all at once (reuse the staggered logic).
  - **Machine:** reboot ~monthly, right after Patch Tuesday updates, during a maintenance
    window. Announce it. After the reboot, the staggered starter brings servers back safely.
  - Between reboots, uptime of **30–45 days is totally fine** on Windows Server 2025.
- Don't do blanket "Tuesday reboots the whole box." Do monthly patched reboots + rolling
  daily server restarts.
