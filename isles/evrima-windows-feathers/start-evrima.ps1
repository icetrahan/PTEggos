# Primal — The Isle: Evrima startup wrapper (feathers / native-Windows node).
#
# Each boot: SteamCMD update -> RENDER Game.ini/Engine.ini from data -> launch.
# Game.ini is a DERIVED artifact, regenerated every boot from the settings below.
# The customer never edits Game.ini directly (The Isle corrupts it) - they edit
# DATA, and we render fresh each boot. Corruption becomes a non-issue.
#
# Settings are layered, later overrides earlier:
#   1. DEFAULTS (below)                      baseline
#   2. EGG VARIABLES ($env:*)                >> THE SOURCE OF TRUTH for every
#      customer setting. The panel renders these, Ptero validates them server-side
#      from the egg `rules`, and provisioning seeds them. Add a variable here when
#      a customer needs a knob - that is the whole config-writer story (#356 T1(a)).
#   3. JSON OVERLAY (_primal/server-config.json)   !! ADMIN ESCAPE HATCH ONLY.
#      STOP: nothing on the platform writes this file. It outranks layer 2, so anything
#      it sets is a field the customer's panel is now LYING about - measured live on
#      93da0534, five fields, 2026-07-29. Use it only for `extra` keys that have no
#      egg variable yet, and prefer promoting the key to a variable instead. Every
#      override it performs is now named loudly on the console (rule 13).
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
    # ---- promoted 2026-07-29 (#356 T1(a)): these three were the last Game.ini keys
    # reachable ONLY through the server-config.json overlay's `extra` map. Defaults
    # below are the values the template used to hardcode, so a server that leaves the
    # new variables alone renders a BYTE-IDENTICAL Game.ini. ----
    MapName               = 'Gateway'
    QueueEnabled          = 'True'
    # Empty = the AISpawnInterval line is OMITTED from Game.ini entirely (the game
    # then uses its own internal default). Same idiom as -PrimalForceDino: we do not
    # know the engine default, so we refuse to guess one and pin it on every server.
    AISpawnInterval       = ''
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
# ---- promoted 2026-07-29 (#356 T1(a)) ----
if ($env:MAP_NAME)          { $cfg.MapName         = $env:MAP_NAME }
if ($env:AI_SPAWN_INTERVAL) { $cfg.AISpawnInterval = $env:AI_SPAWN_INTERVAL }
$cfg.QueueEnabled        = To-Bool $env:QUEUE_ENABLED         $cfg.QueueEnabled

# ---------------------------------------------------------------------------
# cfg key -> the egg variable that feeds it. Used ONLY to make an overlay
# override name the panel field it is contradicting. Keys with no egg variable
# (Extra, AISpawnInterval before it was promoted) are deliberately absent.
# ---------------------------------------------------------------------------
# NOTE: keys are QUOTED deliberately. verify.py enforces rule 10 by rejecting any
# assignment of the RCON-password default to something other than the CHANGEME
# placeholder, and an unquoted key in this table reads to that regex as exactly such
# an assignment. Quoting keeps the secret guard strict instead of loosening it to
# accommodate a lookup table. (Spelling the pattern out here would trip it too.)
$eggVarFor = @{
    'ServerName' = 'SERVER_NAME'; 'MaxPlayers' = 'MAX_PLAYERS'
    'ServerPasswordEnabled' = 'SERVER_PASSWORD_ENABLED'; 'ServerPassword' = 'SERVER_PASSWORD'
    'RconEnabled' = 'RCON_ENABLED'; 'RconPassword' = 'RCON_PASSWORD'
    'Discord' = 'DISCORD_URL'; 'CorpseDecay' = 'CORPSE_DECAY'
    'AdminSteamIds' = 'ADMIN_STEAM_IDS'; 'VipSteamIds' = 'VIP_STEAM_IDS'
    'AllowedClasses' = 'ALLOWED_CLASSES'; 'EnableHumans' = 'ENABLE_HUMANS'
    'DayLength' = 'SERVER_DAY_LENGTH'; 'NightLength' = 'SERVER_NIGHT_LENGTH'
    'GrowthMultiplier' = 'GROWTH_MULTIPLIER'; 'EnableGlobalChat' = 'ENABLE_GLOBAL_CHAT'
    'EnableAI' = 'ENABLE_AI'; 'AIDensity' = 'AI_DENSITY'; 'SpawnFish' = 'SPAWN_FISH'
    'EnableMutations' = 'ENABLE_MUTATIONS'; 'EnableDiets' = 'ENABLE_DIETS'
    'FallDamage' = 'FALL_DAMAGE'; 'AllowReplay' = 'ALLOW_REPLAY'
    'DynamicWeather' = 'DYNAMIC_WEATHER'; 'WhitelistEnabled' = 'WHITELIST_ENABLED'
    'SpawnPlants' = 'SPAWN_PLANTS'; 'PlantMultiplier' = 'PLANT_MULTIPLIER'
    'EnableMigration' = 'ENABLE_MIGRATION'; 'EnableMassMigration' = 'ENABLE_MASS_MIGRATION'
    'EnablePatrolZones' = 'ENABLE_PATROL_ZONES'
    'MapName' = 'MAP_NAME'; 'QueueEnabled' = 'QUEUE_ENABLED'; 'AISpawnInterval' = 'AI_SPAWN_INTERVAL'
}
# Snapshot what the panel's own variables (+ defaults) would render, so the overlay
# pass below can say exactly which fields it is about to contradict. Lists are
# flattened to a comparable string; nothing here is used for rendering.
function Snap($c) {
    $s = @{}
    foreach ($k in $c.Keys) {
        if ($k -eq 'Extra') { continue }
        $v = $c[$k]
        $s[$k] = if ($v -is [Array]) { ($v -join ',') } else { "$v" }
    }
    return $s
}
$preOverlay = Snap $cfg

# ---------------------------------------------------------------------------
# 3) JSON OVERLAY (Primal Hosted). Optional; overrides everything above.
#    Shape: { "ServerName": "...", "MaxPlayers": 200, "AllowedClasses": [...],
#             "AdminSteamIds": [...], "extra": { "ServerDayLengthMinutes": "60", ... } }
# ---------------------------------------------------------------------------
# !! THE OVERLAY IS AN ADMIN ESCAPE HATCH, NOT A CONFIG WRITER (#356 T1(a), 2026-07-29).
#
# Ice's ruling: egg VARIABLES are the single source of truth for customer settings.
# Provisioning and the panel write variables; nothing on the platform writes this file.
# It survives only for keys that have no variable yet (the `extra` map).
#
# WHY THIS BLOCK NOW SHOUTS. This layer silently outranks the panel, and on
# 2026-07-29 that was measured doing real damage on a live customer (93da0534):
# the panel showed MAX_PLAYERS=300 / RCON off / no RCON password, while the rendered
# Game.ini had MaxPlayerCount=250 / bRconEnabled=True / a real password - five fields
# where the customer's own panel was lying to them, and one of them meant a live RCON
# port they could not see or rotate. It also invented BUGS #20's phantom "23 species"
# scare: the auditor read the egg variable, the overlay had pinned 21, and nobody
# compared them.
#
# Rule 13: a path that declines to do its work must say so distinguishably. Discarding
# the panel's value IS declining, so every override is now named on the console with
# both values. DO NOT make this quiet again.
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

    # --- name every field the overlay just took away from the panel ---
    $postOverlay = Snap $cfg
    $overridden  = @()
    foreach ($k in ($preOverlay.Keys | Sort-Object)) {
        if ($postOverlay[$k] -ne $preOverlay[$k]) { $overridden += $k }
    }
    if ($overridden.Count) {
        Write-Host ""
        Write-Host "(config) *** OVERLAY OVERRODE $($overridden.Count) PANEL FIELD(S) - the panel now DISAGREES with this server's Game.ini:"
        foreach ($k in $overridden) {
            $ev   = if ($eggVarFor.ContainsKey($k)) { $eggVarFor[$k] } else { '(no egg variable)' }
            $was  = $preOverlay[$k]; $now = $postOverlay[$k]
            # Never print a secret; length is enough to see that it changed.
            if ($k -match 'Password') { $was = "<len $($was.Length)>"; $now = "<len $($now.Length)>" }
            elseif ($was.Length -gt 90) { $was = $was.Substring(0, 90) + '...' }
            if ($now.Length -gt 90 -and $k -notmatch 'Password') { $now = $now.Substring(0, 90) + '...' }
            Write-Host ("           $k  (panel var $ev)")
            Write-Host ("             panel/default -> '$was'")
            Write-Host ("             overlay WINS  -> '$now'")
        }
        Write-Host "(config)    Fix: move these values into the egg variables and delete them from server-config.json."
        Write-Host ""
        Dbg ("overlay overrode panel fields: " + ($overridden -join ','))
    } else {
        Write-Host "(config) overlay changed no panel-visible field (extra-only or redundant) - panel and Game.ini agree"
    }
    if ($cfg.Extra.Keys.Count) {
        Write-Host ("(config) overlay 'extra' sets {0} key(s) with no panel surface at all: {1}" -f `
                    $cfg.Extra.Keys.Count, (($cfg.Extra.Keys | Sort-Object) -join ', '))
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

# --- overlay "extra": generic [tigamesession] key setter (override anything) ---
foreach ($k in $cfg.Extra.Keys) {
    $line = "$k=$($cfg.Extra[$k])"
    if ($gi -match "(?m)^\s*$([regex]::Escape($k))\s*=") { $gi = $gi -replace "(?m)^\s*$([regex]::Escape($k))\s*=.*$", $line }
    else { $gi = $gi -replace "(?m)^(\[/script/theisle\.tigamesession\]\r?\n)", "`$1$line`r`n" }
}
Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
Write-Host "(config) rendered Game.ini (players=$($cfg.MaxPlayers), classes=$($classes.Count), admins=$($cfg.AdminSteamIds.Count), vips=$($cfg.VipSteamIds.Count))"

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
$pakForceDino = ('' + $env:PRIMAL_FORCE_DINO).Trim()
# 2026-08-03: fallback REMOVED (Isle update 24542870). Ice reported Baryonyx and
# Oviraptor. This hardcoded default silently force-RE-ADDED them at boot even
# after they were stripped from ALLOWED_CLASSES, because Config_Scan hits on
# AllowedClasses OR ForceAllowSet. Empty now means force nothing.
$pakExtra = [ordered]@{
    # Trike corpse cleanup - ON by Ice's call 2026-08-01. Lane B advised holding
    # it OFF on customers until #573; Ice overrode that deliberately.
    # Key names + value forms are the PAK'S: True/False (not 1/0), csv (not array).
    'BodySweepOn'   = 'True'
    'BodySweepList' = 'Triceratops'
    'BodyHoldSec'   = '10.0'
}
# PRIMAL_MOD_INI="Key=Value;Other=1" overrides/extends the above with no script edit.
if ($env:PRIMAL_MOD_INI) {
    foreach ($pair in ($env:PRIMAL_MOD_INI -split ';')) {
        $kv = $pair.Trim(); if (-not $kv) { continue }
        $eq = $kv.IndexOf('='); if ($eq -lt 1) { Write-Host "(config) WARNING ignoring malformed PRIMAL_MOD_INI entry '$kv'"; continue }
        $pakExtra[$kv.Substring(0, $eq).Trim()] = $kv.Substring($eq + 1).Trim()
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
