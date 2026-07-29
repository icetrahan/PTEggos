# Primal — The Isle: Evrima startup wrapper (feathers / native-Windows node).
#
# Each boot: SteamCMD update -> RENDER Game.ini/Engine.ini from data -> launch.
# Game.ini is a DERIVED artifact, regenerated every boot from the settings below.
# The customer never edits Game.ini directly (The Isle corrupts it) - they edit
# DATA, and we render fresh each boot. Corruption becomes a non-issue.
#
# Settings are layered, later overrides earlier:
#   1. DEFAULTS (below)                      baseline
#   2. EGG VARIABLES ($env:*)                the ~12 common knobs + 3 CSV lists
#   3. JSON OVERLAY (_primal/server-config.json)   Primal Hosted writes this for
#      full customization (any field + arbitrary extra session keys). Optional.
#
# Ports come from Panel ALLOCATIONS (not variables, so not customer-editable):
#   game/query = SERVER_PORT | queue = SERVER_PORT_1 | rcon = SERVER_PORT_2

$ErrorActionPreference = 'Stop'
$root  = (Get-Location).Path
$game  = Join-Path $root 'server'
$steam = Join-Path $root 'steamcmd\steamcmd.exe'
$tmpl  = Join-Path $root '_primal'

# DEBUG instrumentation: record wrapper lifecycle so we can see exactly how far
# it gets and whether it throws / the launch returns early. (Temporary.)
$script:dbg = Join-Path $tmpl 'wrapper-debug.log'
function Dbg($m) { "$(Get-Date -Format 'HH:mm:ss.fff') pid=$PID  $m" | Out-File -FilePath $script:dbg -Append -Encoding ascii }
"===== wrapper start $(Get-Date -Format o) =====" | Out-File -FilePath $script:dbg -Encoding ascii
Dbg "begin"

function To-Bool([string]$v, [string]$fallback) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $fallback }
    if ($v -match '^(1|true|yes|on)$') { return 'True' } else { return 'False' }
}
function Split-Csv([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return @() }
    return @($v -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
function EnvOr([string]$v, [string]$fb) { if ([string]::IsNullOrWhiteSpace($v)) { return $fb } else { return $v } }

# ---------------------------------------------------------------------------
# 1) DEFAULTS
# ---------------------------------------------------------------------------
$defaultClasses = @(
    'Dryosaurus','Hypsilophodon','Maiasaura','Pachycephalosaurus','Stegosaurus',
    'Tenontosaurus','Carnotaurus','Ceratosaurus','Deinosuchus','Dilophosaurus',
    'Herrerasaurus','Omniraptor','Pteranodon','Troodon','Beipiaosaurus','Gallimimus',
    'Diabloceratops','Triceratops','Allosaurus','Tyrannosaurus','Kentrosaurus',
    'Baryonyx','Oviraptor'
)
$cfg = @{
    ServerName            = 'Primal Heaven Evrima'
    MaxPlayers            = '150'
    ServerPasswordEnabled = 'False'
    ServerPassword        = ''
    RconEnabled           = 'False'
    RconPassword          = 'CHANGEME'
    Discord               = 'https://discord.gg/primalheaven'
    CorpseDecay           = '0.02'
    AdminSteamIds         = @()
    VipSteamIds           = @()
    AllowedClasses        = $defaultClasses
    # ---- gameplay knobs (customer-configurable via egg vars / overlay) ----
    EnableHumans          = 'True'
    DayLength             = '45'
    NightLength           = '20'
    GrowthMultiplier      = '1'
    EnableGlobalChat      = 'True'
    EnableAI              = 'False'
    AIDensity             = '0'
    SpawnFish             = 'False'
    EnableMutations       = 'True'
    EnableDiets           = 'True'
    FallDamage            = 'True'
    AllowReplay           = 'True'
    DynamicWeather        = 'False'
    WhitelistEnabled      = 'False'
    SpawnPlants           = 'False'
    PlantMultiplier       = '0'
    EnableMigration       = 'False'
    EnableMassMigration   = 'False'
    EnablePatrolZones     = 'False'
    Extra                 = @{}   # arbitrary [tigamesession] key=value (overlay only)
}

# ---------------------------------------------------------------------------
# 2) EGG VARIABLE OVERRIDES
# ---------------------------------------------------------------------------
if ($env:SERVER_NAME)      { $cfg.ServerName            = $env:SERVER_NAME }
if ($env:MAX_PLAYERS)      { $cfg.MaxPlayers            = $env:MAX_PLAYERS }
if ($env:SERVER_PASSWORD)  { $cfg.ServerPassword        = $env:SERVER_PASSWORD }
if ($env:RCON_PASSWORD)    { $cfg.RconPassword          = $env:RCON_PASSWORD }
if ($env:DISCORD_URL)      { $cfg.Discord               = $env:DISCORD_URL }
if ($env:CORPSE_DECAY)     { $cfg.CorpseDecay           = $env:CORPSE_DECAY }
$cfg.ServerPasswordEnabled = To-Bool $env:SERVER_PASSWORD_ENABLED $cfg.ServerPasswordEnabled
$cfg.RconEnabled           = To-Bool $env:RCON_ENABLED           $cfg.RconEnabled
if ($env:ADMIN_STEAM_IDS -ne $null) { $ids = Split-Csv $env:ADMIN_STEAM_IDS; if ($ids.Count) { $cfg.AdminSteamIds = $ids } }
if ($env:VIP_STEAM_IDS   -ne $null) { $ids = Split-Csv $env:VIP_STEAM_IDS;   if ($ids.Count) { $cfg.VipSteamIds   = $ids } }
if ($env:ALLOWED_CLASSES -ne $null) { $cl  = Split-Csv $env:ALLOWED_CLASSES; if ($cl.Count)  { $cfg.AllowedClasses = $cl } }
if ($env:SERVER_DAY_LENGTH)   { $cfg.DayLength        = $env:SERVER_DAY_LENGTH }
if ($env:SERVER_NIGHT_LENGTH) { $cfg.NightLength      = $env:SERVER_NIGHT_LENGTH }
if ($env:GROWTH_MULTIPLIER)   { $cfg.GrowthMultiplier = $env:GROWTH_MULTIPLIER }
if ($env:AI_DENSITY)          { $cfg.AIDensity        = $env:AI_DENSITY }
if ($env:PLANT_MULTIPLIER)    { $cfg.PlantMultiplier  = $env:PLANT_MULTIPLIER }
$cfg.EnableHumans        = To-Bool $env:ENABLE_HUMANS         $cfg.EnableHumans
$cfg.EnableGlobalChat    = To-Bool $env:ENABLE_GLOBAL_CHAT    $cfg.EnableGlobalChat
$cfg.EnableAI            = To-Bool $env:ENABLE_AI             $cfg.EnableAI
$cfg.SpawnFish           = To-Bool $env:SPAWN_FISH            $cfg.SpawnFish
$cfg.EnableMutations     = To-Bool $env:ENABLE_MUTATIONS      $cfg.EnableMutations
$cfg.EnableDiets         = To-Bool $env:ENABLE_DIETS          $cfg.EnableDiets
$cfg.FallDamage          = To-Bool $env:FALL_DAMAGE           $cfg.FallDamage
$cfg.AllowReplay         = To-Bool $env:ALLOW_REPLAY          $cfg.AllowReplay
$cfg.DynamicWeather      = To-Bool $env:DYNAMIC_WEATHER       $cfg.DynamicWeather
$cfg.WhitelistEnabled    = To-Bool $env:WHITELIST_ENABLED     $cfg.WhitelistEnabled
$cfg.SpawnPlants         = To-Bool $env:SPAWN_PLANTS          $cfg.SpawnPlants
$cfg.EnableMigration     = To-Bool $env:ENABLE_MIGRATION      $cfg.EnableMigration
$cfg.EnableMassMigration = To-Bool $env:ENABLE_MASS_MIGRATION $cfg.EnableMassMigration
$cfg.EnablePatrolZones   = To-Bool $env:ENABLE_PATROL_ZONES   $cfg.EnablePatrolZones

# ---------------------------------------------------------------------------
# 3) JSON OVERLAY (Primal Hosted). Optional; overrides everything above.
#    Shape: { "ServerName": "...", "MaxPlayers": 200, "AllowedClasses": [...],
#             "AdminSteamIds": [...], "extra": { "ServerDayLengthMinutes": "60", ... } }
# ---------------------------------------------------------------------------
$overlay = Join-Path $tmpl 'server-config.json'
if (Test-Path $overlay) {
    Write-Host "(config) applying Primal Hosted overlay: server-config.json"
    $o = Get-Content $overlay -Raw | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) {
        switch ($p.Name) {
            'AdminSteamIds'  { $cfg.AdminSteamIds  = @($p.Value) }
            'VipSteamIds'    { $cfg.VipSteamIds    = @($p.Value) }
            'AllowedClasses' { $cfg.AllowedClasses = @($p.Value) }
            'extra'          { foreach ($e in $p.Value.PSObject.Properties) { $cfg.Extra[$e.Name] = "$($e.Value)" } }
            default          { if ($cfg.ContainsKey($p.Name)) { $cfg[$p.Name] = "$($p.Value)" } }
        }
    }
}

# ---------------------------------------------------------------------------
# 1b) Update (skippable via AUTO_UPDATE=0)
# ---------------------------------------------------------------------------
if ($env:AUTO_UPDATE -ne '0' -and (Test-Path $steam)) {
    $binDir    = Join-Path $game 'TheIsle\Binaries'
    $steamApps = Join-Path $game 'steamapps'
    $exeChk    = Join-Path $game 'TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe'

    # FORCE_CLEAN_UPDATE: the Isle devs periodically ship an update SteamCMD refuses to
    # apply cleanly (stale appmanifest) - the server keeps booting the OLD code while
    # `validate` reports "up to date". The known manual fix is to delete BOTH
    # /TheIsle/Binaries and /steamapps so SteamCMD re-pulls from scratch. This flag is
    # that button as an egg var: set FORCE_CLEAN_UPDATE=1, restart once, set it back to 0.
    # (Content under /TheIsle/Content stays on disk, so this re-validates - it does NOT
    # re-download the whole ~70GB, only the wiped Binaries + a full verify pass.)
    if ($env:FORCE_CLEAN_UPDATE -eq '1') {
        Write-Host "(update) FORCE_CLEAN_UPDATE=1 - deleting /TheIsle/Binaries + /steamapps for a clean re-pull..."
        if (Test-Path $binDir)    { Remove-Item -Recurse -Force $binDir    -ErrorAction SilentlyContinue }
        if (Test-Path $steamApps) { Remove-Item -Recurse -Force $steamApps -ErrorAction SilentlyContinue }
    }

    Write-Host "(update) $(Get-Date -Format HH:mm:ss) validating The Isle: Evrima (412680, evrima)..."
    & $steam +force_install_dir $game +login anonymous +app_update 412680 -beta evrima validate +quit

    # SELF-HEAL: a corrupt appmanifest / half-written 'downloading' (the 2026-07-09
    # Evrima update outage) wedges the update so the binary never lands. If it's missing
    # after the update, nuke BOTH /TheIsle/Binaries AND /steamapps and retry once - a
    # clean re-fetch. (Binaries too, not just steamapps: a partial/stale exe survives a
    # steamapps-only wipe and keeps `validate` thinking the install is whole.)
    if (-not (Test-Path $exeChk)) {
        Write-Host "(update) (self-heal) binary missing after update - deleting /TheIsle/Binaries + /steamapps and retrying once..."
        if (Test-Path $binDir)    { Remove-Item -Recurse -Force $binDir    -ErrorAction SilentlyContinue }
        if (Test-Path $steamApps) { Remove-Item -Recurse -Force $steamApps -ErrorAction SilentlyContinue }
        & $steam +force_install_dir $game +login anonymous +app_update 412680 -beta evrima validate +quit
    }

    # Surface the installed build id so staleness is visible in the console/logs.
    $manifest = Join-Path $steamApps 'appmanifest_412680.acf'
    if (Test-Path $manifest) {
        $bidMatch = Select-String -Path $manifest -Pattern '"buildid"\s+"(\d+)"' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bidMatch) { Write-Host "(update) installed buildid = $($bidMatch.Matches.Groups[1].Value)" }
    }
} else {
    Write-Host "(update) skipped (AUTO_UPDATE=0 or steamcmd missing)"
}
Dbg "update phase done"

# ---------------------------------------------------------------------------
# RENDER Game.ini + Engine.ini  (AFTER update, BEFORE launch)
# ---------------------------------------------------------------------------
$cfgDir = Join-Path $game 'TheIsle\Saved\Config\WindowsServer'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

# --- Game.ini: build the repeated-line [tigamestatebase] block from lists ---
$block = New-Object System.Collections.Generic.List[string]
if ($cfg.AdminSteamIds.Count) { foreach ($id in $cfg.AdminSteamIds) { $block.Add("AdminsSteamIDs=$id") } } else { $block.Add('AdminsSteamIDs=0') }
if ($cfg.VipSteamIds.Count)   { foreach ($id in $cfg.VipSteamIds)   { $block.Add("VIPs=$id") } }           else { $block.Add('VIPs=0') }
$classes = if ($cfg.AllowedClasses.Count) { $cfg.AllowedClasses } else { $defaultClasses }
foreach ($c in $classes) { $block.Add("AllowedClasses=$c") }

$scalars = @{
    '{{ServerName}}'            = $cfg.ServerName
    '{{MaxPlayers}}'            = $cfg.MaxPlayers
    '{{ServerPasswordEnabled}}' = $cfg.ServerPasswordEnabled
    '{{ServerPassword}}'        = $cfg.ServerPassword
    '{{RconEnabled}}'           = $cfg.RconEnabled
    '{{RconPassword}}'          = $cfg.RconPassword
    '{{Discord}}'               = $cfg.Discord
    '{{CorpseDecay}}'           = $cfg.CorpseDecay
    '{{EnableHumans}}'          = $cfg.EnableHumans
    '{{DayLength}}'             = $cfg.DayLength
    '{{NightLength}}'           = $cfg.NightLength
    '{{GrowthMultiplier}}'      = $cfg.GrowthMultiplier
    '{{EnableGlobalChat}}'      = $cfg.EnableGlobalChat
    '{{EnableAI}}'              = $cfg.EnableAI
    '{{AIDensity}}'             = $cfg.AIDensity
    '{{SpawnFish}}'             = $cfg.SpawnFish
    '{{EnableMutations}}'       = $cfg.EnableMutations
    '{{EnableDiets}}'           = $cfg.EnableDiets
    '{{FallDamage}}'            = $cfg.FallDamage
    '{{AllowReplay}}'           = $cfg.AllowReplay
    '{{DynamicWeather}}'        = $cfg.DynamicWeather
    '{{WhitelistEnabled}}'      = $cfg.WhitelistEnabled
    '{{SpawnPlants}}'           = $cfg.SpawnPlants
    '{{PlantMultiplier}}'       = $cfg.PlantMultiplier
    '{{EnableMigration}}'       = $cfg.EnableMigration
    '{{EnableMassMigration}}'   = $cfg.EnableMassMigration
    '{{EnablePatrolZones}}'     = $cfg.EnablePatrolZones
    '{{GamePort}}'              = "$env:SERVER_PORT"    # game + query
    '{{QueuePort}}'             = "$env:SERVER_PORT_1"
    '{{RconPort}}'              = "$env:SERVER_PORT_2"
    '{{GAMESTATEBASE}}'         = ($block -join "`r`n")
}
$gi = Get-Content (Join-Path $tmpl 'Game.ini.tmpl') -Raw
foreach ($k in $scalars.Keys) { $gi = $gi.Replace($k, [string]$scalars[$k]) }

# --- overlay "extra": generic [tigamesession] key setter (override anything) ---
foreach ($k in $cfg.Extra.Keys) {
    $line = "$k=$($cfg.Extra[$k])"
    if ($gi -match "(?m)^\s*$([regex]::Escape($k))\s*=") { $gi = $gi -replace "(?m)^\s*$([regex]::Escape($k))\s*=.*$", $line }
    else { $gi = $gi -replace "(?m)^(\[/script/theisle\.tigamesession\]\r?\n)", "`$1$line`r`n" }
}
Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
Write-Host "(config) rendered Game.ini (players=$($cfg.MaxPlayers), classes=$($classes.Count), admins=$($cfg.AdminSteamIds.Count), vips=$($cfg.VipSteamIds.Count))"

# --- Engine.ini: static template (EOS creds etc.), copied verbatim ---
Copy-Item (Join-Path $tmpl 'Engine.ini.tmpl') (Join-Path $cfgDir 'Engine.ini') -Force
Write-Host "(config) wrote Engine.ini"

# Dry-run hook: render the configs and stop (used for local tests + Primal Hosted
# config preview/validation). Set PRIMAL_RENDER_ONLY=1 to skip update + launch.
if ($env:PRIMAL_RENDER_ONLY -eq '1') { Write-Host '(render-only) done'; exit 0 }

# ---------------------------------------------------------------------------
# PRIMAL DLL MOD (Evrima = IsleModRebuild.dll). Mirrors the Legacy pipeline:
#   download-by-version (manifest {version,dll_url,sha256}, re-download only on
#   change) -> write isle_mod.ini BESIDE the DLL (module dir - config.cpp reads
#   module_directory()/isle_mod.ini) -> inject post-boot (armed below). Publish
#   new versions with isle_mod_rebuild/publish_dll.py. Evrima manifest is a
#   SEPARATE key from Legacy's (primal-mod-evrima/latest.json).
# ---------------------------------------------------------------------------
$primalDir     = $tmpl                                 # _primal (same dir the wrapper + overlay live in)
$primalDll     = Join-Path $primalDir 'IsleModRebuild.dll'
$primalVerFile = Join-Path $primalDir 'primal-mod.version'
if ($env:ENABLE_PRIMAL_MOD -eq '1') {
    $manifestUrl = EnvOr $env:PRIMAL_MOD_MANIFEST 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-mod-evrima/latest.json'
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
    # commands using its own phsk_ key. Keys match isle_mod_rebuild/src/config.cpp
    # (bearer_token / command_poll_url / telemetry_push_url + intervals). Written
    # beside the DLL where load_config() reads it. Re-written every boot, so a
    # config change takes effect on the next server restart.
    if ($env:PHSK_KEY) {
        $dataBase = EnvOr $env:PRIMAL_DATA_BASE 'https://data.primalhosted.com'
        $cfg = @(
            '# Primal Hosted - auto-generated each boot from the server phsk_ key. Do not edit.',
            "bearer_token=$($env:PHSK_KEY)",
            "command_poll_url=$dataBase/v1/commands",
            'command_poll_interval_ms=2000',
            "telemetry_push_url=$dataBase/v1/telemetry",
            'telemetry_push_interval_ms=5000'
        ) -join "`n"
        Set-Content -Path (Join-Path $primalDir 'isle_mod.ini') -Value $cfg -Encoding ascii
        Write-Host "(primal-mod) wrote isle_mod.ini (per-server key, poll=$dataBase/v1/commands, telemetry=$dataBase/v1/telemetry)"
    } else {
        Write-Host "(primal-mod) no PHSK_KEY set - mod will run without a data-plane key"
    }
} else {
    Write-Host "(primal-mod) disabled (ENABLE_PRIMAL_MOD != 1)"
}

# ---------------------------------------------------------------------------
# LAUNCH (foreground; Ptero restarts on exit). -stdout so feathers captures console.
#
# Launch the REAL Shipping binary directly, NOT the 0.23MB root TheIsleServer.exe
# thin launcher: the launcher spawns the server then exits, so the wrapper would
# return and feathers would (wrongly) flag a crash. Running Shipping directly
# means the wrapper blocks on the actual server process for its whole lifetime.
#
# Args are DOUBLE-QUOTED so PowerShell expands the variables — `-Port=$env:X`
# (bareword) is passed literally by PS; `"-Port=$env:X"` expands correctly.
# ---------------------------------------------------------------------------
$exe = Join-Path $game 'TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe'
if (-not (Test-Path $exe)) { throw "server binary missing: $exe (did SteamCMD finish?)" }

# Multihome: bind/advertise ONE specific public IP so a box with several IPs gives
# each server its own address - the key to per-server DDoS isolation (one null-routed
# IP only downs its own server, not everyone on the box). MULTIHOME_IP (egg var) wins;
# otherwise the allocation IP feathers injects as SERVER_IP. If neither is a real IPv4
# (empty / 0.0.0.0), omit -MULTIHOME entirely so the server binds all interfaces -
# single-IP boxes keep working unchanged.
#
# ⭐ THE CRITICAL PART (solved 2026-07-14 after a long hunt): -MULTIHOME only BINDS
# the socket to the IP. The Isle's EOS integration still ADVERTISES the box's PRIMARY
# egress IP to the server browser, so clients connect to primary:queueport and never
# reach a server on a secondary IP. The undocumented Redpoint EOS env var
# `EOS_OVERRIDE_HOST_IP` (found in the shipping binary, feeds EOS_SessionModification_
# SetHostAddress) forces EOS to advertise THIS IP instead. Setting it == the multihome
# IP is what makes per-IP isolation actually work end-to-end. Proven: client log
# `Queue: connecting to queue socket <secondaryIP>:<port>`. See isle_evrima_egg/PER_IP_DDOS_ISOLATION.md.
$multihome = EnvOr $env:MULTIHOME_IP $env:SERVER_IP
$mhArgs = @()
if ($multihome -and $multihome -ne '0.0.0.0' -and $multihome -match '^\d{1,3}(\.\d{1,3}){3}$') {
    $mhArgs = @("-MULTIHOME=$multihome")
    $env:EOS_OVERRIDE_HOST_IP = $multihome   # <-- makes EOS advertise the multihome IP (per-IP isolation)
    Write-Host "(start) EOS_OVERRIDE_HOST_IP=$multihome (advertise this IP to the server browser)"
} else {
    $multihome = '(all interfaces)'
}
# Force-enable non-default playable species (egg var PRIMAL_FORCE_DINO, comma-
# separated species names, e.g. "Oviraptor,Baryonyx"). Empty = the flag is
# OMITTED entirely — a bare "-PrimalForceDino=" is never emitted, so every
# server that leaves the variable blank launches byte-identically to before.
# Ice 2026-07-29: per-server species force-enable is a first-class capability
# (#356/#378); needed the moment the mod's storage restores a forced species.
$forceDino = ('' + $env:PRIMAL_FORCE_DINO).Trim()
$fdArgs = @()
if ($forceDino) {
    $fdArgs = @("-PrimalForceDino=$forceDino")
    Write-Host "(start) PrimalForceDino=$forceDino (force-enabled species)"
}
Write-Host "(start) $(Get-Date -Format HH:mm:ss) launching on port $env:SERVER_PORT, multihome $multihome ..."
# CRITICAL: relax the error preference for the launch. Under 'Stop', the UE
# server writing ANYTHING to stderr raises a NativeCommandError that terminates
# this wrapper mid-run — the already-spawned server keeps running (orphaned),
# but feathers sees the wrapper exit and (wrongly) flags a crash + detaches the
# console. 'Continue' lets stderr flow to the console without killing us.
$ErrorActionPreference = 'Continue'
$isleLog = Join-Path $game 'TheIsle\Saved\Logs\TheIsle.log'
$before  = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

# Primal DLL mod injection: arm a background job that waits for the NEW server
# process, then LoadLibraryW-injects the DLL via CreateRemoteThread (P/Invoke, no
# Python in the container). Same technique as isle_mod_rebuild/inject_isle_mod.py.
# Result -> _primal/primal-inject.log.
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
        # LoadLibraryW's return (the HMODULE, low 32 bits here) is the remote thread's
        # exit code: 0 => the DLL failed to load (bad deps / wrong bitness / crash in
        # DllMain). Non-zero => it loaded.
        $ec = 0; [void][PInj]::GetExitCodeThread($t, [ref]$ec)
        W "inject call complete (LoadLibraryW exit=0x$("{0:x}" -f $ec); 0 = load FAILED)"
        # Independent confirmation: is the DLL actually in the target's module list?
        Start-Sleep -Seconds 2
        $name = [IO.Path]::GetFileName($dll)
        try {
            $mod = Get-Process -Id $proc.Id -Module -ErrorAction Stop | Where-Object { $_.ModuleName -ieq $name }
            if ($mod) { W "VERIFIED: $name is loaded in pid $($proc.Id)  ($($mod.FileName))" }
            else      { W "WARNING: $name NOT present in pid $($proc.Id) module list after inject" }
        } catch { W "module verify inconclusive (enum failed: $($_.Exception.Message))" }
    } | Out-Null
    Write-Host "(primal-mod) injector armed (post-boot; result -> _primal/primal-inject.log; mod runtime -> _primal/isle_mod.log)"
}

Dbg "launching (server will detach; we supervise the real process)"
# Launch form matches Hex's proven dedicated command (map URL carries the port; no
# -QueryPort / -stdout). -MULTIHOME (dash flag) via @mhArgs + EOS_OVERRIDE_HOST_IP (env,
# set above) = the working per-IP combo.
& $exe @mhArgs @fdArgs "/Game/TheIsle/Maps/Game/Gateway/Gateway?Port=$env:SERVER_PORT" -log `
    '-ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=xyza7891gk5PRo3J7G9puCJGFJjmEguW' `
    '-ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=pKWl6t5i9NJK8gTpVlAxzENZ65P8hYzodV8Dqe5Rlc8'

# The UE server re-spawns itself detached and the launched process exits in ~3ms,
# so we can't just block on `& $exe`. Find the REAL (new) server process, then:
#  - tail its log file into OUR stdout, so feathers captures the console + sees
#    the startup "done" string, and
#  - block until it exits, so feathers keeps tracking THIS wrapper as the live
#    server (no false crash; clean restart when the game actually dies).
$proc = $null
for ($i = 0; $i -lt 30 -and -not $proc; $i++) {
    Start-Sleep -Milliseconds 500
    $proc = Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } | Select-Object -First 1
}
if (-not $proc) { Dbg "ERROR: server process never appeared after launch"; exit 1 }
Dbg "supervising server pid $($proc.Id)"

$pos = 0
while (-not $proc.HasExited) {
    if (Test-Path $isleLog) {
        try {
            $fs = [IO.File]::Open($isleLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            if ($fs.Length -lt $pos) { $pos = 0 }   # log rotated on relaunch
            if ($fs.Length -gt $pos) {
                $fs.Position = $pos
                $sr = New-Object IO.StreamReader($fs)
                $txt = $sr.ReadToEnd(); if ($txt) { [Console]::Out.Write($txt) }
                $pos = $fs.Position; $sr.Dispose()
            }
            $fs.Dispose()
        } catch { }
    }
    Start-Sleep -Milliseconds 750
    $proc.Refresh()
}
Dbg "server pid $($proc.Id) exited"
Write-Host "(exit) $(Get-Date -Format HH:mm:ss) server process ended; Ptero will restart per policy."
