# Behaviour test for the mass-migration / patrol timing lines in start-evrima.ps1 (BUGS #3328, #3362).
# Runs the REAL lines lifted from the shipping wrapper, never a copy of them.
#   powershell -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_masstiming.ps1
$ErrorActionPreference = 'Stop'
$lines = Get-Content (Join-Path $PSScriptRoot 'start-evrima.ps1')

function Lift([string]$from, [string]$to) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { throw "anchor not found: $from" }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { throw "end anchor not found: $to" }
    return ($lines[($a-1)..($a+$b-2)] -join "`n")
}
# A: the function + the two always-on keys, up to (not including) the Game.ini write.
$blockA = Lift 'function Set-SessionKey' "Set-Content -Path (Join-Path `$cfgDir 'Game.ini')"
$blockA = ($blockA -split "`n" | Select-Object -SkipLast 1) -join "`n"
# B: MassMigrationTime, decided after the commban block.
$blockB = Lift '$massT = ' '# primal-loader: THE GAME LOADS'
$blockB = ($blockB -split "`n" | Select-Object -SkipLast 2) -join "`n"

Invoke-Expression (($lines | Select-String -SimpleMatch 'function Has(' | Select-Object -First 1).Line)

$tmplPath = Join-Path $PSScriptRoot 'Game.ini.tmpl'
$TMPL = Get-Content $tmplPath -Raw
$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}
function Count([string]$text, [string]$pattern) { return ([regex]::Matches($text, $pattern)).Count }
function SessionBody([string]$ini) {
    $m = [regex]::Match($ini, '(?ms)^\[/script/theisle\.tigamesession\][^\n]*\n(.*?)(?=^\[)')
    return $m.Groups[1].Value
}

Write-Host "A - always-on keys"
$gi = $TMPL
Invoke-Expression $blockA
$body = SessionBody $gi
Ok 'D in the session section' ($body -match '(?m)^MassMigrationDisableTime=2700\r?$')
Ok 'patrol time in the session section' ($body -match '(?m)^IndividualPatrolTime=300\r?$')
Ok 'each exactly once' ((Count $gi '(?mi)^MassMigrationDisableTime=') -eq 1 -and (Count $gi '(?mi)^IndividualPatrolTime=') -eq 1)
Ok 'no MassMigrationTime before the commban block decides' ((Count $gi '(?mi)^MassMigrationTime=') -eq 0)
Ok 'nothing else lost' ($gi.Replace("MassMigrationDisableTime=2700`r`n", '').Replace("IndividualPatrolTime=300`r`n", '') -eq $TMPL)

$gi = $TMPL.Replace('bEnablePatrolZones={{EnablePatrolZones}}', "bEnablePatrolZones={{EnablePatrolZones}}`nIndividualPatrolTime=1200`nmassmigrationdisabletime = 7200")
Invoke-Expression $blockA
Ok 'a hand-set value is replaced, never doubled' ((Count $gi '(?mi)^IndividualPatrolTime=') -eq 1 -and (Count $gi '(?mi)^\s*MassMigrationDisableTime\s*=') -eq 1 -and $gi -notmatch '7200|=1200')

$gi = $TMPL.Replace('[/script/theisle.tigamesession]', '[/script/theisle.somethingelse]')
$out = Invoke-Expression $blockA 6>&1 | Out-String
Ok 'no session section: said, not silent' ($out -match 'WARNING no \[/script/theisle.tigamesession\] section')
Ok '...and nothing was added' ((Count $gi '(?mi)^IndividualPatrolTime=') -eq 0)

Write-Host "B - MassMigrationTime: parked 48 h by default, the plane's value, or 48 h for a declared mass rung"
$cfgDir = Join-Path $env:TEMP ('mt_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $cfgDir | Out-Null
$rung = [pscustomobject]@{ version = '1.5.0'; mass_rung = $true }
$cases = @(
    @{ n = 'commban 1.4.4, no plane value';    ready = $true;  cm = [pscustomobject]@{ version = '1.4.4' }; ss = $null;                                         want = '172800'; say = 'parked 48 h' },
    @{ n = 'commban off, no plane value';      ready = $false; cm = $null;                                  ss = [pscustomobject]@{ maxPlayers = 100 };     want = '172800'; say = 'parked 48 h' },
    @{ n = 'plane 36000';                      ready = $true;  cm = [pscustomobject]@{ version = '1.4.4' }; ss = [pscustomobject]@{ massMigrationTime = 36000 };   want = '36000';  say = 'the plane' },
    @{ n = 'plane padded string';              ready = $false; cm = $null;                                  ss = [pscustomobject]@{ massMigrationTime = ' 21600 ' }; want = '21600';  say = 'the plane' },
    @{ n = 'plane 3600 (the floor)';           ready = $false; cm = $null;                                  ss = [pscustomobject]@{ massMigrationTime = 3600 };    want = '3600';   say = 'the plane' },
    @{ n = 'plane 3599 refused';               ready = $false; cm = $null;                                  ss = [pscustomobject]@{ massMigrationTime = 3599 };    want = '172800'; say = 'refused' },
    @{ n = 'plane 172801 refused';             ready = $false; cm = $null;                                  ss = [pscustomobject]@{ massMigrationTime = 172801 };  want = '172800'; say = 'refused' },
    @{ n = 'plane fraction refused';           ready = $false; cm = $null;                                  ss = [pscustomobject]@{ massMigrationTime = 3600.5 };  want = '172800'; say = 'refused' },
    @{ n = 'plane text refused';               ready = $false; cm = $null;                                  ss = [pscustomobject]@{ massMigrationTime = 'soon' };  want = '172800'; say = 'refused' },
    @{ n = 'declared mass rung parks';         ready = $true;  cm = $rung;                                  ss = [pscustomobject]@{ massMigrationTime = 36000 };   want = '172800'; say = 'starts this run' },
    @{ n = 'declared rung, DLL not armed';     ready = $false; cm = $rung;                                  ss = $null;                                         want = '172800'; say = 'parked 48 h' },
    @{ n = 'mass_rung "false" does not park';  ready = $true;  cm = [pscustomobject]@{ version = '1.5.0'; mass_rung = 'false' }; ss = $null;                     want = '172800'; say = 'parked 48 h' },
    @{ n = 'old 1.3+ version alone no park';   ready = $true;  cm = [pscustomobject]@{ version = '1.3.2' }; ss = $null;                                         want = '172800'; say = 'parked 48 h' }
)
foreach ($c in $cases) {
    $gi = $TMPL
    Invoke-Expression $blockA
    Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
    $cbReady = $c.ready; $cm = $c.cm; $ss = $c.ss
    $out = Invoke-Expression $blockB 6>&1 | Out-String
    $after = Get-Content (Join-Path $cfgDir 'Game.ini') -Raw
    $has = (SessionBody $after) -match ('(?m)^MassMigrationTime=' + $c.want + '\r?$')
    Ok "$($c.n): T=$($c.want)" $has $out
    Ok "$($c.n): exactly one line" ((Count $after '(?mi)^MassMigrationTime=') -eq 1)
    Ok "$($c.n): D and patrol time kept" ($after -match '(?m)^MassMigrationDisableTime=2700\r?$' -and $after -match '(?m)^IndividualPatrolTime=300\r?$')
    Ok "$($c.n): the boot says why ($($c.say))" ($out -match [regex]::Escape($c.say)) $out
    Ok "$($c.n): never the 5 h value" ($after -notmatch '(?m)^MassMigrationTime=18000\r?$')
}

$gi = $TMPL.Replace('bEnablePatrolZones={{EnablePatrolZones}}', "bEnablePatrolZones={{EnablePatrolZones}}`nmassmigrationtime = 43200")
Invoke-Expression $blockA
Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
$cbReady = $false; $cm = $null; $ss = $null
$null = Invoke-Expression $blockB 6>&1 | Out-String
$after = Get-Content (Join-Path $cfgDir 'Game.ini') -Raw
Ok 'a hand-set MassMigrationTime is replaced, never doubled' ((Count $after '(?mi)^\s*MassMigrationTime\s*=') -eq 1 -and $after -notmatch '43200')

$gi = $TMPL.Replace('[/script/theisle.tigamesession]', '[/script/theisle.somethingelse]')
Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
$out = Invoke-Expression $blockB 6>&1 | Out-String
Ok 'no session section: said, not silent' ($out -match 'WARNING MassMigrationTime NOT set')
Remove-Item $cfgDir -Recurse -Force

Write-Host "the game's rule: T above 1.1 x D, or a mass never ends"
$T = [int]([regex]::Match($blockB, "\`$massT = '(\d+)'").Groups[1].Value)
$D = [int]([regex]::Match($blockA, "'MassMigrationDisableTime' '(\d+)'").Groups[1].Value)
$floor = [int]([regex]::Match($blockB, "-ge (\d+) -and \[int\]\`$pv -le").Groups[1].Value)
Ok "fleet T=$T > 1.1 x D=$D" ($T -gt 1.1 * $D)
Ok "the plane's floor $floor > 1.1 x D" ($floor -gt 1.1 * $D)

Write-Host "no mass open at a restart on any run length the fleet's schedules make (BUGS #3600)"
# A mass runs [kT, kT + 1.1 D] of uptime; a run of L hours ends 0-120 s short of L (boot time).
foreach ($Lh in @(4.5, 6, 7.5, 8, 11, 12, 13, 16, 24)) {
    $open = $false
    foreach ($short in @(0, 30, 60, 90, 120)) {
        $end = [int]($Lh * 3600) - $short
        for ($k = 1; $k * $T -le $end; $k++) { if ($end -le $k * $T + 1.1 * $D) { $open = $true } }
    }
    Ok "a $Lh h run ends with no mass open" (-not $open)
}

Write-Host ("{0} {1} passed, {2} failed" -f $(if ($fail) { 'FAIL' } else { 'PASS' }), $pass, $fail)
if ($fail) { exit 1 }
