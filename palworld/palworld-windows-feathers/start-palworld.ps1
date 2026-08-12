# Primal - Palworld dedicated server wrapper (feathers / native-Windows node 2).
#
# ASCII ONLY - see install.ps1 header and BUGS #448.
#
# Why a wrapper at all: UE dedicated servers SELF-DETACH. "& $exe" returns in
# milliseconds while the real process keeps running, so feathers would see the
# egg command exit and mark the server stopped. This supervises the real PID,
# pumps Pal.log to the console, and owns stop.
#
# READINESS IS STRUCTURAL, NEVER A VENDOR LOG STRING. This prints its own
# [PRIMAL] ready line only once the game process actually holds the UDP port,
# and that line is the egg's done-string. Gating on a vendor phrase is what
# killed both OVH deathmatch boxes when a patch reworded their ready line -
# they self-killed while UP. See memory dm-readyline-vendor-log-gate.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$game = Join-Path $root 'server'
$sc   = Join-Path $root 'steamcmd'
$exe  = Join-Path $game 'Pal\Binaries\Win64\PalServer-Win64-Shipping.exe'
$cfgDir  = Join-Path $game 'Pal\Saved\Config\WindowsServer'
$logFile = Join-Path $game 'Pal\Saved\Logs\Pal.log'
$modsDir = Join-Path $game 'Mods'
$APPID = '2394010'

function Say { param([string]$m) Write-Output ('[PRIMAL] ' + $m) }

function Env-Or {
    param([string]$Name, [string]$Fallback = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Fallback }
    return $v.Trim()
}
function Env-Bool {
    param([string]$Name, [bool]$Fallback = $false)
    $v = (Env-Or $Name '').ToLower()
    if ($v -eq '') { return $Fallback }
    return @('1','true','yes','on') -contains $v
}

# --- inputs -----------------------------------------------------------------
$gamePort   = [int](Env-Or 'SERVER_PORT' '8211')
# feathers exposes additional allocations as SERVER_PORT_1, SERVER_PORT_2, ...
# RCON gets its own allocation when one is attached; otherwise it stays loopback
# on the default and is simply not reachable from outside, which is fine - the
# only RCON client that matters is this wrapper.
$rconPort   = [int](Env-Or 'SERVER_PORT_1' (Env-Or 'RCON_PORT' '25575'))
$serverName = Env-Or 'SERVER_NAME' 'A Primal hosted Palworld server'
$serverDesc = Env-Or 'SERVER_DESCRIPTION' ''
$maxPlayers = [int](Env-Or 'MAX_PLAYERS' '32')
$adminPass  = Env-Or 'ADMIN_PASSWORD' ''
$serverPass = Env-Or 'SERVER_PASSWORD' ''
$publicIp   = Env-Or 'PUBLIC_IP' ''
$multihome  = Env-Or 'MULTIHOME' ''
$saveFolder = Env-Or 'SAVE_FOLDER' ''
$autoUpdate = Env-Bool 'AUTO_UPDATE' $true
$publicLobby= Env-Bool 'PUBLIC_LOBBY' $true
$enableMods = Env-Bool 'ENABLE_MODS' $false
$activeMods = Env-Or 'ACTIVE_MODS' ''
$extraArgs  = Env-Or 'EXTRA_ARGS' ''

if ([string]::IsNullOrWhiteSpace($adminPass)) {
    Say 'FATAL: ADMIN_PASSWORD is empty. Palworld refuses RCON without it, so this'
    Say 'wrapper could neither send commands nor stop the server gracefully.'
    Say 'Set ADMIN_PASSWORD in the panel Startup tab and boot again.'
    exit 1
}

# --- optional update on boot ------------------------------------------------
if ($autoUpdate) {
    $steam = Join-Path $sc 'steamcmd.exe'
    if (Test-Path $steam) {
        Say 'AUTO_UPDATE is on - running app_update before boot...'
        & $steam +force_install_dir $game +login anonymous +app_update $APPID +quit | Out-Host
        Say ('steamcmd update exit code: ' + $LASTEXITCODE)
    } else {
        Say 'AUTO_UPDATE is on but steamcmd.exe is absent - skipping the update.'
    }
}

if (-not (Test-Path $exe)) {
    Say ('FATAL: ' + $exe + ' is missing.')
    Say 'Reinstall the server. Do NOT trust a previous "Install complete." line -'
    Say 'the install gate is this exact file.'
    exit 1
}

# ---------------------------------------------------------------------------
# PalWorldSettings.ini
#
# Palworld stores every world option inside ONE parenthesised OptionSettings=(...)
# list. We own a handful of keys (name, ports, passwords, player cap); everything
# else - rates, difficulty, breeding, whatever the operator tuned in-game or by
# hand - is CARRIED FORWARD untouched. A wrapper that re-emits only its own keys
# silently resets the rest to stock. Same rule as the Evrima egg (#1137).
# ---------------------------------------------------------------------------
function Parse-OptionSettings {
    param([string]$Text)
    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $map }
    $buf = ''; $depth = 0; $inQuote = $false; $parts = @()
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; $buf += $ch; continue }
        if (-not $inQuote) {
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') { $depth-- }
            elseif ($ch -eq ',' -and $depth -eq 0) { $parts += $buf; $buf = ''; continue }
        }
        $buf += $ch
    }
    if ($buf.Trim() -ne '') { $parts += $buf }
    foreach ($p in $parts) {
        $i = $p.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $p.Substring(0, $i).Trim()
        $v = $p.Substring($i + 1).Trim()
        if ($k -ne '') { $map[$k] = $v }
    }
    return $map
}

function Q { param([string]$s) return '"' + ($s -replace '"', '') + '"' }

$settingsPath = Join-Path $cfgDir 'PalWorldSettings.ini'
$defaultsPath = Join-Path $game 'DefaultPalWorldSettings.ini'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

$sourceText = ''
if ((Test-Path $settingsPath) -and ((Get-Item $settingsPath).Length -gt 0)) {
    $sourceText = Get-Content -Path $settingsPath -Raw
    Say 'Reading existing PalWorldSettings.ini (operator values are preserved).'
} elseif (Test-Path $defaultsPath) {
    $sourceText = Get-Content -Path $defaultsPath -Raw
    Say 'No PalWorldSettings.ini yet - seeding from DefaultPalWorldSettings.ini.'
} else {
    Say 'WARNING: neither PalWorldSettings.ini nor DefaultPalWorldSettings.ini found.'
    Say 'Writing a minimal settings file with only the keys this wrapper owns.'
}

$optRaw = ''
$m = [regex]::Match($sourceText, 'OptionSettings\s*=\s*\((?<body>.*)\)\s*$', 'Singleline,Multiline')
if ($m.Success) { $optRaw = $m.Groups['body'].Value }
$opts = Parse-OptionSettings $optRaw
$carried = $opts.Count

# the keys this wrapper owns - everything else above is left exactly as found
$opts['ServerName']        = Q $serverName
$opts['ServerDescription'] = Q $serverDesc
$opts['AdminPassword']     = Q $adminPass
$opts['ServerPassword']    = Q $serverPass
$opts['PublicPort']        = "$gamePort"
# With MULTIHOME set, the socket binds to that IP - so the address advertised to
# the server browser must be that IP too, or players are handed one the server is
# not listening on. An explicit PUBLIC_IP still wins.
$advertiseIp = if (-not [string]::IsNullOrWhiteSpace($publicIp)) { $publicIp } else { $multihome }
$opts['PublicIP']          = Q $advertiseIp
$opts['ServerPlayerMaxNum']= "$maxPlayers"
$opts['RCONEnabled']       = 'True'
$opts['RCONPort']          = "$rconPort"

$pairs = @()
foreach ($k in $opts.Keys) { $pairs += ($k + '=' + $opts[$k]) }
$ini = @(
    '[/Script/Pal.PalGameWorldSettings]',
    ('OptionSettings=(' + ($pairs -join ',') + ')')
) -join "`r`n"
[System.IO.File]::WriteAllText($settingsPath, $ini + "`r`n", (New-Object System.Text.ASCIIEncoding))
Say ('PalWorldSettings.ini written - ' + $carried + ' keys carried forward, 9 owned by the panel.')

# --- GameUserSettings.ini / DedicatedServerName ------------------------------
# This is what binds the server to a save folder under Pal\Saved\SaveGames\0\.
# Leave SAVE_FOLDER empty and the server picks its own random folder on first boot.
if (-not [string]::IsNullOrWhiteSpace($saveFolder)) {
    $gusPath = Join-Path $cfgDir 'GameUserSettings.ini'
    $gus = ''
    if (Test-Path $gusPath) { $gus = Get-Content -Path $gusPath -Raw }
    if ($gus -match '(?m)^\s*DedicatedServerName\s*=.*$') {
        $gus = [regex]::Replace($gus, '(?m)^\s*DedicatedServerName\s*=.*$', ('DedicatedServerName=' + $saveFolder))
    } elseif ($gus -match '(?m)^\s*\[/Script/Pal\.PalGameLocalSettings\]\s*$') {
        $gus = [regex]::Replace($gus, '(?m)^(\s*\[/Script/Pal\.PalGameLocalSettings\]\s*)$', ("`$1`r`nDedicatedServerName=" + $saveFolder))
    } else {
        $gus = $gus.TrimEnd() + "`r`n[/Script/Pal.PalGameLocalSettings]`r`nDedicatedServerName=" + $saveFolder + "`r`n"
    }
    [System.IO.File]::WriteAllText($gusPath, $gus, (New-Object System.Text.ASCIIEncoding))
    Say ('DedicatedServerName = ' + $saveFolder)
    $savePath = Join-Path $game ('Pal\Saved\SaveGames\0\' + $saveFolder)
    if (-not (Test-Path $savePath)) {
        Say ('NOTE: ' + $saveFolder + ' does not exist under SaveGames\0 yet - the server will create a NEW world there.')
    }
}

# --- mods -------------------------------------------------------------------
# Official Palworld mod loading is Windows-server-only, which is the entire
# reason this egg exists. Mods live in Mods\Workshop\<folder>\ with an Info.json;
# ActiveModList takes the PackageName from that Info.json, NOT the folder name.
if ($enableMods) {
    New-Item -ItemType Directory -Force -Path (Join-Path $modsDir 'Workshop') | Out-Null
    $modList = @()
    foreach ($mod in ($activeMods -split ',')) {
        $t = $mod.Trim()
        if ($t -ne '') { $modList += $t }
    }
    $modIni = @('[ModSettings]', 'bGlobalEnableMod=true')
    foreach ($mm in $modList) { $modIni += ('+ActiveModList=' + $mm) }
    [System.IO.File]::WriteAllText((Join-Path $modsDir 'PalModSettings.ini'),
        (($modIni -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
    Say ('Mods ENABLED - ' + $modList.Count + ' in ActiveModList: ' + $(if ($modList.Count) { ($modList -join ', ') } else { '(none listed)' }))
    $present = @(Get-ChildItem -Path (Join-Path $modsDir 'Workshop') -Directory -ErrorAction SilentlyContinue)
    Say ('Mods\Workshop holds ' + $present.Count + ' folder(s).')
    if ($modList.Count -eq 0 -and $present.Count -gt 0) {
        Say 'WARNING: mod folders are present but ACTIVE_MODS is empty, so NONE will load.'
        Say 'Put each mod PackageName (from its Info.json) into ACTIVE_MODS, comma separated.'
    }
} else {
    Say 'Mods disabled (ENABLE_MODS=0).'
}

# ---------------------------------------------------------------------------
# UE4SS
#
# Two mod systems exist and they are NOT the same thing:
#   - official loader : Mods\Workshop\<name>\ + Mods\PalModSettings.ini  (above)
#   - UE4SS           : Pal\Binaries\Win64\ue4ss\Mods\ + mods.txt        (here)
# Lua and Blueprint mods use UE4SS. Most are client-side, but the ones that
# perform server-authoritative actions (summoning, spawning) must be installed
# HERE to do anything at all. This block only reports - UE4SS is dropped in over
# SFTP, or pulled by install.ps1 when UE4SS_ZIP_URL is set.
# ---------------------------------------------------------------------------
$ue4ssDir  = Join-Path $game 'Pal\Binaries\Win64\ue4ss'
$ue4ssDll  = Join-Path $game 'Pal\Binaries\Win64\dwmapi.dll'
$modsTxt   = Join-Path $ue4ssDir 'Mods\mods.txt'
if (Test-Path $ue4ssDir) {
    $enabled = @()
    if (Test-Path $modsTxt) {
        foreach ($line in (Get-Content $modsTxt)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
            if ($t -match '^(?<n>[^:]+):\s*1\s*$') { $enabled += $Matches['n'].Trim() }
        }
    }
    $present = @(Get-ChildItem -Path (Join-Path $ue4ssDir 'Mods') -Directory -ErrorAction SilentlyContinue)
    Say ('UE4SS present - ' + $present.Count + ' mod folder(s), ' + $enabled.Count + ' enabled in mods.txt' +
         $(if ($enabled.Count) { ': ' + ($enabled -join ', ') } else { '' }))
    if (-not (Test-Path $ue4ssDll)) {
        Say 'WARNING: ue4ss\ exists but dwmapi.dll is NOT in Pal\Binaries\Win64 - UE4SS will not be'
        Say 'injected, so every UE4SS mod here is inert. Nothing will error; they simply will not run.'
    }
    if ($present.Count -gt 0 -and $enabled.Count -eq 0) {
        Say 'WARNING: UE4SS mod folders are present but mods.txt enables none of them.'
    }
} else {
    Say 'UE4SS not installed - Lua/Blueprint mods will not load (pak and official Workshop mods are unaffected).'
}

# --- launch -----------------------------------------------------------------
$argList = @(
    'Pal',
    ('-port=' + $gamePort),
    ('-publicport=' + $gamePort),
    ('-players=' + $maxPlayers),
    ('-servername=' + (Q $serverName)),
    ('-adminpassword=' + (Q $adminPass)),
    '-rcon',
    ('-RconPort=' + $rconPort),
    '-useperfthreads', '-NoAsyncLoadingThread', '-UseMultithreadForDS'
)
if ($publicLobby) { $argList += '-publiclobby' }
if (-not [string]::IsNullOrWhiteSpace($serverPass)) { $argList += ('-serverpassword=' + (Q $serverPass)) }
if (-not [string]::IsNullOrWhiteSpace($advertiseIp)) { $argList += ('-publicip=' + $advertiseIp) }
# -multihome binds the listen socket to ONE address instead of every interface on
# the box. win1 carries eleven IPs; without this the server answers on all of them.
if (-not [string]::IsNullOrWhiteSpace($multihome)) { $argList += ('-multihome=' + $multihome) }
if (-not [string]::IsNullOrWhiteSpace($extraArgs))  { $argList += ($extraArgs -split '\s+') }

Say ('Launching ' + (Split-Path -Leaf $exe) + ' on UDP ' + $gamePort + ' (rcon ' + $rconPort + ')')
$proc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $game -PassThru -NoNewWindow
Start-Sleep -Milliseconds 500
if ($null -eq $proc -or $proc.HasExited) {
    Say 'FATAL: the server process exited immediately after launch.'
    exit 1
}
Say ('Server PID ' + $proc.Id)

# --- RCON (Source protocol) -------------------------------------------------
$script:rconClient = $null
$script:rconStream = $null
$script:rconId = 0
$script:rconHostUsed = $null

function Rcon-Close {
    try { if ($script:rconStream) { $script:rconStream.Close() } } catch {}
    try { if ($script:rconClient) { $script:rconClient.Close() } } catch {}
    $script:rconStream = $null; $script:rconClient = $null
}
function Rcon-Send {
    param([int]$Type, [string]$Body)
    $script:rconId++
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
    $size = 4 + 4 + $bytes.Length + 2
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]$size); $bw.Write([int]$script:rconId); $bw.Write([int]$Type)
    $bw.Write($bytes); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Flush()
    $buf = $ms.ToArray()
    $script:rconStream.Write($buf, 0, $buf.Length); $script:rconStream.Flush()
    $bw.Close(); $ms.Close()
}
function Rcon-Read {
    param([int]$TimeoutMs = 4000)
    $script:rconStream.ReadTimeout = $TimeoutMs
    $hdr = New-Object byte[] 4
    $got = $script:rconStream.Read($hdr, 0, 4)
    if ($got -lt 4) { return $null }
    $len = [BitConverter]::ToInt32($hdr, 0)
    if ($len -lt 10 -or $len -gt 8192) { return $null }
    $payload = New-Object byte[] $len
    $off = 0
    while ($off -lt $len) {
        $n = $script:rconStream.Read($payload, $off, $len - $off)
        if ($n -le 0) { break }
        $off += $n
    }
    $bodyLen = $len - 10
    if ($bodyLen -lt 0) { $bodyLen = 0 }
    return [System.Text.Encoding]::ASCII.GetString($payload, 8, $bodyLen)
}
function Rcon-Connect {
    if ($script:rconStream) { return $true }
    # -multihome binds the listen sockets to ONE address, so loopback is not
    # guaranteed to answer. Try the bind address first, then 127.0.0.1, rather
    # than assuming either: if RCON is unreachable this wrapper cannot Save or
    # Shutdown, and stop degrades to a kill - which costs the world its progress
    # back to the last autosave.
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($multihome)) { $candidates += $multihome }
    $candidates += '127.0.0.1'
    foreach ($h in $candidates) {
        try {
            $script:rconClient = New-Object System.Net.Sockets.TcpClient
            $iar = $script:rconClient.BeginConnect($h, $rconPort, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(3000, $false)) { Rcon-Close; continue }
            $script:rconClient.EndConnect($iar)
            $script:rconStream = $script:rconClient.GetStream()
            Rcon-Send 3 $adminPass          # SERVERDATA_AUTH
            $null = Rcon-Read 4000
            if ($h -ne $script:rconHostUsed) {
                $script:rconHostUsed = $h
                Say ('rcon connected on ' + $h + ':' + $rconPort)
            }
            return $true
        } catch { Rcon-Close }
    }
    return $false
}
function Rcon-Command {
    param([string]$Cmd)
    if (-not (Rcon-Connect)) { return $null }
    try { Rcon-Send 2 $Cmd; return (Rcon-Read 5000) }   # SERVERDATA_EXECCOMMAND
    catch { Rcon-Close; return $null }
}

# --- readiness: structural, not a log string --------------------------------
# netstat.exe rather than Get-NetUDPEndpoint: NetTCPIP is not guaranteed present
# in the stock windows/steamcmd image, and a readiness probe that itself fails to
# run would report a healthy server as dead.
function Test-PortHeld {
    param([int]$Port, [int]$OwnerPid)
    try {
        # netstat prints the local address as IP:PORT ("0.0.0.0:8211", or the
        # multihome address). The character before the colon is a digit, never
        # whitespace, so the port must be anchored on the colon itself. ":8211"
        # cannot match inside ":18211", so no length guard is needed.
        $rows = & netstat -ano -p UDP 2>$null
        foreach ($r in $rows) {
            if ($r -match ([regex]::Escape(':' + $Port) + '\s') -and $r -match ('\s' + $OwnerPid + '\s*$')) { return $true }
        }
    } catch {}
    return $false
}

# --- log pump ---------------------------------------------------------------
$script:logPos = 0
function Pump-Log {
    if (-not (Test-Path $logFile)) { return }
    try {
        $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -lt $script:logPos) { $script:logPos = 0 }   # rotated or truncated
        [void]$fs.Seek($script:logPos, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs)
        $chunk = $sr.ReadToEnd()
        $script:logPos = $fs.Position
        $sr.Close(); $fs.Close()
        if ($chunk) { foreach ($line in ($chunk -split "`r?`n")) { if ($line.Trim() -ne '') { Write-Output $line } } }
    } catch {}
}

# --- stdin reader (panel console) -------------------------------------------
# A separate runspace: [Console]::In.ReadLine() blocks, and the supervisor loop
# must keep pumping the log and watching the process while waiting for input.
$queue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('queue', $queue)
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({
    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { Start-Sleep -Milliseconds 250; continue }
        [void]$queue.Add($line)
    }
})
$handle = $ps.BeginInvoke()

function Terminate {
    # MUST be [Environment]::Exit, not `exit`.
    #
    # `exit` asks the PowerShell engine to unwind, and the engine waits on the
    # stdin runspace above - which is parked forever inside
    # [Console]::In.ReadLine() and never returns. Measured 2026-08-11: the game
    # process stopped and saved correctly, the wrapper then sat alive for five
    # minutes, and feathers hung in "stopping" holding its power lock, so the
    # restart never completed and each attempt orphaned another wrapper.
    #
    # [Environment]::Exit terminates the process outright. Tear the runspace down
    # first so the normal path is still clean, but never depend on it.
    param([int]$Code = 0)
    #
    # Do NOT tidy the runspace up first. The first version of this function
    # called $ps.Stop() before exiting and hung in exactly the same way it was
    # written to prevent: Stop() waits for the pipeline to halt, and that
    # pipeline is blocked inside a native [Console]::In.ReadLine() that never
    # returns, so Stop() never returns either. The "tidy" teardown WAS the hang.
    #
    # Process exit reclaims the runspace, the thread and the handles. There is
    # nothing here worth risking a hung stop for, so this does the one thing
    # that cannot block: closing our own socket, then terminating.
    #
    Rcon-Close
    [Environment]::Exit($Code)
}

function Stop-Server {
    param([string]$Why)
    Say ('Stopping (' + $Why + ') - saving world first.')
    $r = Rcon-Command 'Save'
    if ($r) { Say ('rcon Save -> ' + $r.Trim()) } else { Say 'rcon Save got no response - continuing to shutdown anyway.' }
    Start-Sleep -Seconds 3
    $null = Rcon-Command 'Shutdown 1'
    for ($i = 0; $i -lt 60; $i++) {
        Pump-Log
        if ($proc.HasExited) { Say 'Server exited cleanly.'; Terminate 0 }
        Start-Sleep -Seconds 1
    }
    Say 'Server did not exit within 60s of Shutdown - killing the process.'
    try { $proc.Kill() } catch {}
    Terminate 0
}

# --- supervise ---------------------------------------------------------------
$ready = $false
$ticks = 0
Say 'Supervising. Type Palworld RCON commands into this console (ShowPlayers, Broadcast <msg>, KickPlayer <steamid>).'
while ($true) {
    if ($proc.HasExited) {
        Pump-Log
        Say ('Server process exited with code ' + $proc.ExitCode + '.')
        Terminate $proc.ExitCode
    }

    Pump-Log

    if (-not $ready) {
        $ticks++
        if (Test-PortHeld -Port $gamePort -OwnerPid $proc.Id) {
            $ready = $true
            # Emitted as ONE exact literal, never assembled from parts: this string is
            # the egg's done-string, and verify.py greps this source for it verbatim.
            Write-Output '[PRIMAL] PALWORLD READY'
            Say ('ready after ' + $ticks + 's - PID ' + $proc.Id + ' holding UDP ' + $gamePort)
        } elseif ($ticks -eq 300) {
            Say ('WARNING: 5 minutes in and PID ' + $proc.Id + ' still does not hold UDP ' + $gamePort + '.')
            Say 'The process is alive, so this is not a crash - check the log above for a bind error.'
        }
    }

    while ($queue.Count -gt 0) {
        $cmd = $queue[0]; $queue.RemoveAt(0)
        $cmd = "$cmd".Trim()
        if ($cmd -eq '') { continue }
        if ($cmd -eq 'stop' -or $cmd -eq 'shutdown') { Stop-Server 'console stop' }
        $resp = Rcon-Command $cmd
        if ($null -ne $resp) { Write-Output ($resp.TrimEnd()) }
        else { Say ('rcon: no response to "' + $cmd + '" (is the server finished booting?)') }
    }

    Start-Sleep -Seconds 1
}
