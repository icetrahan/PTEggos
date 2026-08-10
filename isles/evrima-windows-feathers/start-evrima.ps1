# Primal — The Isle: Evrima startup wrapper (feathers / native-Windows node).
#
# Each boot: SteamCMD update -> RENDER Game.ini/Engine.ini from data -> launch.
# Game.ini is a DERIVED artifact, regenerated every boot from the settings below.
# The customer never edits Game.ini directly (The Isle corrupts it) - they edit
# DATA, and we render fresh each boot. Corruption becomes a non-issue.
#
# Settings come from ONE place (Ice's ruling, 2026-08-10 - supersedes #24/#356):
#   1. DEFAULTS (below)   baseline, used ONLY when the plane has never been reached
#   2. THE DATA PLANE     >> THE SINGLE SOURCE OF TRUTH. `GET /v1/boot-config`,
#      authenticated with this server's own phsk key. The customer's Primal Hosted
#      panel writes it; this script fetches and renders. Last-known-good is cached
#      to _primal/boot-config.cache.json so a plane outage cannot stop a boot.
#
# ⛔ THE server-config.json OVERLAY IS GONE. It was a file nothing on the platform
#    could write, and it silently outranked the customer's panel - it froze Dino
#    Vibes' admin list in BOTH directions (an add and a removal both discarded,
#    both sides reading 17, so every count check passed). #1101/#450/#20.
#    ⛔ Do not reintroduce it, and do not add a customer setting as an egg
#    variable: egg variables are BOOTSTRAP ONLY now (see section 2).
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
# 🔴 THE SERVER KEY, TRIMMED ONCE, USED EVERYWHERE.
#
# The panel's API reports this variable as 53 chars, but the value injected into
# the container carried a trailing character - the mod booted `tokenlen=54` for a
# 53-char phsk_ key and every data-plane / rt call 401'd. Auth is a SHA-256 hash
# lookup, so one stray byte doesn't degrade it, it misses the row entirely.
# Trim here, at the single point of entry, so the launch flag and Engine.ini can
# never disagree or carry whitespace again. Never log the value - length only.
# ---------------------------------------------------------------------------
# ⚠️ DEFENCE-IN-DEPTH ONLY - this is NOT the fix for the tokenlen=54 bug.
#
# Settled by measurement 2026-07-29, do not re-derive:
#   * This block has NEVER stripped a byte in production. Every boot logs
#     `rawLen=53 finalLen=53 strippedBytes=0`.
#   * The panel TRIMS trailing whitespace on write, so a dirty value cannot even
#     be stored in the egg variable. Tested: wrote key+space (54 B), panel stored
#     53 B, sha256 unchanged. Via the panel path this code is UNREACHABLE.
#   * What actually fixed tokenlen=54 was removing the SECOND token source
#     (-PrimalToken, see the launch section) - BUGS #436. 05:29 boot and 05:33
#     boot differed ONLY by that flag: 54 -> 53, with this block present and
#     inert in both.
#
# It stays because it is free and it covers a write path the panel doesn't police
# (a direct panel-DB edit, a future provisioning script). ⛔ But do NOT treat it
# as the thing keeping auth alive, and do NOT "simplify" the launch flag back on
# because this looks like it would catch the result - it would not. The two
# load-bearing pieces are: -PrimalToken OFF, and Engine.ini written with LF.
#
# Extract the key by its own shape: phsk_ + 48 hex chars. Whatever surrounds it -
# quote, semicolon, NUL, BOM, newline - is discarded. Falls back to the trimmed
# raw value if the pattern doesn't match, so a future key-format change degrades
# to today's behaviour instead of silently blanking the token.
$phskRaw = '' + $env:PHSK_KEY
$phsk    = $phskRaw.Trim()
$phskM   = [regex]::Match($phskRaw, 'phsk_[0-9a-fA-F]{48}')
if ($phskM.Success) { $phsk = $phskM.Value }
Dbg ("phsk key: rawLen={0} finalLen={1} patternMatched={2} strippedBytes={3}" -f `
     $phskRaw.Length, $phsk.Length, $phskM.Success, ($phskRaw.Length - $phsk.Length))
if ($phskRaw.Length -ne $phsk.Length) {
    # Byte codes of everything we removed - names the culprit exactly once, no secret.
    $extra = ($phskRaw.ToCharArray() | Where-Object { $phsk.IndexOf($_) -lt 0 } | ForEach-Object { [int]$_ }) -join ','
    Dbg ("phsk key: stripped char codes=[{0}]" -f $extra)
}

# ---------------------------------------------------------------------------
# 1) DEFAULTS
# ---------------------------------------------------------------------------
$defaultClasses = @(
    'Dryosaurus','Hypsilophodon','Maiasaura','Pachycephalosaurus','Stegosaurus',
    'Tenontosaurus','Carnotaurus','Ceratosaurus','Deinosuchus','Dilophosaurus',
    'Herrerasaurus','Omniraptor','Pteranodon','Troodon','Beipiaosaurus','Gallimimus',
    'Diabloceratops','Triceratops','Allosaurus','Tyrannosaurus','Kentrosaurus',
    'Austroraptor'
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
    # ---- gameplay knobs (customer-configurable; canonical values come from
    #      the data plane's `server_settings` block - these are the FIRST-BOOT
    #      fallback only, and must stay equal to that block's declared defaults) ----
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
    MapName               = 'Gateway'
    QueueEnabled          = 'True'
    # Empty = the AISpawnInterval line is OMITTED from Game.ini entirely (the game
    # then uses its own internal default). Same idiom as -PrimalForceDino: we do not
    # know the engine default, so we refuse to guess one and pin it on every server.
    AISpawnInterval       = ''
}
# ⛔ `Extra` IS GONE (Ice, 2026-08-10). It was the overlay's generic
# `[tigamesession]` key setter - it could write ANY key under a name no allowlist
# checked, so it could set MaxPlayerCount or RCON behind the panel's back. The
# replacement for "a Game.ini key with no field" is to add it to the data plane's
# `server_settings` block, which is a plane deploy - cheaper than an egg import,
# and visible in the panel. ⛔ Do not reintroduce a generic key setter here.

# ---------------------------------------------------------------------------
# 2) CANONICAL CONFIG — fetched from the data plane (Ice's ruling, 2026-08-10)
# ---------------------------------------------------------------------------
# ⭐ THIS IS THE SINGLE SOURCE OF TRUTH. It supersedes DECISIONS #24/#356, under
# which egg VARIABLES were canonical and this script layered
# defaults -> egg vars -> the server-config.json overlay.
#
# WHY IT CHANGED. Config lived in FIVE places that disagreed, and the overlay —
# a file NOTHING on the platform could write — silently outranked the customer's
# panel. Measured on Dino Vibes: the panel listed 17 admins INCLUDING Ice, the
# overlay listed 17 EXCLUDING him, and Game.ini rendered the overlay's. Worse,
# the freeze ran BOTH ways: an admin the owner had REMOVED was still live. One
# add and one removal cancelled out, so both lists read 17 and every count-based
# check ever run on that server passed (BUGS #1101, #450, #20).
#
# NOW: the panel writes the data plane; this script FETCHES and renders. Egg
# variables are BOOTSTRAP ONLY (PHSK_KEY, ports, AUTO_UPDATE, ENABLE_PRIMAL_MOD,
# FORCE_CLEAN_UPDATE, MULTIHOME_IP, PRIMAL_MOD_MANIFEST). ⛔ Do NOT re-add a
# customer setting as an egg variable — that is how we get back to two stores.
#
# 🔴 THE FAIL-SAFE LADDER, AND ALL THREE RUNGS MUST STAY DISTINGUISHABLE.
# A server MUST boot when the plane is unreachable, but it must NEVER quietly
# render something other than what the owner saved. Hard rule 13: a skip is not
# a success, and an unconfigured boot with a clean log is a server with NO
# ADMINS. Each rung below prints its own sentence and none of them says "ok".
#   1. FETCHED  -> render it, and cache it as last-known-good
#   2. CACHED   -> plane unreachable; render the cache and SAY how old it is
#   3. DEFAULTS -> no plane, no cache (first boot only); render defaults and SHOUT
# ---------------------------------------------------------------------------
$bootCache = Join-Path $tmpl 'boot-config.cache.json'
$cfgSource = 'defaults'
$canon     = $null

if ($phsk) {
    $dataBaseCfg = (EnvOr $env:PRIMAL_DATA_BASE 'https://data.primalhosted.com').TrimEnd('/')
    try {
        $ProgressPreference = 'SilentlyContinue'
        $canon = Invoke-RestMethod -Uri "$dataBaseCfg/v1/boot-config" -Headers @{ Authorization = "Bearer $phsk" } -TimeoutSec 20
        $cfgSource = 'fetched'
        # Cache only a FETCH. Writing the cache on any other path would let a
        # degraded boot overwrite the last known-good with something worse.
        try { ($canon | ConvertTo-Json -Depth 12) | Out-File -FilePath $bootCache -Encoding utf8 -Force } catch {
            Write-Host "(config) WARNING could not write boot-config cache: $($_.Exception.Message)"
        }
    } catch {
        $why = $_.Exception.Message
        if (Test-Path $bootCache) {
            try {
                $canon = Get-Content $bootCache -Raw | ConvertFrom-Json
                $cfgSource = 'cache'
                $age = (New-TimeSpan -Start (Get-Item $bootCache).LastWriteTimeUtc -End (Get-Date).ToUniversalTime())
                Write-Host ""
                Write-Host "(config) *** DATA PLANE UNREACHABLE - RENDERING FROM CACHE ***"
                Write-Host "(config)     reason: $why"
                Write-Host ("(config)     cache written {0:N0} min ago (updatedAt={1})" -f $age.TotalMinutes, $canon.updatedAt)
                Write-Host "(config)     ⚠ ANY PANEL CHANGE SINCE THEN IS NOT APPLIED ON THIS BOOT."
                Write-Host ""
            } catch {
                Write-Host "(config) *** CACHE PRESENT BUT UNREADABLE ($($_.Exception.Message)) - falling through to defaults ***"
                $canon = $null
            }
        } else {
            Write-Host "(config) plane unreachable and no cache: $why"
        }
    }
} else {
    Write-Host "(config) no PHSK_KEY - cannot fetch canonical config"
}

if (-not $canon) {
    Write-Host ""
    Write-Host "(config) *** NO CANONICAL CONFIG AND NO CACHE - THIS SERVER IS UNCONFIGURED ***"
    Write-Host "(config)     Booting on built-in defaults: NO ADMINS, NO VIPs, default dino roster."
    Write-Host "(config)     Expected only on a server's FIRST boot. Otherwise the plane or the key is wrong."
    Write-Host ""
}
Dbg "canonical config source=$cfgSource"

# --- map the canonical block onto $cfg -------------------------------------
# Every field is applied ONLY when the block actually carries it, so a plane
# that ships a NEW field before this wrapper knows it cannot blank an old one.
$ss = $null; $ms = $null
if ($canon -and $canon.config) { $ss = $canon.config.server_settings; $ms = $canon.config.mod_settings }

function Has($o, [string]$n) { return ($null -ne $o) -and ($null -ne $o.PSObject.Properties[$n]) }
function PsBool($v) { if ($v) { return 'True' } else { return 'False' } }

if ($ss) {
    if (Has $ss 'serverName')            { $cfg.ServerName            = [string]$ss.serverName }
    if (Has $ss 'maxPlayers')            { $cfg.MaxPlayers            = [string]$ss.maxPlayers }
    if (Has $ss 'serverPassword')        { $cfg.ServerPassword        = [string]$ss.serverPassword }
    if (Has $ss 'rconPassword')          { $cfg.RconPassword          = [string]$ss.rconPassword }
    if (Has $ss 'discordUrl')            { $cfg.Discord               = [string]$ss.discordUrl }
    if (Has $ss 'corpseDecay')           { $cfg.CorpseDecay           = [string]$ss.corpseDecay }
    if (Has $ss 'serverPasswordEnabled') { $cfg.ServerPasswordEnabled = PsBool $ss.serverPasswordEnabled }
    if (Has $ss 'rconEnabled')           { $cfg.RconEnabled           = PsBool $ss.rconEnabled }
    # Lists: an EMPTY array is a legitimate value meaning "none" (admins/vips) or
    # "use the default roster" (classes) — @() below, never a skip.
    if (Has $ss 'adminSteamIds')  { $cfg.AdminSteamIds  = @($ss.adminSteamIds) }
    if (Has $ss 'vipSteamIds')    { $cfg.VipSteamIds    = @($ss.vipSteamIds) }
    if (Has $ss 'allowedClasses') { $cl = @($ss.allowedClasses); if ($cl.Count) { $cfg.AllowedClasses = $cl } }
    if (Has $ss 'dayLengthMin')       { $cfg.DayLength        = [string]$ss.dayLengthMin }
    if (Has $ss 'nightLengthMin')     { $cfg.NightLength      = [string]$ss.nightLengthMin }
    if (Has $ss 'growthMultiplier')   { $cfg.GrowthMultiplier = [string]$ss.growthMultiplier }
    if (Has $ss 'aiDensity')          { $cfg.AIDensity        = [string]$ss.aiDensity }
    if (Has $ss 'plantMultiplier')    { $cfg.PlantMultiplier  = [string]$ss.plantMultiplier }
    if (Has $ss 'enableHumans')       { $cfg.EnableHumans        = PsBool $ss.enableHumans }
    if (Has $ss 'enableGlobalChat')   { $cfg.EnableGlobalChat    = PsBool $ss.enableGlobalChat }
    if (Has $ss 'enableAi')           { $cfg.EnableAI            = PsBool $ss.enableAi }
    if (Has $ss 'spawnFish')          { $cfg.SpawnFish           = PsBool $ss.spawnFish }
    if (Has $ss 'enableMutations')    { $cfg.EnableMutations     = PsBool $ss.enableMutations }
    if (Has $ss 'enableDiets')        { $cfg.EnableDiets         = PsBool $ss.enableDiets }
    if (Has $ss 'fallDamage')         { $cfg.FallDamage          = PsBool $ss.fallDamage }
    if (Has $ss 'allowReplay')        { $cfg.AllowReplay         = PsBool $ss.allowReplay }
    if (Has $ss 'dynamicWeather')     { $cfg.DynamicWeather      = PsBool $ss.dynamicWeather }
    if (Has $ss 'whitelistEnabled')   { $cfg.WhitelistEnabled    = PsBool $ss.whitelistEnabled }
    if (Has $ss 'spawnPlants')        { $cfg.SpawnPlants         = PsBool $ss.spawnPlants }
    if (Has $ss 'enableMigration')    { $cfg.EnableMigration     = PsBool $ss.enableMigration }
    if (Has $ss 'enableMassMigration'){ $cfg.EnableMassMigration = PsBool $ss.enableMassMigration }
    if (Has $ss 'enablePatrolZones')  { $cfg.EnablePatrolZones   = PsBool $ss.enablePatrolZones }
    if (Has $ss 'mapName')            { $cfg.MapName             = [string]$ss.mapName }
    if (Has $ss 'queueEnabled')       { $cfg.QueueEnabled        = PsBool $ss.queueEnabled }
    # Empty is NOT zero: it omits the Game.ini line so the game's own default stands.
    if (Has $ss 'aiSpawnInterval')    { $cfg.AISpawnInterval     = [string]$ss.aiSpawnInterval }

    Write-Host ("(config) canonical config {0} (admins={1} vips={2} classes={3} players={4} scope={5} updatedAt={6})" -f `
        $cfgSource.ToUpper(), $cfg.AdminSteamIds.Count, $cfg.VipSteamIds.Count, $cfg.AllowedClasses.Count, `
        $cfg.MaxPlayers, $canon.scope.server_settings, $canon.updatedAt)
}

# 🔴 #1097 — the seat cap. The plane REFUSES an over-cap write, but it can only
# CLAMP on read (a server must boot), so it reports what it clamped. Never let
# that pass silently: a player count the owner did not choose is exactly the
# "saved, but not what you asked for" class this whole change exists to kill.
if ($canon -and $canon.clamped) {
    foreach ($cl in @($canon.clamped)) {
        Write-Host "(config) *** CLAMPED BY ENTITLEMENT: $($cl.key).$($cl.field) stored=$($cl.stored) -> applied=$($cl.applied) (your plan's limit)"
        Dbg "entitlement clamp $($cl.key).$($cl.field) $($cl.stored)->$($cl.applied)"
    }
}

# --- LEGACY EGG VARIABLES: gone, and deliberately not silently ---------------
# If a customer setting is still set as an egg variable, it is NO LONGER READ.
# Say so once, loudly, rather than letting someone edit a dead field for a week.
$deadVars = @('SERVER_NAME','MAX_PLAYERS','ADMIN_STEAM_IDS','VIP_STEAM_IDS','ALLOWED_CLASSES',
              'SERVER_PASSWORD','SERVER_PASSWORD_ENABLED','RCON_ENABLED','RCON_PASSWORD','DISCORD_URL',
              'CORPSE_DECAY','ENABLE_HUMANS','SERVER_DAY_LENGTH','SERVER_NIGHT_LENGTH','GROWTH_MULTIPLIER',
              'ENABLE_GLOBAL_CHAT','ENABLE_AI','AI_DENSITY','SPAWN_FISH','ENABLE_MUTATIONS','ENABLE_DIETS',
              'FALL_DAMAGE','ALLOW_REPLAY','DYNAMIC_WEATHER','WHITELIST_ENABLED','SPAWN_PLANTS',
              'PLANT_MULTIPLIER','ENABLE_MIGRATION','ENABLE_MASS_MIGRATION','ENABLE_PATROL_ZONES',
              'MAP_NAME','QUEUE_ENABLED','AI_SPAWN_INTERVAL','AI_MAX_COUNT','SPECIES_CAP_LIST',
              'SPECIES_CAP_EVERY','PRIMAL_FORCE_DINO')
$stillSet = @($deadVars | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
if ($stillSet.Count -and $cfgSource -ne 'defaults') {
    Write-Host "(config) NOTE $($stillSet.Count) legacy egg variable(s) are still set and are NO LONGER READ (config now comes from the panel):"
    Write-Host "(config)      $($stillSet -join ', ')"
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
    '{{MapName}}'               = $cfg.MapName
    '{{QueueEnabled}}'          = $cfg.QueueEnabled
    '{{AISpawnInterval}}'       = $cfg.AISpawnInterval
    '{{GamePort}}'              = "$env:SERVER_PORT"    # game + query
    '{{QueuePort}}'             = "$env:SERVER_PORT_1"
    '{{RconPort}}'              = "$env:SERVER_PORT_2"
    '{{GAMESTATEBASE}}'         = ($block -join "`r`n")
}
$gi = Get-Content (Join-Path $tmpl 'Game.ini.tmpl') -Raw
foreach ($k in $scalars.Keys) { $gi = $gi.Replace($k, [string]$scalars[$k]) }

# AISpawnInterval is OPT-IN: an unset variable removes the line entirely rather than
# pinning a guessed engine default on every server. Stripped by name (never "drop all
# empty values") because ServerPassword= legitimately renders empty.
if ([string]::IsNullOrWhiteSpace($cfg.AISpawnInterval)) {
    $gi = $gi -replace "(?m)^\s*AISpawnInterval\s*=\s*\r?\n", ''
}

Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
Write-Host ("(config) rendered Game.ini from {0} config (players={1}, classes={2}, admins={3}, vips={4})" -f `
            $cfgSource, $cfg.MaxPlayers, $classes.Count, $cfg.AdminSteamIds.Count, $cfg.VipSteamIds.Count)

# --- Engine.ini: static template (EOS creds etc.) + the Primal mod's config section ---
#
# ⭐ The pak mod reads its per-server key as a UE *Config* property on the game
# session BP class, i.e. from Engine.ini under that class's section - NOT only
# from the -PrimalToken launch flag. The proven-live reference server carries:
#
#   [/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]
#   ApiToken=<phsk key>
#   PollURL=<data base>/v1/commands/text
#
# Without this section the pak loads but has no token and no poll URL, so it
# never authenticates - which is exactly why a stock-provisioned server showed
# "no token in engine.ini". We render it from $env:PHSK_KEY every boot (the key
# is NEVER stored in the template - the template stays secret-free, rule 10).
# -PrimalToken is still passed on the launch line as the override path.
$eng = Get-Content (Join-Path $tmpl 'Engine.ini.tmpl') -Raw

# --- pak config keys that are NOT the token ---------------------------------
# #501: GetCommandLine() returns nothing in a cooked server build, so the pak
# reads these from Engine.ini. -PrimalForceDino is still passed on the launch
# line below, but it is INERT - the ini key is what the pak actually loads.
# #572: config ARRAYS do not load. Every value here is ONE csv STRING.
# ⭐ THESE WERE FLEET-WIDE LITERALS UNTIL 2026-08-10. Ice ruled them PER-SERVER
# (*"yes, with defaults: treeknockdownon = false and well... the rest whatever we
# has set now is defaults"*), so they now come from the data plane's
# `mod_settings` block. The values below are the FIRST-BOOT fallback and are
# byte-identical to what this script used to hardcode - a server that has never
# reached the plane still renders exactly the Engine.ini it rendered before.
#
# ⛔⛔ `BodyHoldSet` / `BSLiftSet` ARE NOT SETTINGS AND ARE NOT IN THE BLOCK.
# They are #1071 WIRE SENTINELS: the pak reads a numeric key as UNSET (keeping
# its baked default) unless the paired `*Set=True` is present too. Exposing one
# as a panel field would ship a checkbox that, left off, makes `BodyHoldSec`
# SILENTLY do nothing - #1071 re-created, customer-facing. They are DERIVED
# below: emit the number => emit its sentinel, always, together, never apart.
$modDefaults = [ordered]@{
    BodySweepOn     = 'True'
    BodySweepList   = 'Triceratops'
    BodyHoldSec     = '10.0'
    BodySweepLiftZ  = '150000'
    TreeKnockdownOn = 'False'
    AIMaxCount      = '40'
    SpeciesCapEvery = '30'
}
# Format a number the way this script always has, so the byte-identical render
# test is not tripped by PowerShell's own stringification (10 -> "10", not "10.0").
function ModNum($v, [string]$fallback, [int]$dp) {
    if ($null -eq $v) { return $fallback }
    try { return ([double]$v).ToString("F$dp", [Globalization.CultureInfo]::InvariantCulture) } catch { return $fallback }
}
function ModBool($v, [string]$fallback) {
    if ($null -eq $v) { return $fallback }
    if ($v -is [bool]) { if ($v) { return 'True' } else { return 'False' } }
    return (To-Bool ([string]$v) $fallback)
}
# csv on the wire, ALWAYS (#572: config ARRAYS do not load in the pak).
function ModCsv($v) {
    if ($null -eq $v) { return '' }
    return ((@($v) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' }) -join ',')
}

$pakExtra = [ordered]@{}
foreach ($k in $modDefaults.Keys) { $pakExtra[$k] = $modDefaults[$k] }

if ($ms) {
    if (Has $ms 'bodySweepOn')     { $pakExtra['BodySweepOn']     = ModBool $ms.bodySweepOn     $modDefaults.BodySweepOn }
    if (Has $ms 'treeKnockdownOn') { $pakExtra['TreeKnockdownOn'] = ModBool $ms.treeKnockdownOn $modDefaults.TreeKnockdownOn }
    if (Has $ms 'bodySweepList')   { $pakExtra['BodySweepList']   = ModCsv  $ms.bodySweepList }
    if (Has $ms 'bodyHoldSec')     { $pakExtra['BodyHoldSec']     = ModNum  $ms.bodyHoldSec     $modDefaults.BodyHoldSec 1 }
    if (Has $ms 'bodySweepLiftZ')  { $pakExtra['BodySweepLiftZ']  = ModNum  $ms.bodySweepLiftZ  $modDefaults.BodySweepLiftZ 0 }
    if (Has $ms 'aiMaxCount')      { $pakExtra['AIMaxCount']      = ModNum  $ms.aiMaxCount      $modDefaults.AIMaxCount 0 }
    if (Has $ms 'speciesCapEvery') { $pakExtra['SpeciesCapEvery'] = ModNum  $ms.speciesCapEvery $modDefaults.SpeciesCapEvery 0 }
}

# --- #1071 SENTINELS, DERIVED. Never authored, never a panel field. ------------
# Paired with their numeric by construction, so the two can no longer drift.
if ($pakExtra.Contains('BodyHoldSec'))    { $pakExtra['BodyHoldSet'] = 'True' }
if ($pakExtra.Contains('BodySweepLiftZ')) { $pakExtra['BSLiftSet']   = 'True' }

# --- EMPTY IS NOT ZERO: these two OMIT their line so the pak's own default holds.
$speciesCapList = ''
if ($ms -and (Has $ms 'speciesCapList')) { $speciesCapList = ModCsv $ms.speciesCapList }
if ($speciesCapList) { $pakExtra['SpeciesCapList'] = $speciesCapList }

# ForceDinoList: same omit-when-empty idiom. 🔴 The value lands on the game's
# LAUNCH LINE, where Compsognathus/Pterodactylus are an instant client crash and
# a bricked character (#378), so the panel validates it against an ALLOW-LIST
# before it ever reaches the plane. This script does not re-derive that list -
# it renders what the gated writer stored.
# 2026-08-03: the old hardcoded fallback was REMOVED (Isle update 24542870) -
# it silently force-RE-ADDED Baryonyx/Oviraptor after they were stripped from
# the roster, because Config_Scan hits on AllowedClasses OR ForceAllowSet.
$pakForceDino = ''
if ($ms -and (Has $ms 'forceDinoList')) { $pakForceDino = ModCsv $ms.forceDinoList }

# ⛔ PRIMAL_MOD_INI IS GONE (#1094). It was documented as the ops escape hatch
# ("overrides/extends the above with no script edit") and it was NEVER DECLARED
# IN THE EGG, so Ptero never injected it and the branch could not fire - a hatch
# that silently was not there. Per-server pak config is now a real panel surface
# (`mod_settings`), which is what that hatch was pretending to be.

# --- PrimalModLogging: an OPS OVERRIDE Ice sets by hand for testing (#1071) -----
# Deliberately NOT an egg var and NOT baked - it must default to the pak's own
# value. But the full-section REPLACE below would wipe a hand-edit, so carry
# forward any value already present in the live Engine.ini. Net effect: the egg
# never sets it, and never stomps it either.
# ⚠️ 2026-08-10: the old note here said "Ice's env hatch PRIMAL_MOD_INI still
# wins over a carried-forward value". That hatch is gone (#1094 - it was never
# declared in the egg, so it never fired), and nothing overrides this now: a
# hand-set PrimalModLogging is simply carried forward, full stop.
$preserveModLogging = $null
if (-not $pakExtra.Contains('PrimalModLogging')) {
    $liveEnginePath = Join-Path $cfgDir 'Engine.ini'
    if (Test-Path $liveEnginePath) {
        $curEng = Get-Content $liveEnginePath -Raw
        if ($curEng -match "(?m)^\s*PrimalModLogging\s*=\s*(.+?)\s*$") { $preserveModLogging = $Matches[1] }
    }
}

if ($env:ENABLE_PRIMAL_MOD -eq '1' -and $phsk) {
    $dataBase   = (EnvOr $env:PRIMAL_DATA_BASE 'https://data.primalhosted.com').TrimEnd('/')
    $sessHeader = '[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]'
    $sessLines  = New-Object System.Collections.Generic.List[string]
    $sessLines.Add($sessHeader)
    $sessLines.Add("ApiToken=$phsk")
    $sessLines.Add("PollURL=$dataBase/v1/commands/text")
    if ($pakForceDino) { $sessLines.Add("ForceDinoList=$pakForceDino") }
    foreach ($pk in $pakExtra.Keys) { $sessLines.Add("$pk=$($pakExtra[$pk])") }
    if ($preserveModLogging) {
        $sessLines.Add("PrimalModLogging=$preserveModLogging")
        Write-Host "(config) Engine.ini: preserved hand-set PrimalModLogging=$preserveModLogging (#1071)"
    }
    $sessBlock = ($sessLines -join "`r`n")
    # Idempotent: if the template ever grows this section, REPLACE it rather than
    # appending a second copy (UE takes the first, so a duplicate would silently
    # win with the wrong value).
    if ($eng -match "(?m)^\s*\[/Game/TheIsle/Core/Session/BP_TIGameSession\.BP_TIGameSession_C\]") {
        $eng = [regex]::Replace(
            $eng,
            "(?ms)^\s*\[/Game/TheIsle/Core/Session/BP_TIGameSession\.BP_TIGameSession_C\].*?(?=^\s*\[|\z)",
            ($sessBlock + "`r`n`r`n"), 1)
    } else {
        $eng = $eng.TrimEnd() + "`r`n`r`n" + $sessBlock + "`r`n"
    }
    Write-Host "(config) Engine.ini: Primal session block set (tokenlen=$($phsk.Length), poll=$dataBase/v1/commands/text)"
    Write-Host "(config) Engine.ini: pak keys ForceDinoList=$pakForceDino $(($pakExtra.Keys | ForEach-Object { "$_=$($pakExtra[$_])" }) -join ' ')"
} else {
    Write-Host "(config) Engine.ini: no Primal session block (mod disabled or no PHSK_KEY)"
}

# 🔴 LF LINE ENDINGS, DELIBERATELY - AND THIS ONE IS LOAD-BEARING.
#
# Engine.ini is now the SOLE token source (-PrimalToken is off, #436), so a CR
# here lands straight in the token. Measured: with CRLF the 04:55 boot read
# `ApiToken valueLen=54, last char code 13` and the mod booted tokenlen=54 ->
# 401 on telemetry, commands and voice alike. The proven-working reference server
# is Linux (LF-only Engine.ini) and boots 53. UE's own config parser copes with
# either - only the mod's read keeps the CR - so we write the format that is
# proven to authenticate. Use WriteAllText, NOT Set-Content: Set-Content appends
# a platform line terminator and would re-introduce a CR on the last line.
# ⛔ Do not "tidy" this back to Set-Content / CRLF. It is one of the two things
# holding auth up (the other is -PrimalToken staying off).
$eng = $eng -replace "`r", ""
[System.IO.File]::WriteAllText((Join-Path $cfgDir 'Engine.ini'), $eng, [System.Text.Encoding]::ASCII)
Write-Host "(config) wrote Engine.ini (LF endings; CR would land inside the token - 401)"

# Dry-run hook: render the configs and stop (used for local tests + Primal Hosted
# config preview/validation). Set PRIMAL_RENDER_ONLY=1 to skip update + launch.
if ($env:PRIMAL_RENDER_ONLY -eq '1') { Write-Host '(render-only) done'; exit 0 }

# ---------------------------------------------------------------------------
# PRIMAL PAK MOD (Evrima = BUILD 39+ pak: pakchunk50-Windows_P.{pak,ucas,utoc}).
#
#   SUPERSEDES the old IsleModRebuild.dll lane. The pak IS the finished Evrima
#   mod (telemetry + command poll + voice positions) and it authenticates via
#   -PrimalToken on the launch line (added below), NOT via isle_mod.ini. Running
#   the DLL alongside the pak would DOUBLE-write telemetry/presence (dup steamId
#   -> data-plane presence collision), so the pak REPLACES the DLL here. Legacy
#   keeps its own wrapper + DLL - that lane is untouched.
#
#   Each boot: fetch the pak manifest
#     { version, build, files:[ {name,url,sha256,size}, ... ] }
#   and if the version changed OR any already-placed pak file's sha no longer
#   matches the manifest, re-download ALL files to a temp stage, sha-verify EACH,
#   and only when EVERY file verifies, move the whole set into
#   TheIsle/Content/Paks. A partial triplet is NEVER placed - a half-updated pak
#   loads and misbehaves, which is worse than not updating. sha is the authority,
#   version is only the fast path (#410: build stamps have lied about the build).
#   Publish new versions with IsleModProject/scripts/publish_pak.ps1. Pak manifest
#   is a SEPARATE R2 key from the DLL's (primal-mod-evrima-pak/ vs primal-mod-evrima/).
# ---------------------------------------------------------------------------
$paksDir    = Join-Path $game 'TheIsle\Content\Paks'
$pakVerFile = Join-Path $tmpl 'primal-pak.version'
$pakUcas    = Join-Path $paksDir 'pakchunk50-Windows_P.ucas'

# ---------------------------------------------------------------------------
# SIGNATURE BYPASS (UniversalSigBypasser) - REQUIRED for the mod pak to mount.
#
# The Isle ships signed paks and refuses to mount an unsigned one, so our
# pakchunk50 would sit on disk and never load. The bypass is an ASI hook, NOT a
# binary patch: dsound.dll (ASI loader proxy) + UniversalSigBypasser.asi go in
# TheIsle\Binaries\Win64 beside the server exe, and hook the signature check at
# runtime. Nothing about the game binary is modified.
#
# ⚠️ THIS MUST RUN AFTER THE STEAMCMD UPDATE AND BEFORE LAUNCH. `app_update ...
# validate` restores/strips files under the install dir every boot, so placing
# these earlier (or once, by hand) does not survive. Re-verified by sha every
# boot for exactly that reason.
#
# Source: github.com/rm-NoobInCoding/UniversalSigBypasser (v1.2), mirrored to our
# R2 with pinned sha256s so a boot never pulls an unreviewed third-party binary.
# ---------------------------------------------------------------------------
$binDirWin  = Join-Path $game 'TheIsle\Binaries\Win64'
$sbVerFile  = Join-Path $tmpl 'primal-sigbypass.version'
if ($env:ENABLE_PRIMAL_MOD -eq '1') {
    $sbManifestUrl = EnvOr $env:PRIMAL_SIGBYPASS_MANIFEST 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-sigbypass/latest.json'
    try {
        $ProgressPreference = 'SilentlyContinue'
        $sm = Invoke-RestMethod -Uri $sbManifestUrl -TimeoutSec 20
        $sbFiles = @($sm.files)
        if (-not $sbFiles -or $sbFiles.Count -lt 1) { throw 'sigbypass manifest carries no files[]' }
        New-Item -ItemType Directory -Force -Path $binDirWin | Out-Null

        # Content is the authority: replace whenever a file is missing or its sha
        # differs (i.e. every time SteamCMD strips or reverts one).
        $sbNeed = @()
        foreach ($fi in $sbFiles) {
            $dst = Join-Path $binDirWin $fi.name
            if (-not (Test-Path $dst)) { $sbNeed += $fi; continue }
            $h = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
            if ($h -ne ("" + $fi.sha256).ToLower()) { $sbNeed += $fi }
        }

        if ($sbNeed.Count) {
            Write-Host "(sigbypass) placing $($sbNeed.Count)/$($sbFiles.Count) file(s) (v$($sm.version)) into TheIsle\Binaries\Win64 ..."
            foreach ($fi in $sbNeed) {
                $dst = Join-Path $binDirWin $fi.name
                $tmpf = "$dst.download"
                Invoke-WebRequest -Uri $fi.url -OutFile $tmpf -UseBasicParsing
                $sha = (Get-FileHash $tmpf -Algorithm SHA256).Hash.ToLower()
                if ($sha -ne ("" + $fi.sha256).ToLower()) {
                    Write-Host "(sigbypass) sha256 MISMATCH on $($fi.name) (got $sha) - discarding"
                    Remove-Item $tmpf -Force -ErrorAction SilentlyContinue
                } else {
                    Move-Item -Force $tmpf $dst
                    Write-Host "(sigbypass) placed $($fi.name) ($($fi.size) bytes)"
                }
            }
            Set-Content -Path $sbVerFile -Value $sm.version -Encoding ascii
        } else {
            Write-Host "(sigbypass) up to date (v$($sm.version), all files sha-verified in place)"
        }
    } catch {
        # Fail-soft: the server still boots. The pak just will not mount.
        Write-Host "(sigbypass) manifest/download failed: $_ - the mod pak will NOT mount this boot"
    }
} else {
    Write-Host "(sigbypass) disabled (ENABLE_PRIMAL_MOD != 1)"
}

if ($env:ENABLE_PRIMAL_MOD -eq '1') {
    $pakManifestUrl = EnvOr $env:PRIMAL_MOD_MANIFEST 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-mod-evrima-pak/latest.json'
    try {
        $ProgressPreference = 'SilentlyContinue'
        $pm = Invoke-RestMethod -Uri $pakManifestUrl -TimeoutSec 20
        $pakFiles = @($pm.files)
        if (-not $pakFiles -or $pakFiles.Count -lt 1) { throw 'manifest carries no files[]' }

        # Content is the authority: re-download when the version changed OR any
        # placed file's sha differs from the manifest (a mislabelled version can
        # not hide a changed pak - #410).
        $haveVer = if (Test-Path $pakVerFile) { (Get-Content $pakVerFile -Raw).Trim() } else { '' }
        $needs = ($pm.version -ne $haveVer)
        if (-not $needs) {
            foreach ($fi in $pakFiles) {
                $dst = Join-Path $paksDir $fi.name
                if (-not (Test-Path $dst)) { $needs = $true; break }
                $h = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
                if ($h -ne ("" + $fi.sha256).ToLower()) { $needs = $true; break }
            }
        }

        if ($needs) {
            Write-Host "(primal-pak) updating '$haveVer' -> '$($pm.version)' ($($pakFiles.Count) files)..."
            New-Item -ItemType Directory -Force -Path $paksDir | Out-Null
            $stage = Join-Path $tmpl 'pak-stage'
            if (Test-Path $stage) { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Force -Path $stage | Out-Null

            $allOk = $true
            foreach ($fi in $pakFiles) {
                $tmp = Join-Path $stage $fi.name
                Invoke-WebRequest -Uri $fi.url -OutFile $tmp -UseBasicParsing
                $sha = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
                if ($sha -ne ("" + $fi.sha256).ToLower()) {
                    Write-Host "(primal-pak) sha256 MISMATCH on $($fi.name) (got $sha) - discarding this update"
                    $allOk = $false; break
                }
            }

            if ($allOk) {
                # Placement only after EVERY file verified. Fixed filenames, so a
                # new build overwrites the old triplet in place - never layers.
                foreach ($fi in $pakFiles) {
                    Move-Item -Force (Join-Path $stage $fi.name) (Join-Path $paksDir $fi.name)
                }
                Set-Content -Path $pakVerFile -Value $pm.version -Encoding ascii
                Write-Host "(primal-pak) pak $($pm.version) ready ($($pm.build)) -> $paksDir"
            } else {
                Write-Host "(primal-pak) update discarded on verify failure - keeping the existing pak (if any)"
            }
            Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
        } else {
            Write-Host "(primal-pak) up to date ($haveVer)"
        }
    } catch {
        # A customer server MUST still start if the manifest is unreachable/bad.
        # Boot continues with whatever pak is already on disk (possibly none).
        Write-Host "(primal-pak) manifest/download failed: $_ - booting with existing pak (if any)"
    }

    if (-not $env:PHSK_KEY) {
        Write-Host "(primal-pak) WARNING: no PHSK_KEY set - the pak will load but cannot authenticate to the data plane"
    }
} else {
    Write-Host "(primal-pak) disabled (ENABLE_PRIMAL_MOD != 1)"
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
# Primal data-plane auth for the pak mod: BUILD 39+ reads its per-server key from
# -PrimalToken on the launch line (the DLL lane used isle_mod.ini; the pak does
# not). Passed only when the mod is enabled, a key is set, AND a pak is actually
# present - a token with no pak is inert, and this keeps the console honest.
# 🔴 -PrimalToken is DISABLED BY DEFAULT (2026-07-29, #411).
#
# Engine.ini and this flag are two independent token sources, and with BOTH set
# the mod booted `tokenlen=54` for a provably clean 53-char key (wrapper debug:
# rawLen=53, strippedBytes=0; Engine.ini on disk: 0 CR, valueLen=53). The
# proven-working reference server sets ONLY Engine.ini and boots `tokenlen=53`.
# Same pak, same key length, different result => the flag is the odd one out, so
# we match the configuration that authenticates and keep exactly one source of
# truth. Set PRIMAL_TOKEN_ARG=1 to put it back (diagnostics / if the mod ever
# stops reading the ini).
$ptArgs = @()
if ($env:PRIMAL_TOKEN_ARG -eq '1' -and $env:ENABLE_PRIMAL_MOD -eq '1' -and $phsk -and (Test-Path $pakUcas)) {
    $ptArgs = @("-PrimalToken=$phsk")
    Write-Host "(start) PrimalToken set (len=$($phsk.Length)) - launch-flag token path ENABLED"
    Dbg ("launch token len={0}" -f $phsk.Length)
} elseif ($env:ENABLE_PRIMAL_MOD -eq '1' -and $phsk) {
    Write-Host "(start) PrimalToken flag omitted - Engine.ini is the single token source (len=$($phsk.Length))"
    Dbg 'launch token: flag omitted, engine.ini only'
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

# NOTE: the old DLL-injection job (LoadLibraryW via CreateRemoteThread) lived here.
# The pak needs no injection - it is a content pak the engine mounts from the Paks
# dir at startup - so that block was removed with the DLL lane. See git history of
# this file (PTEggos) for the injector if a DLL lane is ever revived for Evrima.

Dbg "launching (server will detach; we supervise the real process)"
# Launch form matches Hex's proven dedicated command (map URL carries the port; no
# -QueryPort / -stdout). -MULTIHOME (dash flag) via @mhArgs + EOS_OVERRIDE_HOST_IP (env,
# set above) = the working per-IP combo.
& $exe @mhArgs @fdArgs @ptArgs "/Game/TheIsle/Maps/Game/Gateway/Gateway?Port=$env:SERVER_PORT" -log `
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
