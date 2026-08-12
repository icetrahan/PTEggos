# Per-IP DDoS Isolation for The Isle (Evrima) — `EOS_OVERRIDE_HOST_IP` + `-MULTIHOMEHTTP`

**TL;DR:** To run multiple Isle: Evrima servers on one box, each on its **own public IP**
(so a DDoS null-route on one server doesn't take down the others), you need **THREE** things,
not one — and, since 0.21.78x, not two either:

1. **bind** — `-MULTIHOME=<the server's IP>` — binds the game/queue sockets to that IP.
2. **advertise** — **`EOS_OVERRIDE_HOST_IP=<the same IP>`** as an **environment variable** —
   makes EOS *advertise* that IP to the server browser.
3. **egress** — **`-MULTIHOMEHTTP=<the same IP>`** — sources UE's outbound HTTP from that IP.

`-MULTIHOME` alone is **not enough** and is the trap everyone hits. ⛔ **And since The Isle
0.21.78x, legs 1+2 alone are not enough either** — see the section below. All three take the
**same** IP; leg 3 is *added to* the other two, never instead of them.

⚠️ **This document said "two things" until 2026-08-12 and that is why #1281 happened.** Legs
1+2 make a server *joinable* on a secondary IP, which is what every earlier test measured — so
"multihome works" was true for joins and false for the browser listing at the same time.

---

## Why `-MULTIHOME` alone silently fails

The Isle uses the Redpoint EOS Online Subsystem for its server browser. When a client
clicks your server, EOS hands it an address to connect to, and The Isle's queue system
then connects to `<that IP>:<QueuePort>`.

`-MULTIHOME=<secondaryIP>` correctly **binds** the server's sockets to the secondary IP —
you can confirm the server is listening there. **But EOS ignores the multihome bind and
advertises the box's PRIMARY egress IP anyway.** So the client connects to
`primary:queueport`, where your server isn't listening, and the join just hangs
(you'll see the client's TCP connection stuck in `SynSent`).

This is observable from both ends:
- **Server log:** `LogNet: Created socket for bind address: <secondaryIP>:7777` ✅ (bound right)
- **Client log:** `LogTheIsleNetwork: Queue: connecting to queue socket <PRIMARY_IP>:7778` ❌ (wrong IP)

Things that look like fixes but **do not** work (all tested):
- `?MultiHome=` in the map URL vs `-MULTIHOME=` flag — no difference to advertisement.
- `-PublicIPAddress=<ip>` as a command-line arg — ignored.
- `__EOS_OverrideAddressBound=<ip>` env var — internal flag, not the address override.
- Toggling the NIC's `SkipAsSource` on the secondary IP — no effect on advertisement.
- "Separated ports so the client falls through primary→secondary" — there is no
  fallthrough; the client dials the advertised (primary) IP directly and hangs.

## The fix: `EOS_OVERRIDE_HOST_IP`

The Redpoint EOS plugin reads an **environment variable** `EOS_OVERRIDE_HOST_IP`. Set it to
the IP you want EOS to advertise (feeds `EOS_SessionModification_SetHostAddress` internally).
It's undocumented — found by scanning the shipping server binary for the string cluster
`EOS_OVERRIDE_HOST_IP` / `__EOS_OverrideAddressBound` / `EOS_IGNORE_ORCHESTRATOR_PORT`.

Set it **in the server process's environment** (not a command-line arg), equal to the same
IP you multihome to:

```bat
set EOS_OVERRIDE_HOST_IP=104.243.46.71
TheIsleServer-Win64-Shipping.exe -MULTIHOME=104.243.46.71 /Game/TheIsle/Maps/Game/Gateway/Gateway?Port=7777 -log ^
  -ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=... ^
  -ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=...
```

PowerShell:
```powershell
$env:EOS_OVERRIDE_HOST_IP = '104.243.46.71'
& $exe -MULTIHOME=104.243.46.71 "/Game/TheIsle/Maps/Game/Gateway/Gateway?Port=7777" -log -ini:... -ini:...
```

**Proof it works** — client log after the fix:
```
LogTheIsleNetwork: Display: Queue: connecting to queue socket 104.243.46.71:7781
```
The secondary IP, finally. Client spawns in normally.

## Verifying it yourself (no anti-cheat risk — don't attach a debugger)

Watch which IP your CLIENT actually dials, two safe ways:

- **Client log** (`%LOCALAPPDATA%\TheIsle\Saved\Logs\TheIsle.log`), tail it live:
  ```powershell
  Get-Content "$env:LOCALAPPDATA\TheIsle\Saved\Logs\TheIsle.log" -Wait -Tail 0 |
    Select-String 'Queue: connecting to queue socket|Browse Started Browse'
  ```
- **OS network view** — watch the client process's TCP connections; the queue port
  connection reveals the IP:
  ```powershell
  $p = Get-Process TheIsleClient-Win64-Shipping
  Get-NetTCPConnection -OwningProcess $p.Id | ? RemotePort -in 7778,7781 | ft RemoteAddress,RemotePort,State
  ```

## Multi-server layout (per-IP + wraparound)

- **1 server per IP** using the same ports on each (e.g. `7777` game / `7778` queue /
  `7779` rcon) — that's fine because each server is on a different IP. Just make sure the
  primary IP has nothing on those ports if you don't put a server there.
- **When you run out of IPs, wrap around**: put a *second* server on each IP using a new
  port block (`7780/7781/7782`, then `7783/7784/7785`, …). Same IP, different ports, still
  isolated per-IP for the IPs you have.
- Each server needs its `EOS_OVERRIDE_HOST_IP`, `-MULTIHOME` and `-MULTIHOMEHTTP` set to its own IP.

---

## The third leg: `-MULTIHOMEHTTP` (0.21.78x runtime telemetry) — #1281

The Isle 0.21.78x posts runtime telemetry to warphosting every 10 s. In **community mode**
(any server with no `RUNTIME_UPDATE_KEY` — i.e. every server we run) warphosting authenticates
the reporter by matching the **source IP of that POST** against the **IP the EOS session
advertises**. Legs 1 and 2 do not move outbound HTTP, so on a multihomed box the POST still
egresses from the box's primary IP and warphosting refuses it:

```
LogTheIsleNetwork: Warning: Runtime update failed (HTTP 403):
  {"detail":"Community runtime reporter is not trusted for this session"}
```

⚠️ Note it is **403 "not trusted"**, not the 404 `Community session not found` the same binary
can emit — warphosting *knows* the session and is rejecting the reporter. **The server is never
listed in the in-game server browser**, forever, while remaining perfectly joinable by direct
connect. Measured: 45 failures in 8 minutes, one every 10 s, first at boot+20 s, never a success.

`-MULTIHOMEHTTP=<ip>` is UE's own knob for that leg: it parses into `FCurlHttpManager`'s
`CurlRequestOptions.LocalHostAddr` (= `CURLOPT_INTERFACE`). It is a **separate parse** from the
socket subsystem's `MULTIHOME=`, which is exactly why the two can disagree.

**Blast radius (measured, not assumed):** it moves UE's **HTTP module** traffic only. The EOS SDK
carries its own HTTP stack and keeps using the box's default source, so EOS and Steam are
unaffected. Our pak mod *does* ride UE's HTTP module, but the data plane is Cloudflare-fronted and
authenticates by `phsk_` bearer token, so source IP is not load-bearing there.

🟢 **Safe on single-IP and primary-IP servers**: binding HTTP to the address the OS would have
chosen anyway is a no-op, proven by a primary-IP regression arm (0 × 403).

⚠️ **Note on `SkipAsSource`:** win1's ten secondary IPs are all `SkipAsSource=True`, which is
correct and deliberate — it is what pins the box's egress with ten addresses on one NIC. It
suppresses only *automatic* source selection; an explicit `bind()` (which is what
`-MULTIHOMEHTTP` does) egresses fine. **The network was never at fault.**

⭐ **The better fix, if we can get it:** managed mode. `RUNTIME_UPDATE_KEY` (sent as
`X-Runtime-Key`) + `SERVER_ID` + `RUNTIME_UPDATE_URL` bypass the source-IP check entirely. Ask
WarpHosting for a managed runtime key — it is provider-level, IP-independent, and needs no
wrapper change at all. ⛔ Untested; we have no key.

## Notes / gotchas

- `EOS_OVERRIDE_HOST_IP` is an **environment variable**, not a `-flag`. Setting it as a CLI arg
  does nothing. `-MULTIHOME` and `-MULTIHOMEHTTP` are the opposite — CLI flags, not env vars.
- Bind (`-MULTIHOME`), advertise (`EOS_OVERRIDE_HOST_IP`) and egress (`-MULTIHOMEHTTP`) must all
  point at the same IP.
- **How to tell which leg is broken:** joinable but not listed ⇒ leg 3 (look for the 403 above).
  Listed but clients dial the wrong IP ⇒ leg 2. Nothing binds ⇒ leg 1.
- The EOS Client ID/Secret can stay the shared Isle dedicated values; this is orthogonal.
- Confirmed on Windows Server 2025 (Evrima 0.21.x) and matches behavior on an OVH box —
  it's a Redpoint EOS behavior, not host/provider specific.
