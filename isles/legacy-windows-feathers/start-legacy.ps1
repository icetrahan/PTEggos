# Primal - The Isle: LEGACY startup wrapper (feathers / native-Windows node).
#
# Legacy = SteamCMD app 412680, branch `public` (UE 4.25.4). INSTALL ONCE, NEVER
# UPDATE - the build is frozen, so there is NO SteamCMD update on boot (an update
# would only risk breaking a working install). Downside: a crash can wipe files,
# so we RE-RENDER Game.ini + RE-SYNC mods every boot to self-heal.
#
# Each boot: fetch this server's canonical config from the data plane
# (GET /v1/boot-config, this server's own phsk key) -> render Game.ini (Legacy
# schema) + MOTD -> sync server mods -> launch.
#
# *** WHERE SETTINGS COME FROM (2026-09-13, BACKLOG C1/I1, BUGS #1799):
#   1. THE DATA PLANE  >> the source of truth. The customer's Primal Hosted panel
#      writes `server_settings`; this script fetches and renders. Last-known-good
#      is cached to _primal/boot-config.cache.json so a plane outage cannot stop
#      a boot (rung 2). Same ladder as start-evrima.ps1.
#   2. EGG VARIABLES   >> the FALLBACK rung only: rendered when the plane is
#      unreachable AND there is no cache (first boot / broken key), and for any
#      key the served block does not carry. Every rung prints its own sentence.
#      Before 2026-09-13 this wrapper read exactly ONE plane key (adminSteamIds)
#      and took everything else from egg vars, which is why the panel's Legacy
#      page honestly showed 3 fields (#1799). Now it reads the whole set below.
#
# *** PLANE_KEYS - THE ONE LIST. The panel's Legacy canon (primal_billing
#     lib/canonical-config.ts, `canonFieldsFor("legacy")`) and the plane's
#     server_settings contract test are asserted EQUAL to this line, so the three
#     cannot drift apart silently. Edit the list here, then the code below, then
#     the panel + plane in the same change. Keep it on ONE line; tests parse it.
# PLANE_KEYS: serverName,maxPlayers,serverPasswordEnabled,serverPassword,adminSteamIds,enableGlobalChat,fallDamage,allowReplay,enableAi,legacyGameMode,legacyMap,legacyMotd,legacyDisabledDinos,legacyAllowChat,legacyNameTags,legacyGrowth,legacyTurnInPlace,legacyNesting,legacyScent,legacyAiMax,legacyAiRate,legacyAiPlayerSpawns,legacyDayLength,legacyDynamicTime,legacyStartingTime,legacyDeadBodyTime,legacyRespawnTime,legacyLogoutTime,legacyFootprintLifetime,legacyGroupingMod,legacyEnabledMods,legacyBattleye,legacyExperimental,legacyTag,legacyDiscord
#   - the 9 unprefixed keys are SHARED with the Evrima canon (same Game.ini
#     meaning, same default); the 26 `legacy*` keys are Legacy-only and their
#     plane defaults are byte-equal to the egg defaults below, so a server nobody
#     has edited renders an IDENTICAL Game.ini from either rung.
#   - legacyBattleye / legacyExperimental / legacyTag / legacyDiscord (2026-09-17, BUGS #2470,
#     Ice: "if they have stuff set lets use it if not leave it") are TRI-STATE STRINGS:
#     '' = the line is NOT rendered (the game's own default, exactly what every server
#     rendered before this key existed); anything else renders `bServerBattleye=`,
#     `bServerExperimental=`, `ServerTag=`, `ServerDiscord=` into igamesession.
#   - adminSteamIds is served as the plane's union (hand + Discord-role + allow)
#     minus deny; the allow/deny lists are inputs to it, never keys of their own.
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
# '' | 'true' | 'false' - a Game.ini line that is only rendered when someone SET it (#2470).
function Tri-Bool($v) {
    $t = ('' + $v).Trim().ToLower()
    if ($t -in @('1','true','yes','on'))  { return 'true' }
    if ($t -in @('0','false','no','off')) { return 'false' }
    return ''
}
# ServerDiscord is the INVITE CODE only; a pasted discord.gg URL is trimmed to its code.
function Discord-Code([string]$v) {
    $t = ('' + $v).Trim()
    $t = $t -replace '^(https?://)?(www\.)?(discord\.gg|discord\.com/invite)/', ''
    return $t.Trim('/')
}

# ── 1) DEFAULTS <- egg vars (the FALLBACK rung; the plane overrides per key) ──
# Booleans are kept as the Game.ini literals 'true'/'false'; numbers as strings
# (rendered verbatim, so 1.5 stays 1.5). Lists are string arrays.
$cfg = [ordered]@{
    ServerName        = EnvOr $env:SERVER_NAME 'Primal Hosted - Legacy'
    MaxPlayers        = EnvOr $env:MAX_PLAYERS '100'
    ServerPassword    = EnvOr $env:SERVER_PASSWORD ''
    GameMode          = EnvOr $env:GAME_MODE 'Survival'                 # Survival | Sandbox
    Map               = EnvOr $env:MAP 'Isle_V3'                        # short key or /Game/ path
    Motd              = EnvOr $env:MOTD ''
    DisabledDinos     = @(Split-Csv $env:DISABLED_DINOS)
    AdminSteamIds     = @(Split-Csv $env:ADMIN_STEAM_IDS)
    AllowChat         = To-Bool $env:ALLOW_CHAT 'true'
    GlobalChat        = To-Bool $env:GLOBAL_CHAT 'true'
    NameTags          = To-Bool $env:NAME_TAGS 'true'
    Growth            = To-Bool $env:GROWTH 'true'
    FallDamage        = To-Bool $env:FALL_DAMAGE 'true'
    TurnInPlace       = To-Bool $env:TURN_IN_PLACE 'true'
    AllowReplay       = To-Bool $env:ALLOW_REPLAY 'true'
    DeadBodyTime      = EnvOr $env:DEAD_BODY_TIME '200'
    RespawnTime       = EnvOr $env:RESPAWN_TIME '30'
    LogoutTime        = EnvOr $env:LOGOUT_TIME '60'
    FootprintLifetime = EnvOr $env:FOOTPRINT_LIFETIME '60'
    Nesting           = To-Bool $env:NESTING 'true'
    Scent             = To-Bool $env:SCENT 'false'
    EnableAI          = To-Bool $env:ENABLE_AI 'true'
    AIMax             = EnvOr $env:AI_MAX '100'
    AIRate            = EnvOr $env:AI_RATE '1.5'
    AIPlayerSpawns    = To-Bool $env:AI_PLAYER_SPAWNS 'true'
    StartingTime      = EnvOr $env:STARTING_TIME '341'
    DynamicTime       = To-Bool $env:DYNAMIC_TIME '0'
    DayLength         = EnvOr $env:DAY_LENGTH '30'
    GroupingMod       = (EnvOr $env:GROUPING_MOD 'none').ToLower()      # none | universal | diet | herbie
    EnabledMods       = @(Split-Csv $env:ENABLED_MODS)
    # Tri-state ('' = omit the line). Egg vars BATTLEYE / EXPERIMENTAL accept 1/0/true/false.
    Battleye          = Tri-Bool $env:BATTLEYE
    Experimental      = Tri-Bool $env:EXPERIMENTAL
    ServerTag         = (EnvOr $env:SERVER_TAG '').Trim()
    ServerDiscord     = Discord-Code (EnvOr $env:SERVER_DISCORD '')
}
$gamePort  = EnvOr $env:SERVER_PORT '7777'
$queryPort = EnvOr $env:SERVER_PORT_1 ([string]([int]$gamePort + 1))

# ── 2) THE DATA PLANE: fetch -> cache -> (egg vars) ──────────────────────────
# *** THE FAIL-SAFE LADDER, AND ALL THREE RUNGS MUST STAY DISTINGUISHABLE (rule 13).
#   FETCHED  -> render it, and cache it as last-known-good
#   CACHE    -> plane unreachable; render the cache and SAY how old it is
#   EGGVARS  -> no plane, no cache; render the egg vars and SHOUT
$primalDir = Join-Path $root '_primal'
New-Item -ItemType Directory -Force -Path $primalDir | Out-Null
$bootCache = Join-Path $primalDir 'boot-config.cache.json'
$cfgSource = 'eggvars'
$canon     = $null
$phsk      = ('' + $env:PHSK_KEY).Trim()
$dataBase  = (EnvOr $env:PRIMAL_DATA_BASE 'https://data.primalhosted.com').TrimEnd('/')
if ($env:PRIMAL_BOOT_CONFIG_FILE) {
    # TEST HATCH (render-only acceptance): read a served boot-config JSON from a
    # file instead of the network. Not an egg variable, so Wings never sets it;
    # if you see this line on a live box, someone set it by hand.
    Write-Host "(config) *** TEST HATCH: boot-config read from file $($env:PRIMAL_BOOT_CONFIG_FILE) - NOT from the plane ***"
    $canon = Get-Content $env:PRIMAL_BOOT_CONFIG_FILE -Raw | ConvertFrom-Json
    $cfgSource = 'file'
} elseif ($phsk) {
    try {
        $ProgressPreference = 'SilentlyContinue'
        $canon = Invoke-RestMethod -Uri "$dataBase/v1/boot-config" -Headers @{ Authorization = "Bearer $phsk" } -TimeoutSec 20
        $cfgSource = 'fetched'
        # Cache only a FETCH - a degraded boot must never overwrite last-known-good.
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
                Write-Host "(config)     ANY PANEL CHANGE SINCE THEN IS NOT APPLIED ON THIS BOOT."
                Write-Host ""
            } catch {
                Write-Host "(config) *** CACHE PRESENT BUT UNREADABLE ($($_.Exception.Message)) - falling through to egg vars ***"
                $canon = $null
            }
        } else {
            Write-Host ""
            Write-Host "(config) *** DATA PLANE UNREACHABLE AND NO CACHE - RENDERING EGG VARIABLES ***"
            Write-Host "(config)     reason: $why"
            Write-Host "(config)     Expected only on a server's FIRST boot. Otherwise the plane or PHSK_KEY is wrong."
            Write-Host "(config)     Anything saved in the panel is NOT applied on this boot."
            Write-Host ""
        }
    }
} else {
    Write-Host "(config) no PHSK_KEY - rendering EGG VARIABLES only (the panel cannot reach this server)"
}

# ── 3) APPLY the served block onto $cfg, key by key ──────────────────────────
# Every field applies ONLY when the block carries it, so a plane that drops a
# key (or predates one) leaves the egg var standing for that key alone.
function Has($o, [string]$n) { return ($null -ne $o) -and ($null -ne $o.PSObject.Properties[$n]) }
function PsBool($v) { if ($v) { return 'true' } else { return 'false' } }
$ss = $null
if ($canon -and $canon.config) { $ss = $canon.config.server_settings }
$overrode = New-Object System.Collections.Generic.List[string]   # "KEY egg=… plane=…" where the plane changed a value
function Take([string]$field, [string]$key, $value) {
    $old = $cfg[$field]
    $oldS = if ($old -is [array]) { ($old -join ',') } else { [string]$old }
    $newS = if ($value -is [array]) { ($value -join ',') } else { [string]$value }
    $cfg[$field] = $value
    if ($oldS -ne $newS -and $key -ne 'serverPassword' -and $key -ne 'adminSteamIds') { $script:overrode.Add("$key egg=[$oldS] plane=[$newS]") }
}
if ($ss) {
    # shared keys (Evrima canon names)
    if (Has $ss 'serverName') {
        if (('' + $ss.serverName).Trim()) { Take 'ServerName' 'serverName' ([string]$ss.serverName) }
        else { Write-Host "(config) serverName served EMPTY - keeping the egg var '$($cfg.ServerName)' (a blank name is never rendered)" }
    }
    if (Has $ss 'maxPlayers') {
        if ([int]$ss.maxPlayers -ge 1) { Take 'MaxPlayers' 'maxPlayers' ([string][int]$ss.maxPlayers) }
        else { Write-Host "(config) maxPlayers served as $($ss.maxPlayers) - keeping the egg var $($cfg.MaxPlayers)" }
    }
    if (Has $ss 'serverPassword') {
        $pwOn = if (Has $ss 'serverPasswordEnabled') { [bool]$ss.serverPasswordEnabled } else { $true }
        $pw = if ($pwOn) { [string]$ss.serverPassword } else { '' }
        if ($pw -ne $cfg.ServerPassword) { $script:overrode.Add("serverPassword egg=[len $($cfg.ServerPassword.Length)] plane=[len $($pw.Length), enabled=$pwOn]") }
        $cfg.ServerPassword = $pw
    }
    if (Has $ss 'enableGlobalChat') { Take 'GlobalChat'  'enableGlobalChat' (PsBool $ss.enableGlobalChat) }
    if (Has $ss 'fallDamage')       { Take 'FallDamage'  'fallDamage'       (PsBool $ss.fallDamage) }
    if (Has $ss 'allowReplay')      { Take 'AllowReplay' 'allowReplay'      (PsBool $ss.allowReplay) }
    if (Has $ss 'enableAi')         { Take 'EnableAI'    'enableAi'         (PsBool $ss.enableAi) }
    # Legacy-only keys
    if (Has $ss 'legacyGameMode') {
        $gm = [string]$ss.legacyGameMode
        if ($gm -match '^(Survival|Sandbox)$') { Take 'GameMode' 'legacyGameMode' $gm }
        else { Write-Host "(config) legacyGameMode '$gm' is not Survival|Sandbox - keeping '$($cfg.GameMode)'" }
    }
    if (Has $ss 'legacyMap')               { Take 'Map'               'legacyMap'               ([string]$ss.legacyMap) }
    if (Has $ss 'legacyMotd')              { Take 'Motd'              'legacyMotd'              ([string]$ss.legacyMotd) }
    # Lists: an EMPTY array is a legitimate value ("no disabled dinos", "no addons") - @(), never a skip.
    if (Has $ss 'legacyDisabledDinos')     { Take 'DisabledDinos'     'legacyDisabledDinos'     @(@($ss.legacyDisabledDinos) | ForEach-Object { ('' + $_).Trim() } | Where-Object { $_ }) }
    if (Has $ss 'legacyAllowChat')         { Take 'AllowChat'         'legacyAllowChat'         (PsBool $ss.legacyAllowChat) }
    if (Has $ss 'legacyNameTags')          { Take 'NameTags'          'legacyNameTags'          (PsBool $ss.legacyNameTags) }
    if (Has $ss 'legacyGrowth')            { Take 'Growth'            'legacyGrowth'            (PsBool $ss.legacyGrowth) }
    if (Has $ss 'legacyTurnInPlace')       { Take 'TurnInPlace'       'legacyTurnInPlace'       (PsBool $ss.legacyTurnInPlace) }
    if (Has $ss 'legacyNesting')           { Take 'Nesting'           'legacyNesting'           (PsBool $ss.legacyNesting) }
    if (Has $ss 'legacyScent')             { Take 'Scent'             'legacyScent'             (PsBool $ss.legacyScent) }
    if (Has $ss 'legacyAiMax')             { Take 'AIMax'             'legacyAiMax'             ([string]$ss.legacyAiMax) }
    if (Has $ss 'legacyAiRate')            { Take 'AIRate'            'legacyAiRate'            ([string]$ss.legacyAiRate) }
    if (Has $ss 'legacyAiPlayerSpawns')    { Take 'AIPlayerSpawns'    'legacyAiPlayerSpawns'    (PsBool $ss.legacyAiPlayerSpawns) }
    if (Has $ss 'legacyDayLength')         { Take 'DayLength'         'legacyDayLength'         ([string]$ss.legacyDayLength) }
    if (Has $ss 'legacyDynamicTime')       { Take 'DynamicTime'       'legacyDynamicTime'       (PsBool $ss.legacyDynamicTime) }
    if (Has $ss 'legacyStartingTime')      { Take 'StartingTime'      'legacyStartingTime'      ([string]$ss.legacyStartingTime) }
    if (Has $ss 'legacyDeadBodyTime')      { Take 'DeadBodyTime'      'legacyDeadBodyTime'      ([string]$ss.legacyDeadBodyTime) }
    if (Has $ss 'legacyRespawnTime')       { Take 'RespawnTime'       'legacyRespawnTime'       ([string]$ss.legacyRespawnTime) }
    if (Has $ss 'legacyLogoutTime')        { Take 'LogoutTime'        'legacyLogoutTime'        ([string]$ss.legacyLogoutTime) }
    if (Has $ss 'legacyFootprintLifetime') { Take 'FootprintLifetime' 'legacyFootprintLifetime' ([string]$ss.legacyFootprintLifetime) }
    if (Has $ss 'legacyGroupingMod')       { Take 'GroupingMod'       'legacyGroupingMod'       (('' + $ss.legacyGroupingMod).ToLower()) }
    if (Has $ss 'legacyEnabledMods')       { Take 'EnabledMods'       'legacyEnabledMods'       @(@($ss.legacyEnabledMods) | ForEach-Object { ('' + $_).Trim() } | Where-Object { $_ }) }
    # #2470 - tri-state: the plane's '' means "do not render the line" (Tri-Bool/Discord-Code normalise the rest)
    if (Has $ss 'legacyBattleye')          { Take 'Battleye'          'legacyBattleye'          (Tri-Bool $ss.legacyBattleye) }
    if (Has $ss 'legacyExperimental')      { Take 'Experimental'      'legacyExperimental'      (Tri-Bool $ss.legacyExperimental) }
    if (Has $ss 'legacyTag')               { Take 'ServerTag'         'legacyTag'               (('' + $ss.legacyTag).Trim()) }
    if (Has $ss 'legacyDiscord')           { Take 'ServerDiscord'     'legacyDiscord'           (Discord-Code ('' + $ss.legacyDiscord)) }

    Write-Host ("(config) canonical config {0} (players={1} mode={2} map={3} scope={4} updatedAt={5})" -f `
        $cfgSource.ToUpper(), $cfg.MaxPlayers, $cfg.GameMode, $cfg.Map, $canon.scope.server_settings, $canon.updatedAt)
    if ($overrode.Count) {
        # The migration's own evidence line: every key where the panel's value
        # differs from the egg var still set on this server. Expected while the
        # egg vars are stale; if a value here surprises you, the PLANE row is
        # what the server will obey.
        Write-Host "(config) NOTE $($overrode.Count) egg variable(s) are superseded by the panel on this boot:"
        foreach ($o in $overrode) { Write-Host "(config)      $o" }
    }
}
# *** #1097 - the seat cap. The plane REFUSES an over-cap write but can only CLAMP
# on read (a server must boot), so it reports what it clamped. Never let that
# pass silently.
if ($canon -and $canon.clamped) {
    foreach ($cl in @($canon.clamped)) {
        Write-Host "(config) *** CLAMPED BY ENTITLEMENT: $($cl.key).$($cl.field) stored=$($cl.stored) -> applied=$($cl.applied) (your plan's limit)"
    }
}

# map: accept a short key or a full path (default Isle_V3)
$MAPS = @{
    'Isle_V3'   = '/Game/TheIsle/Maps/Landscape3/Isle_V3'
    'V3'        = '/Game/TheIsle/Maps/Landscape3/Isle_V3'
    'Thenyaw'   = '/Game/TheIsle/Maps/Thenyaw_Island/Thenyaw_Island'
    'TestLevel' = '/Game/TheIsle/Maps/Developer/DV_TestLevel'
}
$mapIn = [string]$cfg.Map
$map   = if ($MAPS.ContainsKey($mapIn)) { $MAPS[$mapIn] } elseif ($mapIn -like '/Game/*') { $mapIn } else { Write-Host "(config) map '$mapIn' unknown - using Isle_V3"; $MAPS['Isle_V3'] }

# ── ADMINS: the plane's union, egg var as fail-safe (#1453) ──────────────────
# The plane serves adminSteamIds as the UNION of the owner's hand list and the
# Discord-staff-role resolution (recomputed at serve time, allow/deny applied).
# Rendering from it makes grants AND revocations reach Game.ini at the next
# boot; the ADMIN_STEAM_IDS egg var stays as the fallback so a plane outage can
# never render a server with no admins (frozen beats empty).
#
# FAIL-SAFE POLARITY - each outcome prints its own sentence (hard rule 13):
#   SERVED    fetch ok, non-empty  -> render the union
#   FALLBACK  fetch ok, ZERO admins while the egg var has ids -> render the egg
#             var and SHOUT. A mis-keyed server fetches someone else's empty
#             config "successfully"; zero served admins is treated as suspect,
#             not obeyed, until the egg var itself is emptied on purpose.
#   FALLBACK  no served block (plane down, no cache / no key) -> egg var, said above
$adminsFallback = @($cfg.AdminSteamIds)
$admins      = $adminsFallback
$adminSource = 'eggvar'
if ($ss) {
    $servedRaw = @()
    if (Has $ss 'adminSteamIds') { $servedRaw = @($ss.adminSteamIds) }
    # Steam64s only - junk must not reach Game.ini.
    $served = @($servedRaw | ForEach-Object { ('' + $_).Trim() } | Where-Object { $_ -match '^\d{17}$' })
    $src = if ($canon.adminSources) { "hand=$($canon.adminSources.hand) resolved=$($canon.adminSources.resolved) applied=$($canon.adminSources.applied)" } else { 'adminSources absent' }
    if ($served.Count -gt 0) {
        $admins      = $served
        $adminSource = 'served'
        Write-Host "(admins) SERVED ($cfgSource) from $dataBase/v1/boot-config: $($served.Count) admins ($src, updatedAt=$($canon.updatedAt))"
    } elseif ($adminsFallback.Count -gt 0) {
        Write-Host ""
        Write-Host "(admins) *** PLANE SERVED ZERO ADMINS ($src) - RENDERING EGG-VAR FALLBACK ($($adminsFallback.Count) ids) ***"
        Write-Host "(admins)     Either every admin was really revoked, or this server's PHSK_KEY maps to the wrong plane row."
        Write-Host "(admins)     If zero is intended, empty the ADMIN_STEAM_IDS egg var too and this rung goes away."
        Write-Host ""
    } else {
        $adminSource = 'served'
        Write-Host "(admins) plane served zero admins and the egg var is empty - rendering NO ServerAdmins"
    }
} else {
    Write-Host "(admins) no served config - egg-var admin list only ($($adminsFallback.Count) ids)"
}

# ── RENDER Game.ini (Legacy schema: igamesession + Engine.GameSession + igamemode) ──
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$adminLines = if ($admins.Count) { ($admins | ForEach-Object { "ServerAdmins=$_" }) -join "`r`n" } else { 'ServerAdmins=' }
$dinoLines  = if ($cfg.DisabledDinos.Count) { ($cfg.DisabledDinos | ForEach-Object { "DisabledDinosaurs=$_" }) -join "`r`n" } else { 'DisabledDinosaurs=' }
# #2470 - four igamesession keys rendered ONLY when set ('' = leave the game's default, and the
# file stays byte-identical to what it rendered before these keys existed). Each starts with
# its own CRLF so an unset key adds nothing, not even a blank line.
$sessionExtra = ''
if ($cfg.Battleye -ne '')      { $sessionExtra += "`r`nbServerBattleye=$($cfg.Battleye)" }
if ($cfg.Experimental -ne '')  { $sessionExtra += "`r`nbServerExperimental=$($cfg.Experimental)" }
if ($cfg.ServerTag -ne '')     { $sessionExtra += "`r`nServerTag=$($cfg.ServerTag)" }
if ($cfg.ServerDiscord -ne '') { $sessionExtra += "`r`nServerDiscord=$($cfg.ServerDiscord)" }

$gi = @"
[/script/theisle.igamesession]
ServerName=$($cfg.ServerName)
ServerPassword=$($cfg.ServerPassword)
bServerDatabase=true
bServerAllowChat=$($cfg.AllowChat)
bServerGlobalChat=$($cfg.GlobalChat)
bServerNameTags=$($cfg.NameTags)
bServerGrowth=$($cfg.Growth)
bServerFallDamage=$($cfg.FallDamage)
bServerAllowTurnInPlace=$($cfg.TurnInPlace)
bServerAllowReplayRecording=$($cfg.AllowReplay)
ServerDeadBodyTime=$($cfg.DeadBodyTime)
ServerRespawnTime=$($cfg.RespawnTime)
ServerLogoutTime=$($cfg.LogoutTime)
ServerFootprintLifetime=$($cfg.FootprintLifetime)
bServerNesting=$($cfg.Nesting)
bServerScent=$($cfg.Scent)
bServerAI=$($cfg.EnableAI)
ServerAIMax=$($cfg.AIMax)
ServerAIRate=$($cfg.AIRate)
bServerAIPlayerSpawns=$($cfg.AIPlayerSpawns)$sessionExtra
$adminLines

[/Script/Engine.GameSession]
MaxPlayers=$($cfg.MaxPlayers)

[/script/theisle.igamemode]
ServerStartingTime=$($cfg.StartingTime)
bServerDynamicTimeOfDay=$($cfg.DynamicTime)
ServerDayLength=$($cfg.DayLength)
$dinoLines
"@
Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
$extraNames = @(); if ($cfg.Battleye -ne '') { $extraNames += 'battleye' }; if ($cfg.Experimental -ne '') { $extraNames += 'experimental' }; if ($cfg.ServerTag -ne '') { $extraNames += 'tag' }; if ($cfg.ServerDiscord -ne '') { $extraNames += 'discord' }
$extraSay = if ($extraNames.Count) { ($extraNames -join '+') } else { 'none' }
Write-Host "(config) rendered Legacy Game.ini from $cfgSource (players=$($cfg.MaxPlayers), mode=$($cfg.GameMode), admins=$($admins.Count) [$adminSource], disabled=$($cfg.DisabledDinos.Count), session-extras=$extraSay)"

# ── MOTD (empty file = no MOTD popup; text = shown to players on join) ────────
New-Item -ItemType Directory -Force -Path $savedDir | Out-Null
Set-Content -Path (Join-Path $savedDir 'MOTD.txt') -Value $cfg.Motd -Encoding utf8 -NoNewline
Write-Host "(config) wrote MOTD ($($cfg.Motd.Length) chars)"

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
$grouping = [string]$cfg.GroupingMod
if ($grouping -notmatch '^(none|universal|diet|herbie)$') { Write-Host "(mods) grouping '$grouping' unknown - using none"; $grouping = 'none' }
$groupModName = @{ 'universal'='UniversalGrouping'; 'diet'='DietGrouping'; 'herbie'='HerbieGrouping' }[$grouping]
$wantMods = New-Object System.Collections.Generic.List[string]
if ($groupModName) { $wantMods.Add($groupModName) }
foreach ($mod in @($cfg.EnabledMods)) { if ($MOD_CATALOG.ContainsKey($mod)) { $wantMods.Add($mod) } else { Write-Host "(mods) '$mod' is not in the catalog - ignored" } }
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
if ($env:PRIMAL_RENDER_ONLY -eq '1') { Write-Host "(render-only) done source=$cfgSource map=$map mode=$($cfg.GameMode) players=$($cfg.MaxPlayers) admins=$($admins.Count)[$adminSource] mods=[$($installed -join ', ')]"; exit 0 }

if (-not (Test-Path $exe)) { throw "server binary missing: $exe (install did not finish)" }

# ── Primal DLL mod: download-by-version (deployment pipeline). Manifest carries
#    {version, dll_url, sha256}; only re-downloads when the version changes. The
#    injection itself is armed just before launch (below). Publish new versions
#    with isle_mod_legacy/publish_dll.py — see PRIMAL_MOD_PIPELINE.md.
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
            'command_poll_interval_ms=2000',
            "telemetry_push_url=$dataBase/v1/telemetry",
            "chat_capture_url=$dataBase/v1/chat",
            "chat_msg_offset=16",
            "chat_capture_src=serversay",
            "chat_capture_debug=0"
        ) -join "`n"
        Set-Content -Path (Join-Path $primalDir 'legacy_anticheat.cfg') -Value $cfg -Encoding ascii
        Write-Host "(primal-mod) wrote legacy_anticheat.cfg (per-server key, poll=$dataBase/v1/commands)"
    } else {
        Write-Host "(primal-mod) no PHSK_KEY set - mod will run without a data-plane key"
    }
} else {
    Write-Host "(primal-mod) disabled (ENABLE_PRIMAL_MOD != 1)"
}

# ── primal-loader: THE GAME LOADS ITS OWN MOD (A230, 2026-09-25) ─────────────
# The injector below had to find the game's process from OUTSIDE and reach into it. That
# outside step failed two different ways in two days - 09-24 it picked ANOTHER server's pid
# (#2700), 09-25 it refused the RIGHT pid (#2724: feathers runs the game as pt_<volume>) - and
# both times the server ran for hours without the mod. Ice 09-25: "the servers REQUIRE that dll
# injection" / "our solution needs to solve the issue at the root".
# ROOT FIX: the game exe statically imports DSOUND.dll, so Ultimate ASI Loader (dsound.dll, the
# same sha-pinned binary the Evrima sigbypass lane has run on every Windows Evrima server since
# 2026-08) placed beside it loads every *.asi at process start. primal-loader.asi (PTEggos
# loader/primal-loader) runs INSIDE this server's own process - it cannot be in the wrong one,
# needs no rights over anyone, and runs again on every start (crash-restarts included). It waits
# for THIS boot's world line in TheIsle.log, +10 s, then LoadLibraryW's _primal\LegacyMod.dll -
# the same moment the old injector was proven at - and logs every decision to
# _primal/primal-loader.log. The injector job below is now the VERIFIER + fallback: it confirms
# the module is in the process, heals it if not, and never stops trying while the server lives.
# ⚠️ Mod OFF (ENABLE_PRIMAL_MOD != 1 or PRIMAL_LOADER=0) REMOVES primal-loader.asi + .ini, so a
# disabled mod cannot be loaded by a leftover file. dsound.dll alone loads nothing.
$binDirWin = Split-Path $exe -Parent
$ldrAsi    = Join-Path $binDirWin 'primal-loader.asi'
$ldrIni    = Join-Path $binDirWin 'primal-loader.ini'
$ldrLog    = Join-Path $primalDir 'primal-loader.log'
$ldrWant   = ($env:ENABLE_PRIMAL_MOD -eq '1') -and ((EnvOr $env:PRIMAL_LOADER '1').Trim() -ne '0')
if ($ldrWant -and (Test-Path $primalDll)) {
    $ldrManifestUrl = EnvOr $env:PRIMAL_LOADER_MANIFEST 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-loader/latest.json'
    try {
        $ProgressPreference = 'SilentlyContinue'
        $lm = Invoke-RestMethod -Uri $ldrManifestUrl -TimeoutSec 20
        $lFiles = @($lm.files)
        if (-not $lFiles -or $lFiles.Count -lt 1) { throw 'loader manifest carries no files[]' }
        $lBad = 0
        foreach ($fi in $lFiles) {
            $dst = Join-Path $binDirWin $fi.name
            $h = if (Test-Path $dst) { (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower() } else { '' }
            if ($h -eq ("" + $fi.sha256).ToLower()) { continue }
            $tmpf = "$dst.download"
            Invoke-WebRequest -Uri $fi.url -OutFile $tmpf -UseBasicParsing
            $sha = (Get-FileHash $tmpf -Algorithm SHA256).Hash.ToLower()
            if ($sha -ne ("" + $fi.sha256).ToLower()) {
                Write-Host "(primal-loader) sha256 MISMATCH on $($fi.name) (got $sha) - discarding"
                Remove-Item $tmpf -Force -ErrorAction SilentlyContinue; $lBad++
            } else { Move-Item -Force $tmpf $dst; Write-Host "(primal-loader) placed $($fi.name) ($($fi.size) bytes, v$($lm.version))" }
        }
        $ini = @(
            '; Primal Hosted - written by start-legacy.ps1 every boot. Do not edit.',
            "log=$ldrLog",
            "world_log=$isleLog",
            'world_match=LogWorld: Bringing World',
            'world_match=to LoadMap(',
            'world_timeout_s=600',
            'settle_s=10',
            'retry_s=30',
            'retries=20',
            "load=$primalDll"
        ) -join "`r`n"
        Set-Content -Path $ldrIni -Value $ini -Encoding ascii
        "===== boot $(Get-Date -Format o) (wrapper) - loader v$($lm.version), files sha-verified=$($lBad -eq 0) =====" | Out-File -FilePath $ldrLog -Encoding ascii
        if ($lBad -eq 0) { Write-Host "(primal-loader) v$($lm.version) in place (sha-verified): the game loads LegacyMod.dll ITSELF at world-up; log -> _primal/primal-loader.log" }
        else { Write-Host "(primal-loader) $lBad file(s) failed sha - the injector watchdog carries this boot" }
    } catch {
        Write-Host "(primal-loader) manifest/download failed: $_ - the injector watchdog carries this boot"
    }
} else {
    foreach ($f in @($ldrAsi, $ldrIni)) { if (Test-Path $f) { Remove-Item -Force $f -ErrorAction SilentlyContinue } }
    Write-Host "(primal-loader) off (ENABLE_PRIMAL_MOD=$($env:ENABLE_PRIMAL_MOD) PRIMAL_LOADER=$($env:PRIMAL_LOADER) dll=$(Test-Path $primalDll)) - primal-loader.asi/.ini removed, the game loads nothing by itself"
}

# ── LAUNCH + supervise ───────────────────────────────────────────────────────
# UE writes to stderr in normal operation; 'Stop' would turn that into a
# NativeCommandError that kills the wrapper. 'Continue' lets it flow to feathers.
$ErrorActionPreference = 'Continue'
$url = "$map`?Port=$gamePort`?QueryPort=$queryPort`?MaxPlayers=$($cfg.MaxPlayers)`?game=$($cfg.GameMode)`?listen"
Write-Host "(start) $(Get-Date -Format HH:mm:ss) launching: $url"
$before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$launchedAt = Get-Date

# *** #2700 (2026-09-24) - WHICH PROCESS IS OURS. A Windows node runs MANY Isle servers
# (Legacy AND Evrima share one exe name), and they restart in the same second. The old
# rule - "the first TheIsleServer-Win64-Shipping that was not running before launch" -
# picked DM NA's process (another tenant, pt_9ef0f72e) at Noobz Legacy 2's 01:01:05Z
# boot. OpenProcess was denied only because every server runs as its own pt_ user; the
# server then ran 4.5 h with NO mod and nothing said so. It nearly repeated at 05:25Z.
# IDENTITY now: the exe lives under THIS server's own volume, it was not running before
# this launch, and it started after it. Nothing else counts. Two matches = REFUSE by
# name (a stale boot of this same server is still alive) - never guess between them.
# The injector job and the supervisor below both use this one function.
$volRoot = (Resolve-Path $root).ProviderPath.TrimEnd('\')
function Find-OwnServer([string]$vol, $beforeIds, [datetime]$since) {
    $prefix = $vol.TrimEnd('\') + '\'
    foreach ($p in @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue)) {
        if ($beforeIds -contains $p.Id) { continue }
        # .Path is $null for a process we may not query (another pt_ user's) - excluded.
        $path = $null; try { $path = $p.Path } catch { }
        if (-not $path -or -not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $gone = $false; try { $gone = $p.HasExited } catch { }
        if ($gone) { continue }
        $st = $null; try { $st = $p.StartTime } catch { }
        if ($st -and $st -lt $since.AddSeconds(-5)) { continue }
        $p
    }
}

# Primal DLL mod: VERIFY + HEAL job (A230; was the one-shot injector of #2700). primal-loader
# (above) normally loads the DLL from INSIDE the game; this job proves it from the process's own
# module list and, if the DLL is absent, LoadLibraryW-injects it via CreateRemoteThread - through
# the same identity gate (Find-OwnServer + owner = the wrapper's user or pt_<volume>, #2724). It
# never gives up while THIS server's process lives: a short burst, then one attempt every 60 s,
# and a module that disappears from a verified pid is re-injected (WATCHDOG). Every pass that
# changes state goes to _primal/primal-inject.log; the plane (POST /v1/boot-report, this server's
# own phsk_ key) hears the first FAILED and the eventual VERIFIED, which resolves its page. The
# supervisor prints each verdict LOUDLY. A failed load is never folded into success (rule 13).
$injJob = $null
if ($env:ENABLE_PRIMAL_MOD -eq '1' -and (Test-Path $primalDll)) {
    $injLog = Join-Path $primalDir 'primal-inject.log'
    $injTries = 4; try { $injTries = [Math]::Max(1, [int](EnvOr $env:PRIMAL_INJECT_ATTEMPTS '4')) } catch { }
    $injJob = Start-Job -Name primal-inject -ArgumentList $primalDll, $before, $injLog, $volRoot, $launchedAt, ${function:Find-OwnServer}.ToString(), $injTries, "$(EnvOr $env:PRIMAL_DATA_BASE 'https://data.primalhosted.com')/v1/boot-report", $phsk, $isleLog, $ldrLog -ScriptBlock {
        param($dll, $beforeIds, $log, $vol, $launchedAt, $findSrc, $tries, $reportUrl, $key, $isleLog, $loaderLog)
        function W($m) { "$(Get-Date -Format 'HH:mm:ss') $m" | Out-File -FilePath $log -Append -Encoding ascii }
        Set-Item -Path function:Find-OwnServer -Value ([scriptblock]::Create($findSrc))
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
  [DllImport("kernel32", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@
        # Seconds the in-process loader gets after the world line (its own settle is 10) / between watchdog passes.
        $graceS = 30; try { if ($env:PRIMAL_INJECT_GRACE_S) { $graceS = [Math]::Max(0, [int]$env:PRIMAL_INJECT_GRACE_S) } } catch { }
        $watchS = 60; try { if ($env:PRIMAL_INJECT_WATCH_S) { $watchS = [Math]::Max(1, [int]$env:PRIMAL_INJECT_WATCH_S) } } catch { }
        "===== primal-inject $(Get-Date -Format o) =====" | Out-File -FilePath $log -Encoding ascii
        W "identity: exe under $vol\, not running before launch, started >= $($launchedAt.ToString('HH:mm:ss')) - user $env:USERNAME; burst $tries, then every $watchS s while the server runs (A230)"
        $name = [IO.Path]::GetFileName($dll)
        $modLike = [IO.Path]::GetFileNameWithoutExtension($dll) + '*' + [IO.Path]::GetExtension($dll)
        function Has-Mod([int]$procId) {
            # $true = in the module list, $false = enumerated and absent, $null = could not enumerate
            # LegacyMod*.dll = the loader/injector's LegacyMod.dll OR a hot-swap copy (LegacyMod-stage-*.dll, mod-manager.ps1)
            try { return [bool](Get-Process -Id $procId -Module -ErrorAction Stop | Where-Object { $_.ModuleName -like $modLike }) } catch { return $null }
        }
        # Whose process may we inject? The wrapper's own user, OR the node's per-server user. Feathers runs
        # each game as pt_<first 8 chars of the volume uuid> while this wrapper can run as the machine
        # account (NS...$): 09-25 16:37Z the old one-user check refused the RIGHT pid on 9900080
        # ('pt_d0e7cefe' vs 'NS1006204$') and three Legacy servers ran without the mod (xstore hotfix).
        # An unread owner ($null) is not a refusal - Find-OwnServer's volume + start-time identity already holds.
        function Get-VolumeUser([string]$v) { return 'pt_' + ((Split-Path $v -Leaf).Split('-')[0]) }
        function Test-OurOwner([string]$o, [string]$v, [string]$me) {
            if (-not $o) { return $true }
            if ($o -ieq (Get-VolumeUser $v)) { return $true }
            if (-not $me) { return $true }
            return ($o -ieq $me)
        }
        function Owner-Of([int]$procId) {
            try {
                $w = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
                $o = Invoke-CimMethod -InputObject $w -MethodName GetOwner -ErrorAction Stop
                if ($o.ReturnValue -eq 0) { return "$($o.User)" }
            } catch { }
            return $null
        }
        # One attempt. Returns @{ ok; reason; pid; path }. Every exit names itself.
        function Try-Inject {
            $c = @(Find-OwnServer $vol $beforeIds $launchedAt)
            if ($c.Count -eq 0) { return @{ ok = $false; reason = "no process of THIS server (exe under $vol) is running"; pid = $null; path = $null } }
            if ($c.Count -gt 1) { return @{ ok = $false; reason = "AMBIGUOUS - $($c.Count) new processes under this volume (pids $(($c | ForEach-Object { $_.Id }) -join ', ')); refusing to guess"; pid = $null; path = $null } }
            $p = $c[0]; $ppath = $p.Path
            $owner = Owner-Of $p.Id
            if (-not (Test-OurOwner $owner $vol $env:USERNAME)) { return @{ ok = $false; reason = "pid $($p.Id) is owned by '$owner', not '$env:USERNAME' or '$(Get-VolumeUser $vol)' - refusing"; pid = $p.Id; path = $ppath } }
            $already = Has-Mod $p.Id
            if ($already -eq $true) { return @{ ok = $true; reason = "already loaded"; pid = $p.Id; path = $ppath } }
            W "injecting into pid $($p.Id) (owner=$(if ($owner) { $owner } else { 'unread' }), exe=$ppath): $dll"
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($dll + [char]0)
            $h = [PInj]::OpenProcess(0x1F0FFF, $false, [uint32]$p.Id)
            if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; reason = "OpenProcess failed on pid $($p.Id) (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"; pid = $p.Id; path = $ppath } }
            try {
                $addr = [PInj]::VirtualAllocEx($h, [IntPtr]::Zero, [uint32]$bytes.Length, 0x3000, 0x04)
                if ($addr -eq [IntPtr]::Zero) { return @{ ok = $false; reason = "VirtualAllocEx failed on pid $($p.Id)"; pid = $p.Id; path = $ppath } }
                $wrote = [UIntPtr]::Zero
                [void][PInj]::WriteProcessMemory($h, $addr, $bytes, [uint32]$bytes.Length, [ref]$wrote)
                $ll = [PInj]::GetProcAddress([PInj]::GetModuleHandleA('kernel32.dll'), 'LoadLibraryW')
                $t = [PInj]::CreateRemoteThread($h, [IntPtr]::Zero, 0, $ll, $addr, 0, [IntPtr]::Zero)
                if ($t -eq [IntPtr]::Zero) { return @{ ok = $false; reason = "CreateRemoteThread failed on pid $($p.Id)"; pid = $p.Id; path = $ppath } }
                [void][PInj]::WaitForSingleObject($t, 15000)
                # LoadLibraryW's return (HMODULE, low 32 bits) is the remote thread exit code:
                # 0 => load FAILED (bad deps / bitness / DllMain crash); non-zero => loaded.
                $ec = 0; [void][PInj]::GetExitCodeThread($t, [ref]$ec)
                [void][PInj]::CloseHandle($t)
                W "inject call complete (LoadLibraryW exit=0x$("{0:x}" -f $ec); 0 = load FAILED)"
            } finally { [void][PInj]::CloseHandle($h) }
            Start-Sleep -Seconds 2
            # The module list is the verdict - not the exit code, not the absence of an error.
            $has = Has-Mod $p.Id
            if ($has -eq $true)  { return @{ ok = $true;  reason = "loaded"; pid = $p.Id; path = $ppath } }
            if ($has -eq $false) { return @{ ok = $false; reason = "$name NOT in pid $($p.Id)'s module list after inject (LoadLibraryW exit=0x$("{0:x}" -f $ec))"; pid = $p.Id; path = $ppath } }
            return @{ ok = $false; reason = "module list of pid $($p.Id) could not be read - UNVERIFIED"; pid = $p.Id; path = $ppath }
        }
        function Report($r, [int]$n) {
            if (-not $key) { W 'NOT REPORTED off-box: no PHSK_KEY on this server'; return 'unreported (no key)' }
            try {
                $body = @{ stage = 'inject'; game = 'legacy'; ok = [bool]$r.ok; attempts = $n; reason = "$($r.reason)"; pid = $r.pid; exePath = "$($r.path)"; dll = $name; volume = $vol } | ConvertTo-Json -Compress
                $resp = Invoke-RestMethod -Method Post -Uri $reportUrl -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body -TimeoutSec 15
                W "reported to the plane: $($resp | ConvertTo-Json -Compress)"
                return "reported (paged=$($resp.paged))"
            } catch {
                W "REPORT TO THE PLANE FAILED: $($_.Exception.Message) - the plane's own mod-absent watch is the backstop"
                return "report FAILED: $($_.Exception.Message)"
            }
        }

        # ---- A230: VERIFY, then KEEP it verified, for as long as THIS server's process lives ----
        # 1. wait for our process (<= 60 s) and THIS boot's world (<= 600 s, the loader's own budget);
        # 2. give the in-process primal-loader its settle (+10 s) and a grace (+20 s) to load the DLL itself;
        # 3. then every pass: Try-Inject (re-find -> identity/owner gate -> "already loaded" = healthy).
        #    Healthy -> VERIFIED (once per pid; says whether primal-loader or the injector put it there).
        #    Absent  -> inject; the first attempts back off 5/10/20 s, then one attempt every 60 s,
        #    FOREVER while the process lives (the old job gave up after 4 and the server ran mod-less for
        #    hours, #2724). The plane hears the first FAILED and the eventual VERIFIED (which resolves it).
        #    A module that DISAPPEARS from a verified pid is logged as WATCHDOG and re-injected.
        # AMBIGUOUS / wrong owner stay refusals on every pass - never a guess (#2700).
        for ($i = 0; $i -lt 120 -and @(Find-OwnServer $vol $beforeIds $launchedAt).Count -eq 0; $i++) { Start-Sleep -Milliseconds 500 }
        if (@(Find-OwnServer $vol $beforeIds $launchedAt).Count -eq 0) {
            $r = @{ ok = $false; reason = "no process of THIS server (exe under $vol) appeared within 60 s"; pid = $null; path = $null }
            W "FAILED: $($r.reason)"; $rep = Report $r 0
            return "FAILED: $($r.reason) ($rep)"
        }
        $up = $false
        for ($i = 0; $i -lt 600 -and -not $up; $i++) {
            if (@(Find-OwnServer $vol $beforeIds $launchedAt).Count -eq 0) { W 'server process ended before its world came up - nothing to verify (the next boot starts over)'; return 'ENDED before the world came up' }
            $up = (Test-Path $isleLog) -and ((Get-Item $isleLog).LastWriteTime -gt $launchedAt) -and (Select-String -Path $isleLog -Pattern 'LogWorld: Bringing World|LogLoad: Took .* to LoadMap' -Quiet)
            if (-not $up) { Start-Sleep -Seconds 1 }
        }
        W $(if ($up) { "world is up; waiting $graceS s for primal-loader (in-process) before the first check" } else { "world line not seen in 600 s - checking anyway" })
        Start-Sleep -Seconds $graceS
        $verifiedPid = $null; $failReported = $false; $n = 0
        while ($true) {
            $r = Try-Inject
            if ($r.ok) {
                # A pass that had to INJECT into the pid we had already verified = the DLL went missing
                # and this pass healed it (the watchdog case). Said and reported, never silent.
                if ($r.reason -ne 'already loaded' -and $verifiedPid -and $r.pid -eq $verifiedPid) {
                    W "WATCHDOG: $name was GONE from verified pid $($r.pid) - re-injected"
                    $verifiedPid = $null
                }
                if ($r.pid -ne $verifiedPid) {
                    $via = if ($r.reason -ne 'already loaded') { "the injector (attempt $([Math]::Max(1, $n)))" }
                           elseif ((Test-Path $loaderLog) -and (Select-String -Path $loaderLog -Pattern "pid $($r.pid) LOADED" -SimpleMatch -Quiet)) { 'primal-loader (in-process, no injection)' }
                           else { 'already present (hot-swap or a previous pass)' }
                    W "VERIFIED: $name is loaded in pid $($r.pid) ($($r.path)) - via $via"
                    $rep = Report $r ([Math]::Max(1, $n))
                    "VERIFIED pid $($r.pid) via $via ($rep)"
                    $verifiedPid = $r.pid; $failReported = $false; $n = 0
                }
                Start-Sleep -Seconds $watchS
                continue
            }
            if (-not $r.pid -and $r.reason -like 'no process of THIS server*') {
                W "server process ended - the watchdog stops (a new boot starts a new one)"
                return 'ENDED (server process exited)'
            }
            if ($verifiedPid -and $r.pid -eq $verifiedPid) { W "WATCHDOG: $name was GONE from verified pid $($r.pid) - re-inject FAILED, retrying" }
            $verifiedPid = $null
            $n++
            W "attempt $n FAILED: $($r.reason)"
            if (-not $failReported -and $n -ge $tries) {
                W "FAILED: the mod is NOT loaded after $n attempt(s) - last: $($r.reason) - STILL RETRYING every $watchS s while this server runs"
                $rep = Report $r $n
                "FAILED after $n attempt(s), still retrying: $($r.reason) ($rep)"
                $failReported = $true
            }
            if ($n -lt $tries) { Start-Sleep -Seconds ([Math]::Min(30, 5 * [Math]::Pow(2, $n - 1))) } else { Start-Sleep -Seconds $watchS }
        }
    }
    Write-Host "(primal-mod) verify+heal armed (identity = exe under $volRoot; primal-loader first, then inject: burst $injTries + every 60 s while the server runs; result -> _primal/primal-inject.log; loader -> _primal/primal-loader.log; mod runtime -> _primal/legacy_mod.log)"

    # Hot-swap watcher: stage/unstage WITHOUT a server restart. Injects a new DLL
    # version on demand when _primal/restage.flag appears (paired with the mod's
    # `unload` command). Self-contained in _primal/mod-manager.ps1.
    $mgrScript = Join-Path $primalDir 'mod-manager.ps1'
    if (Test-Path $mgrScript) {
        Start-Job -Name primal-restage -ArgumentList $mgrScript, $primalDir -ScriptBlock {
            param($s, $pd)
            & $s -PrimalDir $pd
        } | Out-Null
        Write-Host "(primal-mod) hot-swap watcher armed -> _primal/mod-manager.log"
    }
}

# Multihome (opt-in): Legacy historically launched WITHOUT -MULTIHOME. For per-server
# DDoS isolation you can bind/advertise ONE specific public IP by setting MULTIHOME_IP.
# Left BLANK (default) = unchanged behaviour (bind all interfaces) so the live OVH box
# is untouched. ⚠️ test on a SPARE server first - some Legacy builds are picky.
#
# Legacy = STEAM networking (app 412680, UE4.25), NOT EOS - the Evrima
# EOS_OVERRIDE_HOST_IP fix does nothing here. The lever is the UE4 MultiHome ARG.
# MEASURED 2026-09-05 (multihome-97-0905, win3 = feathers node 6, TWO egg-41 servers
# on distinct IPs with the SAME 7777/7778, A/B/A, read off the box + A2S + Steam master):
#   cli  (`-MULTIHOME=<ip>`)           -> binds <ip>:7778 + :7779, A2S answers on <ip>
#                                        only, Steam master lists <ip>:7778.   WORKS.
#   url  (`?MultiHome=<ip>` in URL)    -> binds 0.0.0.0:7778, A2S answers on the box
#                                        PRIMARY only, Steam lists the PRIMARY. DEAD.
#   both (url + cli)                   -> SAME AS url: the URL option NEGATES the arg.
#                                        Not belt-and-suspenders - it removes the belt.
# => MULTIHOME_MODE is pinned to cli below; url/both are honoured as cli and SAID so.
# SERVER_IP is REAL on feathers: the wrapper printed the default-allocation IP from it
# on both servers (src=MULTIHOME_AUTO->SERVER_IP), and the box bound exactly that IP.
#
# #1832/#97 - AUTO fallback. Evrima's wrapper does `EnvOr $env:MULTIHOME_IP
# $env:SERVER_IP` unconditionally; Legacy gates the same fallback on MULTIHOME_AUTO.
# History: Ice ruled 2026-07-27 "peg them to the default as though it were intentional
# until Legacy multihome is proven on a test server" - so the egg default was 0 (bind
# all interfaces). PROVEN 2026-09-05/06 (G12: two servers on win3, own-ip binds, A2S
# and Steam per ip, restart isolation, and a human joined EACH by ip) => the egg
# default is 1 as of 2026-09-06 (build_egg.py). An egg default reaches NEW provisions
# only: an existing volume keeps the wrapper it installed with, and a per-server
# MULTIHOME_AUTO value set in the panel always wins over the default.
# #2038: a multihomed Legacy server binds THREE udp ports on its ip - Port, QueryPort
# and QueryPort+1 (Steam's master-server port, which the game takes on its own) - so
# the panel must hand it 3 allocations; on 2 the third reads as `bound_unassigned`.
$mhMode = (EnvOr $env:MULTIHOME_MODE 'cli').ToLower()
if ($mhMode -ne 'cli') {
    # Hard rule 13: url/both used to print "multihome BOUND ... mode=url" while the box
    # showed 0.0.0.0:7778 - a false success line. Measured dead 2026-09-05; pinned to cli.
    Write-Host "(start) multihome MODE '$mhMode' is DEAD (measured 2026-09-05: it binds 0.0.0.0) - using cli (-MULTIHOME=) instead"
    $mhMode = 'cli'
}
$mhArgs = @()
$mhIp   = ('' + $env:MULTIHOME_IP).Trim()
$mhSrc  = 'MULTIHOME_IP'
if (-not $mhIp -and ('' + $env:MULTIHOME_AUTO).Trim() -eq '1') {
    $mhIp  = ('' + $env:SERVER_IP).Trim()
    $mhSrc = 'MULTIHOME_AUTO->SERVER_IP'
}
if ($mhIp -and $mhIp -ne '0.0.0.0' -and $mhIp -match '^\d{1,3}(\.\d{1,3}){3}$') {
    # cli is the ONLY form that binds (see the measured table above). Never put
    # ?MultiHome= in the travel URL - it un-multihomes the server even beside the arg.
    $mhArgs = @("-MULTIHOME=$mhIp")
    Write-Host "(start) multihome BOUND ip=$mhIp src=$mhSrc mode=$mhMode  args=[$($mhArgs -join ' ')]"
} else {
    # Hard rule 13: this branch used to be COMPLETELY SILENT, which is half of why
    # #1832 hid - a server that binds 0.0.0.0 looked identical in the log to one that
    # bound its own IP. Every outcome now names itself.
    if (('' + $env:MULTIHOME_AUTO).Trim() -eq '1') {
        Write-Host "(start) multihome AUTO=1 but no usable IP (MULTIHOME_IP='$($env:MULTIHOME_IP)' SERVER_IP='$($env:SERVER_IP)') - binding ALL INTERFACES"
    } else {
        Write-Host "(start) multihome OFF (MULTIHOME_IP empty, MULTIHOME_AUTO=0) - binding ALL INTERFACES on 0.0.0.0:$queryPort"
    }
    Write-Host "(start)   #1832: on 0.0.0.0 the query port is a BOX-WIDE namespace - the first Legacy server on this box owns $queryPort on every IP, and a later server given the same port on its OWN ip will fail Steam init and never list."
}

# Foreground launch: if Legacy runs in-process, this BLOCKS for the server's whole
# life and its stdout streams straight to feathers (correct). If instead it detaches,
# `&` returns fast and we fall through to find + supervise the detached process.
& $exe $url @mhArgs -log

# #2700: the SAME identity as the injector - "the first new process" here used to be
# able to supervise ANOTHER server's life (and HasExited on another pt_ user's process
# cannot even be read). Both of two matches are OURS (same volume), so the supervisor
# takes the newest and SAYS so; the injector, which must not guess, refuses instead.
$own = @()
for ($i = 0; $i -lt 30 -and $own.Count -ne 1; $i++) {
    $own = @(Find-OwnServer $volRoot $before $launchedAt)
    if ($own.Count -ne 1) { Start-Sleep -Milliseconds 500 }
}
$proc = $own | Sort-Object { try { $_.StartTime } catch { [datetime]::MinValue } } | Select-Object -Last 1
if ($own.Count -gt 1) { Write-Host "(start) *** $($own.Count) new server processes under THIS volume (pids $(($own | ForEach-Object { $_.Id }) -join ', ')) - supervising the newest ($($proc.Id)); a second copy of this server is running - restart it ***" }
# The verify+heal job's verdicts, LOUD, on the console the moment each one happens (#2700, A230).
# The job lives as long as the server, so its lines are drained incrementally, never waited for.
function Show-InjectVerdict {
    if (-not $script:injJob) { return }
    foreach ($line in @(Receive-Job $script:injJob -ErrorAction SilentlyContinue)) {
        $v = ('' + $line).Trim()
        if (-not $v) { continue }
        if ($v -like 'VERIFIED*') { Write-Host "(primal-mod) inject $v" }
        elseif ($v -like 'ENDED*') { Write-Host "(primal-mod) verify+heal $v" }
        else {
            Write-Host '(primal-mod) ****************************************************************'
            Write-Host "(primal-mod) *** MOD NOT LOADED: $v"
            Write-Host '(primal-mod) *** The game is running WITHOUT the Primal mod: no telemetry, admin,'
            Write-Host '(primal-mod) *** storage or anticheat. The wrapper keeps retrying every 60 s and the'
            Write-Host '(primal-mod) *** plane has been told; read _primal/primal-inject.log. (#2700, A230)'
            Write-Host '(primal-mod) ****************************************************************'
        }
    }
    if ($script:injJob.State -ne 'Running' -and $script:injJob.State -ne 'NotStarted') {
        if ($script:injJob.State -ne 'Completed') { Write-Host "(primal-mod) *** verify+heal job ended $($script:injJob.State) - read _primal/primal-inject.log" }
        Remove-Job $script:injJob -Force -ErrorAction SilentlyContinue
        $script:injJob = $null
    }
}
if ($proc) {
    Write-Host "(start) supervising detached server pid $($proc.Id) ($($proc.Path))"
    $pos = 0
    while (-not $proc.HasExited) {
        Show-InjectVerdict
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
Show-InjectVerdict
if ($script:injJob) { Stop-Job $script:injJob -ErrorAction SilentlyContinue; Remove-Job $script:injJob -Force -ErrorAction SilentlyContinue }
Write-Host "(exit) $(Get-Date -Format HH:mm:ss) Legacy server process ended; feathers will restart per policy."
