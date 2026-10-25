# Behaviour test for A836 - region spawning (bUseRegionSpawning and its two cooldown keys).
# Runs the WHOLE shipping wrapper in its render-only mode, once per case, against a
# local stand-in for the plane's /v1/boot-config, and reads the Game.ini the game reads.
#   powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_regionspawn.ps1
#   ... -Wrapper <path> -Templates <dir>   judges another copy (an older commit, a mutant)
param(
    [string]$Wrapper = (Join-Path $PSScriptRoot 'start-evrima.ps1'),
    [string]$Templates = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
$Wrapper = (Resolve-Path -LiteralPath $Wrapper).Path
Write-Host "wrapper under test: $Wrapper`n"

$KEY  = 'phsk_' + ('0' * 48)
$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  ok   $name" } else { $script:fail++; Write-Host "  FAIL $name  $detail" }
}

$listener = $null
foreach ($try in 1..20) {
    $port = Get-Random -Minimum 20000 -Maximum 60000
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    try { $listener.Start(); break } catch { $listener = $null }
}
if (-not $listener) { throw 'could not open a local listener' }
$planeUp   = "http://localhost:$port"
$planeDown = 'http://localhost:1'

$work = Join-Path $env:TEMP ('rs_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

function New-Volume {
    $v = Join-Path $work ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $v '_primal') -Force | Out-Null
    foreach ($t in @('Game.ini.tmpl', 'Engine.ini.tmpl')) { Copy-Item (Join-Path $Templates $t) (Join-Path $v "_primal\$t") }
    return $v
}
function GamePath([string]$vol) { return (Join-Path $vol 'server\TheIsle\Saved\Config\WindowsServer\Game.ini') }

# $ss = the plane's server_settings for this boot (a hashtable), or $null for "the plane is unreachable".
function Boot([string]$vol, $ss) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = (Get-Process -Id $PID).Path
    $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$Wrapper`""
    $psi.WorkingDirectory       = $vol
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.EnvironmentVariables['PHSK_KEY']           = $KEY
    $psi.EnvironmentVariables['ENABLE_PRIMAL_MOD']  = '1'
    $psi.EnvironmentVariables['PRIMAL_RENDER_ONLY'] = '1'
    $psi.EnvironmentVariables['AUTO_UPDATE']        = '0'
    $psi.EnvironmentVariables['PRIMAL_DATA_BASE']   = $(if ($null -ne $ss) { $planeUp } else { $planeDown })
    $p    = [System.Diagnostics.Process]::Start($psi)
    $outT = $p.StandardOutput.ReadToEndAsync()
    $errT = $p.StandardError.ReadToEndAsync()
    if ($null -ne $ss) {
        $ctxT = $listener.GetContextAsync()
        if (-not $ctxT.Wait(60000)) { try { $p.Kill() } catch {}; throw 'the wrapper never asked for /v1/boot-config' }
        $ctx  = $ctxT.Result
        $s    = @{ serverName = 'RS-TEST' }
        foreach ($k in $ss.Keys) { $s[$k] = $ss[$k] }
        $body = @{
            serverId = 9999; scope = @{}; updatedAt = '2026-01-01T00:00:00.000Z'; clamped = @()
            config   = @{ server_settings = $s; mod_settings = @{} }
        } | ConvertTo-Json -Depth 8
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    }
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; throw 'the wrapper did not finish its render-only run' }
    $gi = ''
    if (Test-Path -LiteralPath (GamePath $vol)) { $gi = [System.IO.File]::ReadAllText((GamePath $vol)) }
    return @{ Exit = $p.ExitCode; Out = $outT.Result; Err = $errT.Result; Game = $gi }
}

function Lines([string]$gi, [string]$key) { return @($gi -split "`r?`n" | Where-Object { $_ -match ('^\s*' + [regex]::Escape($key) + '\s*=') }) }
function One([string]$gi, [string]$key) { $l = @(Lines $gi $key); if ($l.Count -eq 1) { return $l[0].Trim() } return ($l -join ' | ') }

try {
    Write-Host 'A836 - the owner turns region spawning on'
    $r = Boot (New-Volume) @{ useRegionSpawning = $true; useRegionSpawnCooldown = $true; regionSpawnCooldownSeconds = 77 }
    Check 'the render-only run exits 0' ($r.Exit -eq 0) "exit=$($r.Exit) err=$($r.Err)"
    Check 'useRegionSpawning true => bUseRegionSpawning=True' ((One $r.Game 'bUseRegionSpawning') -ceq 'bUseRegionSpawning=True') (One $r.Game 'bUseRegionSpawning')
    Check 'useRegionSpawnCooldown true => bUseRegionSpawnCooldown=True' ((One $r.Game 'bUseRegionSpawnCooldown') -ceq 'bUseRegionSpawnCooldown=True') (One $r.Game 'bUseRegionSpawnCooldown')
    Check 'regionSpawnCooldownSeconds 77 => RegionSpawnCooldownTimeSeconds=77' ((One $r.Game 'RegionSpawnCooldownTimeSeconds') -ceq 'RegionSpawnCooldownTimeSeconds=77') (One $r.Game 'RegionSpawnCooldownTimeSeconds')
    Check 'no placeholder is left in Game.ini' ($r.Game -notmatch '\{\{') (([regex]::Matches($r.Game, '\{\{[^}]*\}\}') | ForEach-Object { $_.Value }) -join ' ')

    Write-Host 'A836 - default stays off'
    $r = Boot (New-Volume) @{ maxPlayerCount = 100 }
    Check 'no region fields => bUseRegionSpawning=False' ((One $r.Game 'bUseRegionSpawning') -ceq 'bUseRegionSpawning=False') (One $r.Game 'bUseRegionSpawning')
    Check '...bUseRegionSpawnCooldown=False' ((One $r.Game 'bUseRegionSpawnCooldown') -ceq 'bUseRegionSpawnCooldown=False') (One $r.Game 'bUseRegionSpawnCooldown')
    Check '...RegionSpawnCooldownTimeSeconds=150' ((One $r.Game 'RegionSpawnCooldownTimeSeconds') -ceq 'RegionSpawnCooldownTimeSeconds=150') (One $r.Game 'RegionSpawnCooldownTimeSeconds')
    $r = Boot (New-Volume) @{ useRegionSpawning = $false; useRegionSpawnCooldown = $false; regionSpawnCooldownSeconds = 150 }
    Check 'explicit false => bUseRegionSpawning=False' ((One $r.Game 'bUseRegionSpawning') -ceq 'bUseRegionSpawning=False') (One $r.Game 'bUseRegionSpawning')

    Write-Host 'A836 - switched back off on the same volume'
    $v = New-Volume
    $r1 = Boot $v @{ useRegionSpawning = $true }
    $r2 = Boot $v @{ useRegionSpawning = $false }
    Check 'boot 1 on, boot 2 off => True then False' ((One $r1.Game 'bUseRegionSpawning') -ceq 'bUseRegionSpawning=True' -and (One $r2.Game 'bUseRegionSpawning') -ceq 'bUseRegionSpawning=False') "$(One $r1.Game 'bUseRegionSpawning') / $(One $r2.Game 'bUseRegionSpawning')"

    Write-Host 'A836 - a plane outage keeps the last value'
    $v = New-Volume
    $null = Boot $v @{ useRegionSpawning = $true }
    $r = Boot $v $null
    Check 'plane unreachable => rendered from the cache with the switch on' ($r.Exit -eq 0 -and (One $r.Game 'bUseRegionSpawning') -ceq 'bUseRegionSpawning=True') (One $r.Game 'bUseRegionSpawning')
} finally {
    $listener.Stop()
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host "`n$pass passed, $fail failed"
if ($fail) { exit 1 }
