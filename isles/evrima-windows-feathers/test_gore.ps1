# Behaviour test for the gore section start-evrima.ps1 writes into Game.ini from the panel's switches (A1173):
#   server_settings.enableBiteGore / enableDismemberment / spawnLooseChunks
#   -> [/Script/TheIsle.TIRuntimeGoreSettings] bEnableRuntimeBiteGore / bEnableDismemberment / bSpawnLooseChunks
# Runs the REAL lines lifted from the shipping wrapper, never a copy of them.
#   powershell -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_gore.ps1
param([string]$Wrapper = (Join-Path $PSScriptRoot 'start-evrima.ps1'))
$ErrorActionPreference = 'Stop'
$lines = Get-Content $Wrapper

function Lift([string]$from, [string]$to) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { throw "anchor not found: $from" }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { throw "end anchor not found: $to" }
    return ($lines[($a-1)..($a+$b-2)] -join "`n")
}
$block = Lift '# Gore (A1173)' '# --- AI LEARNING (#1099)'

function Has($o, [string]$n) { return ($null -ne $o) -and ($null -ne $o.PSObject.Properties[$n]) }
function PsBool($v) { if ($v) { return 'True' } else { return 'False' } }
$GTMPL = Get-Content (Join-Path $PSScriptRoot 'Game.ini.tmpl') -Raw
$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}
function Count([string]$text, [string]$pattern) { return ([regex]::Matches($text, $pattern)).Count }
$HDR = '\[/Script/TheIsle\.TIRuntimeGoreSettings\]'
function Section([string]$ini) {
    return [regex]::Match($ini, "(?ms)^$HDR[^\n]*\n(.*?)(?=^\[|\z)").Groups[1].Value
}

function Run($ss, [string]$tmpl = $GTMPL) {
    $script:ss = $ss; $script:gi = $tmpl
    $ss = $script:ss; $gi = $script:gi
    $out = Invoke-Expression $block 6>&1 | Out-String
    return @{ gi = $gi; out = $out }
}

$K = @('bEnableRuntimeBiteGore', 'bEnableDismemberment', 'bSpawnLooseChunks')
$F = @('enableBiteGore', 'enableDismemberment', 'spawnLooseChunks')

Write-Host "1 - all off (the game's default): no gore section, the template untouched"
foreach ($c in @(
    @{ n = 'no plane config'; ss = $null },
    @{ n = 'block without the keys'; ss = [pscustomobject]@{ serverName = 'x' } },
    @{ n = 'all three false'; ss = [pscustomobject]@{ enableBiteGore = $false; enableDismemberment = $false; spawnLooseChunks = $false } },
    @{ n = 'strings "true" are not on'; ss = [pscustomobject]@{ enableBiteGore = 'true'; enableDismemberment = 'True'; spawnLooseChunks = '1' } },
    @{ n = 'numbers are not on'; ss = [pscustomobject]@{ enableBiteGore = 1; enableDismemberment = 1; spawnLooseChunks = 1 } }
)) {
    $r = Run $c.ss
    Ok "$($c.n): no gore section" ((Count $r.gi "(?mi)^$HDR") -eq 0) $r.out
    Ok "$($c.n): template unchanged" ($r.gi -eq $GTMPL)
    Ok "$($c.n): the boot says gore off" ($r.out -match '\(config\) Game.ini: gore off')
}

Write-Host "2 - each switch alone, then all three"
$cases = @()
for ($i = 0; $i -lt 3; $i++) { $cases += , @($i) }
$cases += , @(0, 1, 2)
foreach ($on in $cases) {
    $h = [ordered]@{}; for ($j = 0; $j -lt 3; $j++) { $h[$F[$j]] = ($on -contains $j) }
    $r = Run ([pscustomobject]$h)
    $body = Section $r.gi
    $name = ($on | ForEach-Object { $F[$_] }) -join '+'
    Ok "${name}: exactly one gore section" ((Count $r.gi "(?mi)^$HDR") -eq 1) $r.out
    for ($j = 0; $j -lt 3; $j++) {
        $want = if ($on -contains $j) { 'True' } else { 'False' }
        Ok "${name}: $($K[$j])=$want" ($body -match "(?m)^$($K[$j])=$want\r?$") $body
        Ok "${name}: $($K[$j]) once" ((Count $r.gi "(?mi)^\s*$($K[$j])\s*=") -eq 1)
    }
    Ok "${name}: the template is kept whole before it" ($r.gi.StartsWith($GTMPL.TrimEnd("`r", "`n")))
    Ok "${name}: the session section is untouched" ($r.gi -match '(?mi)^\[/script/theisle\.tigamesession\]')
    Ok "${name}: the boot names what is on" ($r.out -match "\(config\) Game.ini: gore on: .*$($K[$on[0]])")
}

Write-Host "3 - a stale gore section in the template is replaced, never doubled; turned off it is removed"
$stale = $GTMPL.TrimEnd("`r", "`n") + "`r`n`r`n[/Script/TheIsle.TIRuntimeGoreSettings]`r`nbEnableRuntimeBiteGore=True`r`nbEnableDismemberment=True`r`nbSpawnLooseChunks=True`r`n"
$r = Run ([pscustomobject]@{ enableBiteGore = $false; enableDismemberment = $true; spawnLooseChunks = $false }) $stale
Ok "stale + dismemberment only: one section" ((Count $r.gi "(?mi)^$HDR") -eq 1) $r.gi
Ok "stale + dismemberment only: bite gore now False" ((Section $r.gi) -match '(?m)^bEnableRuntimeBiteGore=False\r?$')
$r = Run ([pscustomobject]@{ enableBiteGore = $false; enableDismemberment = $false; spawnLooseChunks = $false }) $stale
Ok "stale + all off: section removed" ((Count $r.gi "(?mi)^$HDR") -eq 0) $r.gi
Ok "stale + all off: no orphan gore key left" ((Count $r.gi '(?mi)^\s*b(EnableRuntimeBiteGore|EnableDismemberment|SpawnLooseChunks)\s*=') -eq 0)
$cut = $GTMPL.IndexOf('[/script/theisle.tigamesession]')
$mid = $GTMPL.Substring(0, $cut) + "[/Script/TheIsle.TIRuntimeGoreSettings]`nbEnableRuntimeBiteGore=True`n" + $GTMPL.Substring($cut)
$r = Run ([pscustomobject]@{ enableBiteGore = $false }) $mid
Ok "a gore section before the session section: removed, the rest kept" (($r.gi -eq $GTMPL) -and ((Count $r.gi "(?mi)^$HDR") -eq 0)) $r.gi.Substring(0, [Math]::Min(200, $r.gi.Length))

Write-Host ""
Write-Host "gore: $pass passed, $fail failed"
if ($fail) { exit 1 }
