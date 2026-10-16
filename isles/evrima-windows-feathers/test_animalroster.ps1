# Behaviour test for A431 - the AnimalRoster line (play as an animal).
# Runs the WHOLE shipping wrapper in its render-only mode, once per case, against a
# local stand-in for the plane's /v1/boot-config, and reads the Engine.ini the game
# would read. Nothing is lifted or re-implemented: the bytes come from the real file.
#   powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_animalroster.ps1
#   ... -Wrapper <path>   judges another copy of the wrapper (a mutant, or an older commit)
param([string]$Wrapper = (Join-Path $PSScriptRoot 'start-evrima.ps1'))
$ErrorActionPreference = 'Stop'
$Wrapper = (Resolve-Path -LiteralPath $Wrapper).Path
Write-Host "wrapper under test: $Wrapper`n"

$SEC  = '[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]'
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

$work = Join-Path $env:TEMP ('ar_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

# One "volume": the two templates in _primal, like an installed server.
function New-Volume {
    $v = Join-Path $work ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $v '_primal') -Force | Out-Null
    foreach ($t in @('Game.ini.tmpl', 'Engine.ini.tmpl')) { Copy-Item (Join-Path $PSScriptRoot $t) (Join-Path $v "_primal\$t") }
    return $v
}
function EnginePath([string]$vol) { return (Join-Path $vol 'server\TheIsle\Saved\Config\WindowsServer\Engine.ini') }

# $ms = the plane's mod_settings block for this boot (a hashtable), or $null for "the
# plane is unreachable" (the wrapper then renders from its own cache, or defaults).
function Boot([string]$vol, $ms, [string]$modOn = '1') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = (Get-Process -Id $PID).Path
    $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$Wrapper`""
    $psi.WorkingDirectory       = $vol
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.EnvironmentVariables['PHSK_KEY']           = $KEY
    $psi.EnvironmentVariables['ENABLE_PRIMAL_MOD']  = $modOn
    $psi.EnvironmentVariables['PRIMAL_RENDER_ONLY'] = '1'
    $psi.EnvironmentVariables['AUTO_UPDATE']        = '0'
    $psi.EnvironmentVariables['PRIMAL_DATA_BASE']   = $(if ($null -ne $ms) { $planeUp } else { $planeDown })
    $p    = [System.Diagnostics.Process]::Start($psi)
    $outT = $p.StandardOutput.ReadToEndAsync()
    $errT = $p.StandardError.ReadToEndAsync()
    $asked = ''
    if ($null -ne $ms) {
        $ctxT = $listener.GetContextAsync()
        if (-not $ctxT.Wait(60000)) { try { $p.Kill() } catch {}; throw 'the wrapper never asked for /v1/boot-config' }
        $ctx   = $ctxT.Result
        $asked = $ctx.Request.Url.AbsolutePath
        $body  = @{
            serverId = 9999; scope = @{}; updatedAt = '2026-01-01T00:00:00.000Z'; clamped = @()
            config   = @{ server_settings = @{ serverName = 'AR-TEST' }; mod_settings = $ms }
        } | ConvertTo-Json -Depth 8
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    }
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; throw 'the wrapper did not finish its render-only run' }
    $eng = ''
    if (Test-Path -LiteralPath (EnginePath $vol)) { $eng = [System.IO.File]::ReadAllText((EnginePath $vol)) }
    $carry = ''
    $cp = Join-Path $vol '_primal\engine-carry.ini'
    if (Test-Path -LiteralPath $cp) { $carry = [System.IO.File]::ReadAllText($cp) }
    return @{ Exit = $p.ExitCode; Out = $outT.Result; Err = $errT.Result; Engine = $eng; Carry = $carry; Asked = $asked }
}

# The pak section's lines, as the game reads them (LF file, first copy of a key wins).
function PakLines([string]$eng) {
    $m = [regex]::Match($eng, '(?ms)^' + [regex]::Escape($SEC) + '\n(.*?)(?=^\[|\z)')
    if (-not $m.Success) { return @() }
    return @($m.Groups[1].Value -split "`n" | Where-Object { $_ -ne '' })
}
function RosterLines([string]$text) { return @($text -split "`r?`n" | Where-Object { $_ -match '^\s*AnimalRoster\s*=' }) }
function NoteLine([string]$out)     { return (@($out -split "`r?`n" | Where-Object { $_ -match 'Engine\.ini: AnimalRoster ' }) -join ' | ') }

try {
    Write-Host 'A431 - the panel''s pick is the line, byte for byte'
    $v = New-Volume
    $r = Boot $v @{ animalRoster = 'Boar,Deer' }
    Check 'the render-only run exits 0 and asked the plane for /v1/boot-config' ($r.Exit -eq 0 -and $r.Asked -eq '/v1/boot-config') "exit=$($r.Exit) asked=$($r.Asked) err=$($r.Err)"
    $pak = PakLines $r.Engine
    Check 'pick Boar,Deer renders AnimalRoster=Boar,Deer in the pak section' ($pak -ccontains 'AnimalRoster=Boar,Deer') ($pak -join ' / ')
    Check 'exactly one AnimalRoster line in the whole file' ((RosterLines $r.Engine).Count -eq 1)
    Check 'the console names the pick and who owns the key' ((NoteLine $r.Out) -match 'AnimalRoster Boar,Deer \(the panel''s pick\)\. The panel owns this key') (NoteLine $r.Out)
    Check 'the token and the poll URL are still the first two keys' ($pak[0] -ceq "ApiToken=$KEY" -and $pak[1] -ceq "PollURL=$planeUp/v1/commands/text") ($pak[0..1] -join ' / ')
    Check 'the file is LF only (a CR would land inside the token)' (-not $r.Engine.Contains("`r"))
    Check 'an owned key is never written to the hand-set copy' ((RosterLines $r.Carry).Count -eq 0) $r.Carry

    $all = 'Boar,Deer,Chicken,Rabbit,Seaturtle,GoatBaby'
    $r = Boot (New-Volume) @{ animalRoster = $all }
    Check 'all six offered animals render in the owner''s order' ((PakLines $r.Engine) -ccontains "AnimalRoster=$all")
    $r = Boot (New-Volume) @{ animalRoster = 'GoatBaby' }
    Check 'one animal renders alone' ((PakLines $r.Engine) -ccontains 'AnimalRoster=GoatBaby')

    Write-Host 'A431 - no pick writes nothing'
    $vNone = New-Volume
    $rNone = Boot $vNone @{ aiMaxCount = 40 }
    Check 'no animalRoster field => no AnimalRoster line' ($rNone.Exit -eq 0 -and (RosterLines $rNone.Engine).Count -eq 0)
    Check 'the console says so, and does not call it a pick' ((NoteLine $rNone.Out) -match 'AnimalRoster not rendered - this boot''s config carries no animal pick') (NoteLine $rNone.Out)
    $r = Boot (New-Volume) @{ animalRoster = '' }
    Check 'an empty string => no line, and it is not reported as a refusal' ((RosterLines $r.Engine).Count -eq 0 -and (NoteLine $r.Out) -match 'not rendered' -and (NoteLine $r.Out) -notmatch 'SKIPPED') (NoteLine $r.Out)
    $withPick = Boot (New-Volume) @{ aiMaxCount = 40; animalRoster = 'Boar' }
    $strip = { param($t) (@($t -split "`n" | Where-Object { $_ -cne 'AnimalRoster=Boar' }) -join "`n") }
    Check 'a pick adds ONE line and changes no other byte of Engine.ini' ((& $strip $withPick.Engine) -ceq $rNone.Engine -and $withPick.Engine -cne $rNone.Engine)

    Write-Host 'A431 - the key is owned: clearing the pick clears the line'
    $v = New-Volume
    $r1 = Boot $v @{ animalRoster = 'Boar,Deer' }
    $r2 = Boot $v @{ aiMaxCount = 40 }
    Check 'boot 1 has the line' ((RosterLines $r1.Engine).Count -eq 1)
    Check 'boot 2, pick cleared, same volume => the line is gone' ((RosterLines $r2.Engine).Count -eq 0) ((PakLines $r2.Engine) -join ' / ')
    Check '...and it is not carried as a hand-set key' ((RosterLines $r2.Carry).Count -eq 0 -and $r2.Out -notmatch 'carried forward \d+ hand-set pak key\(s\)[^\r\n]*AnimalRoster') $r2.Carry
    $r3 = Boot $v @{ animalRoster = 'Chicken' }
    Check 'boot 3, a new pick => one line, the new value' (((RosterLines $r3.Engine) -join '|') -ceq 'AnimalRoster=Chicken') ((RosterLines $r3.Engine) -join '|')

    Write-Host 'A431 - a hand-set AnimalRoster is not kept; other hand-set keys are'
    $v = New-Volume
    New-Item -ItemType Directory -Path (Split-Path (EnginePath $v)) -Force | Out-Null
    [System.IO.File]::WriteAllText((EnginePath $v), "$SEC`nApiToken=old`nAnimalRoster=Bullfrog`nIrisCensusEvery=77`n", [System.Text.Encoding]::ASCII)
    $r = Boot $v @{ aiMaxCount = 40 }
    Check 'no pick => the hand-set AnimalRoster=Bullfrog is dropped' ((RosterLines $r.Engine).Count -eq 0) ((RosterLines $r.Engine) -join '|')
    Check 'the hand-set IrisCensusEvery=77 beside it survives' ((PakLines $r.Engine) -ccontains 'IrisCensusEvery=77')
    Check 'the hand-set copy holds IrisCensusEvery and no AnimalRoster' ($r.Carry -match 'IrisCensusEvery=77' -and (RosterLines $r.Carry).Count -eq 0) $r.Carry
    [System.IO.File]::WriteAllText((EnginePath $v), "$SEC`nApiToken=old`nAnimalRoster=Bullfrog`n", [System.Text.Encoding]::ASCII)
    $r = Boot $v @{ animalRoster = 'Boar' }
    Check 'a pick beats a hand-set line: one line, the panel''s' (((RosterLines $r.Engine) -join '|') -ceq 'AnimalRoster=Boar') ((RosterLines $r.Engine) -join '|')

    Write-Host 'A431 - a value that is not a plain name list is refused whole, and said'
    $bad = [ordered]@{
        'a line break (Engine.ini line injection)' = "Boar`nApiToken=stolen"
        'a trailing line break'                    = "Boar`n"
        'a CR LF inside'                           = "Boar`r`nDeer"
        'an empty entry'                           = 'Boar,,Deer'
        'a trailing comma'                         = 'Boar,'
        'a leading space'                          = ' Boar'
        'a space after the comma'                  = 'Boar, Deer'
        'a semicolon list'                         = 'Boar;Deer'
        'a section header'                         = '[Core.Log]'
        'a key=value'                              = 'Boar=1'
        'a 65-character name'                      = ('B' * 65)
        '33 names'                                 = ((1..33 | ForEach-Object { 'Boar' }) -join ',')
    }
    foreach ($name in $bad.Keys) {
        $r = Boot (New-Volume) @{ animalRoster = $bad[$name] }
        $pak = PakLines $r.Engine
        $oneToken = (@($r.Engine -split "`n" | Where-Object { $_ -match '^\s*ApiToken\s*=' }).Count -eq 1) -and ($pak[0] -ceq "ApiToken=$KEY")
        Check "$name => no AnimalRoster line, the token untouched, SKIPPED on the console" `
            ($r.Exit -eq 0 -and (RosterLines $r.Engine).Count -eq 0 -and $oneToken -and (NoteLine $r.Out) -match 'AnimalRoster SKIPPED' -and $r.Engine -notmatch 'stolen') (NoteLine $r.Out)
    }
    $r = Boot (New-Volume) @{ animalRoster = @('Boar', 'Deer') }
    Check 'a JSON list instead of the csv string => refused (the plane sends one string)' ((RosterLines $r.Engine).Count -eq 0 -and (NoteLine $r.Out) -match 'SKIPPED') (NoteLine $r.Out)
    $r = Boot (New-Volume) @{ animalRoster = ((1..32 | ForEach-Object { 'Boar' }) -join ',') }
    Check '32 names is the most the shape allows, and it renders' ((RosterLines $r.Engine).Count -eq 1)

    Write-Host 'A431 - a plane outage does not strip the roster'
    $v = New-Volume
    $r1 = Boot $v @{ animalRoster = 'Boar,Deer' }
    $r2 = Boot $v $null
    Check 'plane unreachable => rendered from the cache, and says so' ($r2.Exit -eq 0 -and $r2.Out -match 'DATA PLANE UNREACHABLE - RENDERING FROM CACHE') $r2.Out
    Check '...with the last fetched pick' ((PakLines $r2.Engine) -ccontains 'AnimalRoster=Boar,Deer')
    $r = Boot (New-Volume) $null
    Check 'no plane and no cache (first boot) => no line, the game''s own roster' ($r.Exit -eq 0 -and (RosterLines $r.Engine).Count -eq 0 -and (NoteLine $r.Out) -match 'not rendered')

    Write-Host 'A431 - mod off: no pak section, so no roster line and no claim of one'
    $r = Boot (New-Volume) @{ animalRoster = 'Boar' } '0'
    Check 'ENABLE_PRIMAL_MOD=0 => no pak section, no AnimalRoster, no AnimalRoster console line' ($r.Exit -eq 0 -and (PakLines $r.Engine).Count -eq 0 -and (RosterLines $r.Engine).Count -eq 0 -and (NoteLine $r.Out) -eq '') (NoteLine $r.Out)
} finally {
    $listener.Stop()
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host "`n$pass passed, $fail failed"
if ($fail) { exit 1 }
