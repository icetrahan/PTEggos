# Per-IP DDoS Isolation for The Isle (Evrima) — the `EOS_OVERRIDE_HOST_IP` fix

**TL;DR:** To run multiple Isle: Evrima servers on one box, each on its **own public IP**
(so a DDoS null-route on one server doesn't take down the others), you need **two** things,
not one:

1. `-MULTIHOME=<the server's IP>` — binds the game/queue sockets to that IP.
2. **`EOS_OVERRIDE_HOST_IP=<the same IP>`** as an **environment variable** — makes EOS
   *advertise* that IP to the server browser.

`-MULTIHOME` alone is **not enough** and is the trap everyone hits.

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
- Each server needs its `EOS_OVERRIDE_HOST_IP` and `-MULTIHOME` set to its own IP.

## Notes / gotchas

- It's an **environment variable**, not a `-flag`. Setting it as a CLI arg does nothing.
- Bind (`-MULTIHOME`) AND advertise (`EOS_OVERRIDE_HOST_IP`) must both point at the same IP.
- The EOS Client ID/Secret can stay the shared Isle dedicated values; this is orthogonal.
- Confirmed on Windows Server 2025 (Evrima 0.21.x) and matches behavior on an OVH box —
  it's a Redpoint EOS behavior, not host/provider specific.
