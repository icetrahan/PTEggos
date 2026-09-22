# Behaviour test for A168 - the animated-skins pak knobs (AnimMaxAnimated / AnimWriteHz).
# Extracts the REAL pak-keys block out of the shipping wrapper (from `$modDefaults =`
# to `$pakForceDino = ''`) and executes it against boot-config fixtures, the same way
# test_carryforward.ps1 does - a copy-pasted reimplementation would pass while the
# shipped file was broken.
#   powershell -NoProfile -File isles/evrima-windows-feathers/test_animcap.ps1
$ErrorActionPreference = 'Stop'
$src   = Join-Path $PSScriptRoot 'start-evrima.ps1'
$lines = Get-Content $src
function LineOf([string]$needle) {
    $m = $lines | Select-String -SimpleMatch $needle | Select-Object -First 1
    if (-not $m) { throw "could not locate '$needle' in the real file" }
    return $m.LineNumber
}
$tb = LineOf 'function To-Bool('
$hs = LineOf 'function Has($o'
$helpers = (@($lines[($tb - 1)..($tb + 2)]) + @($lines[$hs - 1])) -join "`n"
$start = LineOf '$modDefaults = [ordered]@{'
$end   = LineOf "`$pakForceDino = ''"
$block = ($lines[($start-1)..($end-2)] -join "`n")
Write-Host "extracted real block: lines $start..$($end-1)`n"

$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  ok   $name" } else { $script:fail++; Write-Host "  FAIL $name  $detail" }
}
function Render($msJson) {
    $ms = $null
    if ($msJson) { $ms = $msJson | ConvertFrom-Json }
    $out = & ([scriptblock]::Create($helpers + "`n" + $block + "`n" + 'return $pakExtra')) 6>$null
    return $out
}

Write-Host 'A168 - defaults (no plane / first boot)'
$p = Render $null
Check 'no plane => AnimMaxAnimated=999 (no cap)' ($p['AnimMaxAnimated'] -eq '999') $p['AnimMaxAnimated']
Check 'no plane => AnimWriteHz=10 (half the pak default)' ($p['AnimWriteHz'] -eq '10') $p['AnimWriteHz']
Check 'the pre-A168 keys still render unchanged' ($p['AIMaxCount'] -eq '40' -and $p['BodyHoldSec'] -eq '10.0' -and $p['BodyHoldSet'] -eq 'True')

Write-Host 'A168 - the plane value wins'
$p = Render '{"animMaxAnimated":20,"animWriteHz":5}'
Check 'plane cap 20 renders 20' ($p['AnimMaxAnimated'] -eq '20') $p['AnimMaxAnimated']
Check 'plane 5 Hz renders 5' ($p['AnimWriteHz'] -eq '5') $p['AnimWriteHz']
$p = Render '{"animMaxAnimated":3}'
Check 'the acceptance fixture: cap 3 renders 3' ($p['AnimMaxAnimated'] -eq '3')

Write-Host 'A168 - out of band is SKIPPED to the default, never rendered (the pak reads Hz 0 as 20)'
foreach ($bad in @(0, 3, 21, 60)) {
    $p = Render ('{"animWriteHz":' + $bad + '}')
    Check "Hz $bad renders the default 10" ($p['AnimWriteHz'] -eq '10') $p['AnimWriteHz']
}
foreach ($bad in @(0, -5, 1000)) {
    $p = Render ('{"animMaxAnimated":' + $bad + '}')
    Check "cap $bad renders the default 999" ($p['AnimMaxAnimated'] -eq '999') $p['AnimMaxAnimated']
}

Write-Host 'A168 - owned keys are no longer carried forward (#1137)'
$cf = LineOf '$pakManaged = New-Object'
$cfBlock = ($lines[($cf-1)..($cf+2)] -join "`n")
$pakExtra = Render $null
$pakManaged = & ([scriptblock]::Create($cfBlock + "`n" + 'return ,$pakManaged'))
Check 'AnimMaxAnimated is managed (a stale hand-set 10 cannot survive)' ($pakManaged.Contains('AnimMaxAnimated'))
Check 'AnimWriteHz is managed' ($pakManaged.Contains('AnimWriteHz'))

Write-Host "`n$pass passed, $fail failed"
if ($fail) { exit 1 }
