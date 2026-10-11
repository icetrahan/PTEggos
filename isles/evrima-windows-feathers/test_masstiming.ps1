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
$blockB = Lift '$cbMassVer = 0' '# primal-loader: THE GAME LOADS'
$blockB = ($blockB -split "`n" | Select-Object -SkipLast 2) -join "`n"

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

Write-Host "B - MassMigrationTime only with a mass-rung DLL this boot"
$cfgDir = Join-Path $env:TEMP ('mt_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $cfgDir | Out-Null
$cases = @(
    @{ n = 'ready + 1.3.0';        ready = $true;  v = '1.3.0';      want = $true  },
    @{ n = 'ready + 1.3.0-lab';    ready = $true;  v = '1.3.0-lab';  want = $true  },
    @{ n = 'ready + 2.0.0';        ready = $true;  v = '2.0.0';      want = $true  },
    @{ n = 'ready + 1.10.0';       ready = $true;  v = '1.10.0';     want = $true  },
    @{ n = 'ready + 1.2.0';        ready = $true;  v = '1.2.0';      want = $false },
    @{ n = 'ready + no version';   ready = $true;  v = '';           want = $false },
    @{ n = 'not ready + 1.3.0';    ready = $false; v = '1.3.0';      want = $false },
    @{ n = 'commban off (no $cm)'; ready = $false; v = $null;        want = $false }
)
foreach ($c in $cases) {
    $gi = $TMPL
    Invoke-Expression $blockA
    Set-Content -Path (Join-Path $cfgDir 'Game.ini') -Value $gi -Encoding ascii
    $cbReady = $c.ready
    $cm = if ($null -eq $c.v) { $null } else { [pscustomobject]@{ version = $c.v } }
    $out = Invoke-Expression $blockB 6>&1 | Out-String
    $after = Get-Content (Join-Path $cfgDir 'Game.ini') -Raw
    $has = (SessionBody $after) -match '(?m)^MassMigrationTime=172800\r?$'
    Ok "$($c.n): parked=$($c.want)" ($has -eq $c.want) $out
    Ok "$($c.n): at most one line" ((Count $after '(?mi)^MassMigrationTime=') -le 1)
    Ok "$($c.n): D and patrol time kept" ($after -match '(?m)^MassMigrationDisableTime=2700\r?$' -and $after -match '(?m)^IndividualPatrolTime=300\r?$')
    Ok "$($c.n): the boot says which" ($out -match '\(config\) Game.ini: MassMigrationTime')
}
Remove-Item $cfgDir -Recurse -Force

Write-Host "the game's rule: T above 1.1 x D, or a mass never ends"
$T = [int]([regex]::Match($blockB, "'MassMigrationTime' '(\d+)'").Groups[1].Value)
$D = [int]([regex]::Match($blockA, "'MassMigrationDisableTime' '(\d+)'").Groups[1].Value)
Ok "T=$T > 1.1 x D=$D" ($T -gt 1.1 * $D)
Ok 'T above the longest restart gap (24 h)' ($T -gt 86400)

Write-Host ("{0} {1} passed, {2} failed" -f $(if ($fail) { 'FAIL' } else { 'PASS' }), $pass, $fail)
if ($fail) { exit 1 }
