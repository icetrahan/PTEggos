# Primal - Palworld dedicated server install script (feathers / native-Windows node 2).
#
# ASCII ONLY. Same constraint as the Evrima egg: PowerShell 5.1 on the feathers
# node decodes this as CP1252 and several multi-byte characters decode to byte
# 0x94, which PS treats as a quote - enough of them and the script stops parsing.
# See ../../isles/evrima-windows-feathers/README.md "ASCII ONLY" and BUGS #448.
#
# THE GATE (workspace hard rule 13 / BUGS #346): this script exits 0 ONLY when the
# binary that start-palworld.ps1 actually launches is on disk. steamcmd is a native
# exe whose non-zero exit does NOT throw under $ErrorActionPreference='Stop', so
# nothing here may infer success from the absence of an exception. An install that
# produced no bootable server exits 1 with a class that says what to do about it.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$game = Join-Path $root 'server'
$sc   = Join-Path $root 'steamcmd'
$prim = Join-Path $root '_primal'
foreach ($d in $game, $sc, $prim) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$APPID = '2394010'

# The thin launcher. Diagnostic value only - never a success criterion.
# (Same trap as Evrima's 0.23 MB TheIsleServer.exe: it lands early in the pull.)
$launcherExe = Join-Path $game 'PalServer.exe'
# THE GATE: the binary start-palworld.ps1 launches and throws without.
$serverExe   = Join-Path $game 'Pal\Binaries\Win64\PalServer-Win64-Shipping.exe'

$steamExits = @()
$bootstrapExit = -999

function Test-Tcp {
    # Dependency-free reachability probe. Deliberately NOT Test-NetConnection: that
    # lives in the NetTCPIP module, which is not guaranteed present in the stock
    # windows/steamcmd image, and a diagnostic that itself fails to run would turn
    # a clear failure back into a vague one.
    param([string]$Target, [int]$Port = 443, [int]$TimeoutMs = 6000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Test-Dns {
    param([string]$Target)
    try { [System.Net.Dns]::GetHostAddresses($Target) | Out-Null; return $true } catch { return $false }
}

function Get-FreeGb {
    # Returns -1 for "could not measure". A class is never assigned from -1: an
    # unmeasurable disk must not be reported as a full one.
    param([string]$PathOnDisk)
    try {
        $qual = Split-Path -Qualifier ((Resolve-Path $PathOnDisk).Path)
        $drive = Get-PSDrive -Name $qual.TrimEnd(':') -ErrorAction Stop
        if ($null -eq $drive.Free) { return -1 }
        return [math]::Round($drive.Free / 1GB, 1)
    } catch { return -1 }
}

function Fail-Install {
    param([string]$Class, [string]$Summary, [string[]]$WhatToDo)
    Write-Output ''
    Write-Output '============================================================'
    Write-Output ('INSTALL FAILED - ' + $Class)
    Write-Output '============================================================'
    Write-Output $Summary
    Write-Output ''
    Write-Output 'What to do:'
    foreach ($line in $WhatToDo) { Write-Output ('  - ' + $line) }
    Write-Output ''
    Write-Output ('steamcmd bootstrap exit : ' + $bootstrapExit)
    Write-Output ('steamcmd attempt exits  : ' + $(if ($steamExits.Count -gt 0) { ($steamExits -join ', ') } else { '(never ran)' }))
    Write-Output ('free disk on volume     : ' + (Get-FreeGb $root) + ' GB')
    Write-Output '============================================================'
    exit 1
}

# --- SteamCMD ---------------------------------------------------------------
Write-Output 'Downloading SteamCMD...'
$zip = Join-Path $sc 'steamcmd.zip'
Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $sc -Force
$steam = Join-Path $sc 'steamcmd.exe'
if (-not (Test-Path $steam)) {
    Fail-Install -Class 'STEAMCMD_MISSING' `
        -Summary 'steamcmd.zip downloaded and extracted, but steamcmd.exe is not there.' `
        -WhatToDo @('Re-run the install. If it repeats, the Steam CDN served a bad archive.')
}

Write-Output 'Bootstrapping SteamCMD (self-update)...'
& $steam +quit | Out-Host
$bootstrapExit = $LASTEXITCODE
Write-Output ("(steamcmd) bootstrap exit code: " + $bootstrapExit)

# --- the game pull ----------------------------------------------------------
# Retry loop: transient Steam "Missing configuration" / connect failures are the
# norm, not the exception. The loop breaks on THE GATE file, never on the thin
# launcher - on Evrima the launcher landed in the first seconds of the pull and a
# loop that broke on it spent its retries instead of using them (BUGS #346).
for ($i = 1; $i -le 5; $i++) {
    Write-Output ("Installing Palworld dedicated server (app " + $APPID + ") - attempt $i of 5...")
    & $steam +force_install_dir $game +login anonymous +app_update $APPID validate +quit | Out-Host
    $steamExits += $LASTEXITCODE
    Write-Output ("(steamcmd) attempt $i exit code: " + $LASTEXITCODE)
    if (Test-Path $serverExe) { Write-Output 'Gate file present - stopping retries.'; break }
    if ($i -lt 5) { Write-Output 'Gate file not present yet - retrying in 15s...'; Start-Sleep -Seconds 15 }
}

# --- scaffold the dirs the wrapper writes into -------------------------------
# Created here so a first boot never races the game on directory creation, and so
# the operator can drop mods in over SFTP before the server has ever run.
foreach ($d in @(
    (Join-Path $game 'Pal\Saved\Config\WindowsServer'),
    (Join-Path $game 'Pal\Saved\SaveGames\0'),
    (Join-Path $game 'Mods\Workshop'),
    (Join-Path $game 'Pal\Content\Paks\~mods'),
    (Join-Path $game 'Pal\Content\Paks\LogicMods'),
    $prim
)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# --- optional UE4SS ---------------------------------------------------------
# Lua and Blueprint mods need UE4SS; the official Workshop loader does not. This
# is OPT-IN and unpinned by design: UE4SS ships a new build per game patch, so a
# URL baked into the egg would rot into a silently-wrong version. Set
# UE4SS_ZIP_URL to the release you actually want. Left empty, nothing is fetched
# and UE4SS mods simply do not load - which the wrapper says out loud on boot.
$ue4ssUrl = [Environment]::GetEnvironmentVariable('UE4SS_ZIP_URL')
if (-not [string]::IsNullOrWhiteSpace($ue4ssUrl)) {
    $win64 = Join-Path $game 'Pal\Binaries\Win64'
    New-Item -ItemType Directory -Force -Path $win64 | Out-Null
    Write-Output ('Fetching UE4SS from ' + $ue4ssUrl)
    try {
        $ue4ssZip = Join-Path $root 'ue4ss.zip'
        Invoke-WebRequest -Uri $ue4ssUrl -OutFile $ue4ssZip
        Expand-Archive -Path $ue4ssZip -DestinationPath $win64 -Force
        Remove-Item $ue4ssZip -Force -ErrorAction SilentlyContinue
        $dll = Join-Path $win64 'dwmapi.dll'
        if (Test-Path $dll) {
            Write-Output ('UE4SS installed - dwmapi.dll present (' + (Get-Item $dll).Length + ' B).')
        } else {
            # Not fatal: the SERVER still boots fine without UE4SS. But say so
            # plainly rather than let an operator infer a working mod loader
            # from the absence of an error.
            Write-Output 'WARNING: the UE4SS archive extracted but dwmapi.dll is NOT present.'
            Write-Output 'UE4SS will NOT be injected and every Lua/Blueprint mod will be inert.'
            Write-Output 'Check that UE4SS_ZIP_URL points at a zip whose ROOT holds dwmapi.dll.'
        }
    } catch {
        Write-Output ('WARNING: UE4SS fetch/extract failed: ' + $_.Exception.Message)
        Write-Output 'The server will still install and boot; Lua/Blueprint mods will not load.'
    }
} else {
    Write-Output 'UE4SS_ZIP_URL is empty - skipping UE4SS (pak and Workshop mods are unaffected).'
}

# --- verdict ----------------------------------------------------------------
$launcherOk = Test-Path $launcherExe
$serverOk   = Test-Path $serverExe
$launcherSize = if ($launcherOk) { (Get-Item $launcherExe).Length } else { 0 }
$serverSize   = if ($serverOk)   { (Get-Item $serverExe).Length }   else { 0 }

Write-Output ''
Write-Output 'Install verdict:'
Write-Output ('  thin launcher (NOT the gate)  server\PalServer.exe : ' + $(if ($launcherOk) { "present, $launcherSize B" } else { 'MISSING' }))
Write-Output ('  THE GATE  server\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe : ' + $(if ($serverOk) { "present, $serverSize B" } else { 'MISSING' }))

if ($serverOk) {
    Write-Output ('OK: PalServer-Win64-Shipping.exe present (' + $serverSize + ' B).')
    Write-Output 'Install complete.'
    exit 0
}

# --- no bootable server: diagnose, then exit 1 ------------------------------
$anyGameFiles = @(Get-ChildItem -Path $game -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0
$freeGb = Get-FreeGb $root

if (-not (Test-Tcp -Target '1.1.1.1' -Port 443)) {
    Fail-Install -Class 'NO_OUTBOUND' `
        -Summary 'This box has NO outbound connectivity - not even to 1.1.1.1:443, so steamcmd could never have reached Steam.' `
        -WhatToDo @(
            'Check the host firewall / egress rules on win1 (199.127.62.3).',
            'On 2026-07-28 a DDoS mitigation false-positived on steamcmd pulling and cut the box outbound.')
}
if (-not (Test-Dns -Target 'steamcdn-a.akamaihd.net')) {
    Fail-Install -Class 'NO_DNS' `
        -Summary 'Raw outbound works but Steam hostnames do not resolve, so steamcmd cannot find Steam.' `
        -WhatToDo @('Check DNS resolver config on win1.')
}
if ($freeGb -ge 0 -and $freeGb -lt 5) {
    Fail-Install -Class 'DISK_FULL' `
        -Summary ('Only ' + $freeGb + ' GB free on the volume; the Palworld server needs roughly 10 GB.') `
        -WhatToDo @('Raise the server disk limit, or free space on win1.')
}
if (-not $anyGameFiles) {
    Fail-Install -Class 'STEAM_NO_FILES' `
        -Summary 'Steam is reachable but steamcmd produced no game files at all.' `
        -WhatToDo @(
            'Read the steamcmd exit codes above and the attempt output for the real error.',
            ('Confirm app ' + $APPID + ' is still the Palworld dedicated server appid and is anonymous-downloadable.'))
}
Fail-Install -Class 'PARTIAL_PULL' `
    -Summary ('steamcmd wrote game files but the gate binary is absent. This is the state a naive script ' +
              'would call "Install complete." - it is an unbootable server.') `
    -WhatToDo @(
        'Re-run the install; a partial pull usually completes on a second validate.',
        'If it repeats, read the steamcmd attempt output above for the failing depot.')
