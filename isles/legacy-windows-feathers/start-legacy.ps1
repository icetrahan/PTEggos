# Primal - The Isle: LEGACY startup wrapper (feathers / native-Windows node).
#
# Legacy = SteamCMD app 412680, branch `public` (UE 4.25.4). INSTALL ONCE, NEVER
# UPDATE - the build is frozen, so there is NO SteamCMD update on boot (an update
# would only risk breaking a working install). Downside: a crash can wipe files,
# so we RE-RENDER Game.ini + RE-SYNC mods every boot to self-heal.
#
# Each boot: render Game.ini (Legacy schema) + MOTD -> sync server mods -> launch.
#
# Launch (Ice's canonical Legacy command):
#   TheIsleServer-Win64-Shipping.exe {Map}?Port={p}?QueryPort={q}?MaxPlayers={m}?game={mode}?listen -log
#   - ?game (Survival|Sandbox) and ?listen are REQUIRED (without them the server
#     exits immediately). NO -MULTIHOME / -stdout (Legacy doesn't want them).
#   - Root TheIsleServer.exe is a dead launcher shim; run Shipping directly.

$ErrorActionPreference = 'Stop'
$root    = (Get-Location).Path
$game    = Join-Path $root 'server'
$exe     = Join-Path $game 'TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe'
$isleLog = Join-Path $game 'TheIsle\Saved\Logs\TheIsle.log'
$savedDir= Join-Path $game 'TheIsle\Saved'
$cfgDir  = Join-Path $game 'TheIsle\Saved\Config\WindowsServer'
$paksDir = Join-Path $game 'TheIsle\Content\Paks'
$modsSrc = Join-Path $root '_mods'

function To-Bool([string]$v, [string]$fb) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $fb }
    if ($v -match '^(1|true|yes|on)$') { return 'true' } else { return 'false' }
}
function Split-Csv([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return @() }
    return @($v -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
function EnvOr([string]$v, [string]$fb) { if ([string]::IsNullOrWhiteSpace($v)) { return $fb } else { return $v } }

# ── settings (defaults <- egg vars) ──────────────────────────────────────────
$serverName = EnvOr $env:SERVER_NAME 'Primal Hosted - Legacy'
$maxPlayers = EnvOr $env:MAX_PLAYERS '100'
$gameMode   = EnvOr $env:GAME_MODE 'Survival'                 # Survival | Sandbox
$password   = EnvOr $env:SERVER_PASSWORD ''
$gamePort   = EnvOr $env:SERVER_PORT '7777'
$queryPort  = EnvOr $env:SERVER_PORT_1 ([string]([int]$gamePort + 1))

# map: accept a short key or a full path (default Isle_V3)
$MAPS = @{
    'Isle_V3'   = '/Game/TheIsle/Maps/Landscape3/Isle_V3'
    'V3'        = '/Game/TheIsle/Maps/Landscape3/Isle_V3'
    'Thenyaw'   = '/Game/TheIsle/Maps/Thenyaw_Island/Thenyaw_Island'
    'TestLevel' = '/Game/TheIsle/Maps/Developer/DV_TestLevel'
}
$mapIn = EnvOr $env:MAP 'Isle_V3'
$map   = if ($MAPS.ContainsKey($mapIn)) { $MAPS[$mapIn] } elseif ($mapIn -like '/Game/*') { $mapIn } else { $MAPS['Isle_V3'] }

$admins        = Split-Csv $env:ADMIN_STEAM_IDS
$disabledDinos = Split-Csv $env:DISABLED_DINOS
$motd          = EnvOr $env:MOTD ''

# ── RENDER Game.ini (Legacy schema: igamesession + Engine.GameSession + igamemode) ──
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$adminLines = if ($admins.Count) { ($admins | ForEach-Object { "ServerAdmins=$_" }) -join "`r`n" } else { 'ServerAdmins=' }
$dinoLines  = if ($disabledDinos.Count) { ($disabledDinos | ForEach-Object { "DisabledDinosaurs=$_" }) -join "`r`n" } else { 'DisabledDinosaurs=' }

$gi = @"
[/script/theisle.igamesession]
ServerName=$serverName
ServerPassword=$password
bServerDatabase=true
bServerAllowChat=$(To-Bool $env:ALLOW_CHAT 'true')
bServerGlobalChat=$(To-Bool $env:GLOBAL_CHAT 'true')
bServerNameTags=$(To-Bool $env:NAME_TAGS 'true')
bServerGrowth=$(To-Bool $env:GROWTH 'true')
bServerFallDamage=$(To-Bool $env:FALL_DAMAGE 'true')
bServerAllowTurnInPlace=$(To-Bool $env:TURN_IN_PLACE 'true')
bServerAllowReplayRecording=$(To-Bool $env:ALLOW_REPLAY 'true')
ServerDeadBodyTime=$(EnvOr $env:DEAD_BODY_TIME '200')
ServerRespawnTime=$(EnvOr $env:RESPAWN_TIME '30')
ServerLogoutTime=$(EnvOr $env:LOGOUT_TIME '60')
ServerFootprintLifetime=$(EnvOr $env:FOOTPRINT_LIFETIME '60')
bServerNesting=$(To-Bool $env:NESTING 'true')
bServerScent=$(To-Bool $env:SCENT 'false')
bServerAI=$(To-Bool $env:ENABLE_AI 'true')
ServerAIMax=$(EnvOr $env:AI_MAX '100')
ServerAIRate=$(EnvOr $env:AI_RATE '1.5')
bServerAIPlayerSpawns=$(To-Bool $env:AI_PLAYER_SPAWNS 'true')
$adminLines

[/Script/Engine.GameSession]
MaxPlayers=$maxPlayers

[/script/theisle.igamemode]
ServerStartingTime=$(EnvOr $env:STARTING_TIME '341')
bServerDynamicTimeOfDay=$(To-Bool $env:DYNAMIC_TIME '0')
ServerDayLength=$(EnvOr $env:DAY_LENGTH '30')
$dinoLines
"@
Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
Write-Host "(config) rendered Legacy Game.ini (players=$maxPlayers, mode=$gameMode, admins=$($admins.Count), disabled=$($disabledDinos.Count))"

# ── MOTD (empty file = no MOTD popup; text = shown to players on join) ────────
New-Item -ItemType Directory -Force -Path $savedDir | Out-Null
Set-Content -Path (Join-Path $savedDir 'MOTD.txt') -Value $motd -Encoding utf8 -NoNewline
Write-Host "(config) wrote MOTD ($($motd.Length) chars)"

# ── MOD SYNC (server-side .pak+.sig into Content/Paks; server must be offline,
#    which it is here pre-launch). Re-synced every boot so a crash-wipe self-heals.
#    Grouping mods are mutually exclusive; variant mods pick a build by grouping. ─
$MOD_CATALOG = @{
    'UniversalGrouping'  = @{ folder = 'UniversalGrouping';  file = 'TheIsle-WindowsServer_zUniversalGrouping' }
    'DietGrouping'       = @{ folder = 'DietGrouping';       file = 'TheIsle-WindowsServer_zDietGrouping' }
    'HerbieGrouping'     = @{ folder = 'HerbieGrouping';     file = 'TheIsle-WindowsServer_zHerbieGrouping' }
    'UniversalDevColors' = @{ folder = 'UniversalDevColors'; file = 'TheIsle-WindowsServer_UniversalDevColors' }
    'AnkyBonebreak'      = @{ folder = 'AnkyBonebreak';      file = 'TheIsle-WindowsServer_zzAnkyBonebreak' }
    'PachyBoneBreak'     = @{ folder = 'PachyBoneBreak';     file = 'TheIsle-WindowsServer_zPachyBoneBreak' }
    'EnhancedPara'   = @{ folder = 'EnhancedPara';   variants = @{ none='TheIsle-WindowsServer_zEnhancedPara_DefaultGrouping'; herbie='TheIsle-WindowsServer_zEnhancedPara_DietHerbieGrouping'; diet='TheIsle-WindowsServer_zEnhancedPara_DietHerbieGrouping'; universal='TheIsle-WindowsServer_zEnhancedPara_UniversalGrouping' } }
    'EnhancedAustro' = @{ folder = 'EnhancedAustro'; variants = @{ none='TheIsle-WindowsServer_zzEnhancedAustro_DefaultGrouping'; herbie='TheIsle-WindowsServer_zzEnhancedAustro_DefaultGrouping'; diet='TheIsle-WindowsServer_zzEnhancedAustro_UniversalDietGrouping'; universal='TheIsle-WindowsServer_zzEnhancedAustro_UniversalDietGrouping' } }
    'EnhancedBary'   = @{ folder = 'EnhancedBary';   variants = @{ none='TheIsle-WindowsServer_zzEnhancedBary_DefaultGrouping'; herbie='TheIsle-WindowsServer_zzEnhancedBary_DefaultGrouping'; diet='TheIsle-WindowsServer_zzEnhancedBary_UniversalDietGrouping'; universal='TheIsle-WindowsServer_zzEnhancedBary_UniversalDietGrouping' } }
    'ExtremeUtah'    = @{ folder = 'ExtremeUtah';    variants = @{ none='TheIsle-WindowsServer_zExtremeUtah_DefaultGrouping'; herbie='TheIsle-WindowsServer_zExtremeUtah_DefaultGrouping'; diet='TheIsle-WindowsServer_zExtremeUtah_DietUniversalGrouping'; universal='TheIsle-WindowsServer_zExtremeUtah_DietUniversalGrouping' } }
    'UtahGore'       = @{ folder = 'UtahGore';       variants = @{ none='TheIsle-WindowsServer_zUtahGore_DefaultGrouping'; herbie='TheIsle-WindowsServer_zUtahGore_DefaultGrouping'; diet='TheIsle-WindowsServer_zUtahGore_DietUniversalGrouping'; universal='TheIsle-WindowsServer_zUtahGore_DietUniversalGrouping' } }
}
function Mod-Files($m, $grouping) {
    if ($m.variants) { $base = $m.variants[$grouping]; if (-not $base) { $base = $m.variants['none'] } } else { $base = $m.file }
    return $base
}
# resolve the DESIRED mod set (grouping mod + enabled addons, minus incompatibilities)
$grouping = (EnvOr $env:GROUPING_MOD 'none').ToLower()
$groupModName = @{ 'universal'='UniversalGrouping'; 'diet'='DietGrouping'; 'herbie'='HerbieGrouping' }[$grouping]
$wantMods = New-Object System.Collections.Generic.List[string]
if ($groupModName) { $wantMods.Add($groupModName) }
foreach ($mod in (Split-Csv $env:ENABLED_MODS)) { if ($MOD_CATALOG.ContainsKey($mod)) { $wantMods.Add($mod) } }
if ($wantMods -contains 'ExtremeUtah' -and $wantMods -contains 'UtahGore') {
    Write-Host "(mods) WARNING: ExtremeUtah and UtahGore are incompatible - keeping ExtremeUtah, dropping UtahGore"
    $wantMods.Remove('UtahGore') | Out-Null
}

# stage the mod library from R2 if we need mods and it isn't present (also self-heals a crash-wipe;
# vanilla servers never download it). MODS_URL can be overridden via the LEGACY_MODS_URL egg var.
$MODS_URL = EnvOr $env:LEGACY_MODS_URL 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/legacy-mods.zip'
if ($wantMods.Count -gt 0 -and -not (Test-Path (Join-Path $modsSrc 'UniversalGrouping'))) {
    Write-Host "(mods) staging mod library from R2..."
    New-Item -ItemType Directory -Force -Path $modsSrc | Out-Null
    $zip = Join-Path $root 'legacy-mods.zip'
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $MODS_URL -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $modsSrc -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Write-Host "(mods) staged $((Get-ChildItem $modsSrc -Directory -ErrorAction SilentlyContinue).Count) mod folders"
    } catch { Write-Host "(mods) ERROR staging mods: $_" }
}

# sync Content/Paks: strip all managed paks (so disabling removes them), then copy selected variants
New-Item -ItemType Directory -Force -Path $paksDir | Out-Null
foreach ($m in $MOD_CATALOG.Values) {
    $bases = if ($m.variants) { $m.variants.Values | Select-Object -Unique } else { @($m.file) }
    foreach ($b in $bases) {
        Remove-Item (Join-Path $paksDir "$b.pak") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $paksDir "$b.sig") -Force -ErrorAction SilentlyContinue
    }
}
$installed = @()
foreach ($mod in ($wantMods | Select-Object -Unique)) {
    $m = $MOD_CATALOG[$mod]; $base = Mod-Files $m $grouping
    $srcPak = Join-Path $modsSrc "$($m.folder)\$base.pak"
    $srcSig = Join-Path $modsSrc "$($m.folder)\$base.sig"
    if (Test-Path $srcPak) {
        Copy-Item $srcPak $paksDir -Force
        if (Test-Path $srcSig) { Copy-Item $srcSig $paksDir -Force }
        $installed += "$mod($([regex]::Replace($base,'^.*_','')))"
    } else { Write-Host "(mods) missing source pak for ${mod}: $srcPak" }
}
Write-Host "(mods) grouping=$grouping installed=[$($installed -join ', ')]"

# render-only hook (local config/mod-sync tests): PRIMAL_RENDER_ONLY=1 -> stop here
if ($env:PRIMAL_RENDER_ONLY -eq '1') { Write-Host '(render-only) done'; exit 0 }

if (-not (Test-Path $exe)) { throw "server binary missing: $exe (install did not finish)" }

# ── Primal DLL mod: download-by-version (deployment pipeline). Manifest carries
#    {version, dll_url, sha256}; only re-downloads when the version changes. The
#    injection itself is armed just before launch (below). Publish new versions
#    with isle_mod_legacy/publish_dll.py — see PRIMAL_MOD_PIPELINE.md.
$primalDir = Join-Path $root '_primal'
$primalDll = Join-Path $primalDir 'LegacyMod.dll'
$primalVerFile = Join-Path $primalDir 'primal-mod.version'
if ($env:ENABLE_PRIMAL_MOD -eq '1') {
    $manifestUrl = EnvOr $env:PRIMAL_MOD_MANIFEST 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-mod/latest.json'
    try {
        $ProgressPreference = 'SilentlyContinue'
        $m = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 20
        $haveVer = if (Test-Path $primalVerFile) { (Get-Content $primalVerFile -Raw).Trim() } else { '' }
        if ($m.version -ne $haveVer -or -not (Test-Path $primalDll)) {
            Write-Host "(primal-mod) updating '$haveVer' -> '$($m.version)'..."
            Invoke-WebRequest -Uri $m.dll_url -OutFile $primalDll -UseBasicParsing
            $sha = (Get-FileHash $primalDll -Algorithm SHA256).Hash.ToLower()
            if ($sha -ne ("" + $m.sha256).ToLower()) {
                Write-Host "(primal-mod) sha256 MISMATCH (got $sha) - discarding"
                Remove-Item $primalDll -Force -ErrorAction SilentlyContinue
            } else {
                Set-Content -Path $primalVerFile -Value $m.version -Encoding ascii
                Write-Host "(primal-mod) DLL $($m.version) ready ($($m.size) bytes)"
            }
        } else { Write-Host "(primal-mod) up to date ($haveVer)" }
    } catch { Write-Host "(primal-mod) manifest/download failed: $_" }

    # Per-server mod config: the DLL authenticates + polls ONLY this server's
    # commands using its own phsk_ key. Keys match legacy_mod.cpp's parser
    # (command_poll_url / command_key / license_key / rt_base_url / server_id).
    # Written beside the DLL (module dir) - where the DLL SHOULD read it once the
    # hardcoded dev path in load_config() is changed to module_directory().
    if ($env:PHSK_KEY) {
        $dataBase = EnvOr $env:PRIMAL_DATA_BASE 'https://data.primalhosted.com'
        $rtBase   = EnvOr $env:PRIMAL_RT_BASE   'https://rt.primalhosted.com'
        $sid = EnvOr $env:SERVER_NAME 'legacy'
        $cfg = @(
            '# Primal Hosted - auto-generated each boot from the server phsk_ key. Do not edit.',
            "command_poll_url=$dataBase/v1/commands",
            "command_key=$($env:PHSK_KEY)",
            "license_key=$($env:PHSK_KEY)",
            "rt_base_url=$rtBase",
            "server_id=$sid",
            'command_poll_interval_ms=2000'
        ) -join "`n"
        Set-Content -Path (Join-Path $primalDir 'legacy_anticheat.cfg') -Value $cfg -Encoding ascii
        Write-Host "(primal-mod) wrote legacy_anticheat.cfg (per-server key, poll=$dataBase/v1/commands)"
    } else {
        Write-Host "(primal-mod) no PHSK_KEY set - mod will run without a data-plane key"
    }
} else {
    Write-Host "(primal-mod) disabled (ENABLE_PRIMAL_MOD != 1)"
}

# ── LAUNCH + supervise ───────────────────────────────────────────────────────
# UE writes to stderr in normal operation; 'Stop' would turn that into a
# NativeCommandError that kills the wrapper. 'Continue' lets it flow to feathers.
$ErrorActionPreference = 'Continue'
$url = "$map`?Port=$gamePort`?QueryPort=$queryPort`?MaxPlayers=$maxPlayers`?game=$gameMode`?listen"
Write-Host "(start) $(Get-Date -Format HH:mm:ss) launching: $url"
$before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

# Primal DLL mod injection (deployment scaffold). Arm a background job that waits
# for the NEW server process, then LoadLibraryW-injects the DLL via CreateRemoteThread
# (same technique as isle_mod_rebuild/inject_isle_mod.py, done in-process with P/Invoke
# so the container needs no Python). Result -> _primal/primal-inject.log. The final
# live inject + command-fetch verification is the remaining "last bit of testing".
if ($env:ENABLE_PRIMAL_MOD -eq '1' -and (Test-Path $primalDll)) {
    $injLog = Join-Path $primalDir 'primal-inject.log'
    Start-Job -Name primal-inject -ArgumentList $primalDll, $before, $injLog -ScriptBlock {
        param($dll, $beforeIds, $log)
        function W($m) { "$(Get-Date -Format 'HH:mm:ss') $m" | Out-File -FilePath $log -Append -Encoding ascii }
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class PInj {
  [DllImport("kernel32", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool inh, uint pid);
  [DllImport("kernel32", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, uint sz, uint typ, uint prot);
  [DllImport("kernel32", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, uint sz, out UIntPtr wrote);
  [DllImport("kernel32", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr GetModuleHandleA(string n);
  [DllImport("kernel32", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
  [DllImport("kernel32", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr sa, uint sz, IntPtr start, IntPtr arg, uint fl, IntPtr tid);
  [DllImport("kernel32", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32", SetLastError=true)] public static extern bool GetExitCodeThread(IntPtr h, out uint code);
}
'@
        "===== primal-inject $(Get-Date -Format o) =====" | Out-File -FilePath $log -Encoding ascii
        $proc = $null
        for ($i = 0; $i -lt 60 -and -not $proc; $i++) {
            Start-Sleep -Milliseconds 500
            $proc = Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $beforeIds -notcontains $_.Id } | Select-Object -First 1
        }
        if (-not $proc) { W 'no server process appeared - abort inject'; return }
        Start-Sleep -Seconds 10   # let the server finish init before injecting
        W "injecting into pid $($proc.Id): $dll"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($dll + [char]0)
        $h = [PInj]::OpenProcess(0x1F0FFF, $false, [uint32]$proc.Id)
        if ($h -eq [IntPtr]::Zero) { W 'OpenProcess failed'; return }
        $addr = [PInj]::VirtualAllocEx($h, [IntPtr]::Zero, [uint32]$bytes.Length, 0x3000, 0x04)
        if ($addr -eq [IntPtr]::Zero) { W 'VirtualAllocEx failed'; return }
        $wrote = [UIntPtr]::Zero
        [void][PInj]::WriteProcessMemory($h, $addr, $bytes, [uint32]$bytes.Length, [ref]$wrote)
        $ll = [PInj]::GetProcAddress([PInj]::GetModuleHandleA('kernel32.dll'), 'LoadLibraryW')
        $t = [PInj]::CreateRemoteThread($h, [IntPtr]::Zero, 0, $ll, $addr, 0, [IntPtr]::Zero)
        if ($t -eq [IntPtr]::Zero) { W 'CreateRemoteThread failed'; return }
        [void][PInj]::WaitForSingleObject($t, 15000)
        # LoadLibraryW's return (HMODULE, low 32 bits) is the remote thread exit code:
        # 0 => load FAILED (bad deps / bitness / DllMain crash); non-zero => loaded.
        $ec = 0; [void][PInj]::GetExitCodeThread($t, [ref]$ec)
        W "inject call complete (LoadLibraryW exit=0x$("{0:x}" -f $ec); 0 = load FAILED)"
        Start-Sleep -Seconds 2
        $name = [IO.Path]::GetFileName($dll)
        try {
            $mod = Get-Process -Id $proc.Id -Module -ErrorAction Stop | Where-Object { $_.ModuleName -ieq $name }
            if ($mod) { W "VERIFIED: $name is loaded in pid $($proc.Id)  ($($mod.FileName))" }
            else      { W "WARNING: $name NOT present in pid $($proc.Id) module list after inject" }
        } catch { W "module verify inconclusive (enum failed: $($_.Exception.Message))" }
    } | Out-Null
    Write-Host "(primal-mod) injector armed (post-boot; result -> _primal/primal-inject.log; mod runtime -> _primal/legacy_mod.log)"
}

# Multihome (opt-in): Legacy historically launched WITHOUT -MULTIHOME. For per-server
# DDoS isolation you can bind/advertise ONE specific public IP by setting MULTIHOME_IP.
# Left BLANK (default) = unchanged behaviour (bind all interfaces) so the live OVH box
# is untouched. ⚠️ test on a SPARE server first - some Legacy builds are picky.
#
# Legacy = STEAM networking (app 412680, UE4.25), NOT EOS — so the Evrima
# EOS_OVERRIDE_HOST_IP fix almost certainly does NOTHING here. The lever is UE4
# MultiHome, and Legacy accepts it in two forms we must A/B test:
#   MULTIHOME_MODE=cli  (default) -> `-MULTIHOME=<ip>` engine arg (Evrima-style)
#   MULTIHOME_MODE=url            -> `?MultiHome=<ip>` in the travel URL (the form
#                                    in the only online reference we could find)
#   MULTIHOME_MODE=both           -> both at once (belt + suspenders)
# Steam auto-detects the advertised public IP from the bound socket, so unlike EOS
# a correct bind SHOULD also fix advertisement — but that's the exact thing to
# verify (client connects to the dedicated IP; A2S on <dedIP>:QueryPort answers).
$mhMode = (EnvOr $env:MULTIHOME_MODE 'cli').ToLower()
$mhArgs = @()
if ($env:MULTIHOME_IP -and $env:MULTIHOME_IP -ne '0.0.0.0' -and $env:MULTIHOME_IP -match '^\d{1,3}(\.\d{1,3}){3}$') {
    $mhIp = $env:MULTIHOME_IP
    if ($mhMode -eq 'cli' -or $mhMode -eq 'both') { $mhArgs = @("-MULTIHOME=$mhIp") }
    if ($mhMode -eq 'url' -or $mhMode -eq 'both') {
        # insert ?MultiHome right after the map, before Port (matches the reference:
        # Map?MultiHome=<ip>?Port=..?QueryPort=..). Rebuild the URL identically to above.
        $url = "$map`?MultiHome=$mhIp`?Port=$gamePort`?QueryPort=$queryPort`?MaxPlayers=$maxPlayers`?game=$gameMode`?listen"
    }
    Write-Host "(start) multihome ip=$mhIp mode=$mhMode  args=[$($mhArgs -join ' ')]"
}

# Foreground launch: if Legacy runs in-process, this BLOCKS for the server's whole
# life and its stdout streams straight to feathers (correct). If instead it detaches,
# `&` returns fast and we fall through to find + supervise the detached process.
& $exe $url @mhArgs -log

$proc = Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue |
        Where-Object { $before -notcontains $_.Id } | Select-Object -First 1
if ($proc) {
    Write-Host "(start) supervising detached server pid $($proc.Id)"
    $pos = 0
    while (-not $proc.HasExited) {
        if (Test-Path $isleLog) {
            try {
                $fs = [IO.File]::Open($isleLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                if ($fs.Length -lt $pos) { $pos = 0 }
                if ($fs.Length -gt $pos) { $fs.Position = $pos; $sr = New-Object IO.StreamReader($fs); $t = $sr.ReadToEnd(); if ($t) { [Console]::Out.Write($t) }; $pos = $fs.Position; $sr.Dispose() }
                $fs.Dispose()
            } catch { }
        }
        Start-Sleep -Milliseconds 750
        $proc.Refresh()
    }
}
Write-Host "(exit) $(Get-Date -Format HH:mm:ss) Legacy server process ended; feathers will restart per policy."
