# Behaviour test for the hand-set pak key carry-forward (#1137, #3363).
# It lifts the REAL lines out of the shipping wrapper and executes those - a
# re-implementation here would pass while the shipped file was broken.
#   powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_carryforward.ps1
$ErrorActionPreference = 'Stop'
$src   = Join-Path $PSScriptRoot 'start-evrima.ps1'
$lines = Get-Content $src

function Lift([string]$from, [string]$to, [int]$toOffset) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    $b = ($lines | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $a -or -not $b -or $b -lt $a) { throw "could not locate '$from' .. '$to' in the real file" }
    return ($lines[($a - 1)..($b - 1 + $toOffset)] -join "`n")
}
# The boot-time block (functions + the read), and the render-time save inside the mod block.
$bootBlock   = Lift '$pakManaged = New-Object' 'if ($env:ENABLE_PRIMAL_MOD -eq ''1'' -and $phsk)' -1
$renderBlock = Lift 'Write-Host $carryNote' '$script:carryArmed = $true' 0
Write-Host "lifted: boot block $(($bootBlock -split "`n").Count) lines, render block $(($renderBlock -split "`n").Count) lines`n"

$SEC = '[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]'
function Get-PakExtra {
    [ordered]@{
        BodySweepOn='True'; BodySweepList='Triceratops'; BodyHoldSec='10.0'; BodyHoldSet='True'
        BodySweepLiftZ='150000'; BSLiftSet='True'; TreeKnockdownOn='False'; AIMaxCount='40'
        SpeciesCapEvery='30'; AnimMaxAnimated='999'; AnimWriteHz='10'
    }
}

# A pak section shaped like a live one (token redacted), SpeciesCapList CLEARED in the panel.
$LIVE = @"
[SystemSettings]
PlayersRate=3

$SEC
SpeciesCapEvery=20
SpeciesCapList=Stegosaurus:1,Dryosaurus:2
TreeKnockdownOn=True
ApiToken=phsk_REDACTED_FIXTURE_VALUE
PollURL=https://data.primalhosted.com/v1/commands/text
BodySweepOn=True
ForceDinoList=Oviraptor,Baryonyx
AIMaxCount=40

PrimalModLogging=Verbose
[Core.Log]
LogConsoleManager=off
IrisCensusOn=True
"@

$root = Join-Path $env:TEMP ('cf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$fail = 0
function Check([bool]$ok, [string]$name, [string]$detail) {
    if (-not $ok) { $script:fail++ }
    '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name
    if (-not $ok -and $detail) { "      $detail" }
}

# One "volume": its own config dir and its own _primal, like a server.
function New-Volume {
    $v = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $v 'cfg'), (Join-Path $v '_primal') | Out-Null
    return $v
}
function Set-Live($v, $text) {
    $p = Join-Path $v 'cfg\Engine.ini'
    if ($null -eq $text) { Remove-Item $p -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText($p, $text) }
}
# A boot on volume $v: the real boot block, then (mod on) the real render-time save.
# ALWAYS dot-source it (`. Invoke-Boot ...`) so the lifted functions and variables land
# in this script's scope, where the wrapper's own supervise loop finds them.
function Invoke-Boot($v, [switch]$Render) {
    $cfgDir = Join-Path $v 'cfg'
    $tmpl = Join-Path $v '_primal'
    $pakExtra = Get-PakExtra
    $carried = $null; $carryNote = $null; $carryArmed = $false
    . ([scriptblock]::Create($bootBlock))
    if ($Render) { . ([scriptblock]::Create($renderBlock)) 6>$null }
}
# What the wrapper's rendered Engine.ini holds for this boot's carried keys.
function Rendered($keys) {
    $kv = @($keys.Keys | ForEach-Object { "$_=$($keys[$_])" })
    return (@('[Core.Log]', 'LogInit=off', '', $SEC, 'ApiToken=phsk_REDACTED_FIXTURE_VALUE', 'AIMaxCount=40') + $kv) -join "`n"
}
function KeysOf($m) { if ($null -eq $m) { return '<null>' } return (@($m.Keys) -join ',') }

# --- the live-file cases (the #1137 behaviour, unchanged) ---------------------------
$cases = @(
  @{ n='1 live section: owned keys never carried, PrimalModLogging carried'; ini=$LIVE; want='PrimalModLogging' }
  @{ n='2 #1137: four new pak keys survive, file order'; want='IrisCensusOn,IrisCensusEvery,IrisCensusDelay,IrisCensusCmds,PrimalModLogging'
     ini=$LIVE -replace '(?m)^PrimalModLogging=Verbose$', "IrisCensusOn=True`nIrisCensusEvery=600.0`nIrisCensusDelay=600.0`nIrisCensusCmds=replicated`nPrimalModLogging=Verbose" }
  @{ n='3 no leakage from [Core.Log] (IrisCensusOn there is not ours)'; ini=$LIVE; want='PrimalModLogging' }
  @{ n='4 a CLEARED SpeciesCapList is not resurrected'; ini=$LIVE; want='PrimalModLogging' }
  @{ n='5 duplicate key: UE takes the FIRST copy'; want='Dup'; ini="$SEC`nDup=first`nDup=second`n" }
  @{ n='6 comments and blanks ignored'; want='Real'; ini="$SEC`n; Note=x`n# Other=y`n`nReal=1`n" }
  @{ n='7 section runs to EOF'; want='Tail'; ini="$SEC`nApiToken=phsk_x`nTail=9`n" }
  @{ n='8 case-insensitive: apitoken is still owned'; want=''; ini="$SEC`napitoken=phsk_x`nBODYSWEEPON=False`n" }
)
foreach ($c in $cases) {
    $v = New-Volume; Set-Live $v $c.ini
    . Invoke-Boot $v
    Check ((KeysOf $carried) -eq $c.want) $c.n "want [$($c.want)] got [$(KeysOf $carried)]"
}
$v = New-Volume; Set-Live $v "$SEC`nIrisCensusCmds=replicated,alwaysrelevant`n  Spaced = 7  `n"
. Invoke-Boot $v
Check (($carried['IrisCensusCmds'] -eq 'replicated,alwaysrelevant') -and ($carried['Spaced'] -eq '7')) '9 values verbatim, whitespace trimmed' "cmds=$($carried['IrisCensusCmds']) spaced=$($carried['Spaced'])"

# --- #3363: the live file is gone or has no section ----------------------------------
$v = New-Volume; Set-Live $v $null
. Invoke-Boot $v
Check ((KeysOf $carried) -eq '' -and $carryNote -like '*MISSING at boot*no _primal/engine-carry.ini*') '10 first boot: no live file, no copy - empty, and SAID' $carryNote

$v = New-Volume; Set-Live $v "$SEC`nIrisCensusEvery=77`nWireVersion=2`n"
. Invoke-Boot $v -Render
Set-Live $v $null
. Invoke-Boot $v
Check ((KeysOf $carried) -eq 'IrisCensusEvery,WireVersion' -and $carried['IrisCensusEvery'] -eq '77' -and $carryNote -like '*MISSING at boot*from _primal/engine-carry.ini*: IrisCensusEvery, WireVersion') '11 live deleted by a clean exit: keys + values come from the copy, and SAID' "$(KeysOf $carried) | $carryNote"

$v = New-Volume; Set-Live $v "$SEC`nWireVersion=2`n"
. Invoke-Boot $v -Render
Set-Live $v "[Core.Log]`nLogInit=off`n"
. Invoke-Boot $v
Check ((KeysOf $carried) -eq 'WireVersion' -and $carryNote -like '*has no pak section*from _primal/engine-carry.ini*') '12 live file without the pak section (a mod-off boot): keys from the copy' "$(KeysOf $carried) | $carryNote"

$v = New-Volume; Set-Live $v "$SEC`nWireVersion=2`nCmdBudget=25`n"
. Invoke-Boot $v -Render
Set-Live $v "$SEC`nApiToken=phsk_x`n"
. Invoke-Boot $v
Check ((KeysOf $carried) -eq '' -and $carryNote -like '*no hand-set pak keys present*') '13 an operator CLEARED every key in the live file: the copy does not resurrect them' "$(KeysOf $carried) | $carryNote"

# --- the copy itself ----------------------------------------------------------------
$v = New-Volume; Set-Live $v $LIVE
. Invoke-Boot $v -Render
$copy = [IO.File]::ReadAllText((Join-Path $v '_primal\engine-carry.ini'))
Check (($copy -notmatch '(?im)^\s*(ApiToken|PollURL|ForceDinoList|SpeciesCapList|AIMaxCount)\s*=') -and $copy -match '(?m)^PrimalModLogging=Verbose$') '14 the copy never holds an owned key (no ApiToken)' $copy

$v = New-Volume; Set-Live $v "$SEC`nApiToken=phsk_x`n"
. Invoke-Boot $v -Render
Set-Live $v $null
. Invoke-Boot $v
Check ($null -ne $carried -and (KeysOf $carried) -eq '' -and $carryNote -like '*carried forward 0 hand-set pak key(s) from _primal/engine-carry.ini*: none') '15 a header-only copy reads back as "none hand-set", never as "no copy"' $carryNote

# --- the supervise loop: an edit made while the server runs -------------------------
$v = New-Volume; Set-Live $v "$SEC`nWireVersion=2`n"
. Invoke-Boot $v -Render
$carryFile = Join-Path $v '_primal\engine-carry.ini'
$before = [IO.File]::ReadAllText($carryFile)
$script:carryArmed = $false
Set-Live $v "$SEC`nWireVersion=2`nTestKit=True`n"
(Get-Item (Join-Path $v 'cfg\Engine.ini')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(5)
Sync-PakCarry 6>$null
Check ([IO.File]::ReadAllText($carryFile) -eq $before) '16 the loop writes nothing before the render armed it'
$script:carryArmed = $true
Sync-PakCarry 6>$null
Check ([IO.File]::ReadAllText($carryFile) -match '(?m)^TestKit=True$') '17 an edit made while running is saved the moment the file changes' ([IO.File]::ReadAllText($carryFile))
Set-Live $v $null
Sync-PakCarry 6>$null
Check ([IO.File]::ReadAllText($carryFile) -match '(?m)^TestKit=True$') '18 the live file vanishing (clean exit) leaves the copy alone'
. Invoke-Boot $v
Check ((KeysOf $carried) -eq 'WireVersion,TestKit') '19 ...and the next boot carries the edit made mid-run' (KeysOf $carried)

# --- the whole lifecycle on one volume ----------------------------------------------
$v = New-Volume; Set-Live $v "$SEC`nApiToken=phsk_x`nIrisCensusEvery=77`nCmdBudget=25`n"
$ok = $true; $trail = @()
. Invoke-Boot $v -Render; $trail += "boot1=$(KeysOf $carried)"; Set-Live $v (Rendered $carried)
Set-Live $v $null                                           # clean exit
. Invoke-Boot $v -Render; $trail += "afterCleanExit=$(KeysOf $carried)"; Set-Live $v (Rendered $carried)
$ok = $ok -and ((KeysOf $carried) -eq 'IrisCensusEvery,CmdBudget')
                                                            # crash / hard kill: the file stays
. Invoke-Boot $v -Render; $trail += "afterCrash=$(KeysOf $carried)"; Set-Live $v (Rendered $carried)
$ok = $ok -and ((KeysOf $carried) -eq 'IrisCensusEvery,CmdBudget') -and $carryNote -like '*carried forward 2 hand-set pak key(s) (#1137/#1071)*'
Set-Live $v $null                                           # two clean exits in a row
. Invoke-Boot $v -Render; Set-Live $v (Rendered $carried)
Set-Live $v $null
. Invoke-Boot $v -Render; $trail += "afterTwoCleanExits=$(KeysOf $carried)"
$ok = $ok -and ((KeysOf $carried) -eq 'IrisCensusEvery,CmdBudget') -and $carried['IrisCensusEvery'] -eq '77'
Check $ok '20 lifecycle: clean exit, crash, two clean exits - every key and value survives' ($trail -join ' ; ')

Remove-Item $root -Recurse -Force
"`n$(if ($fail -eq 0) { 'ALL GREEN' } else { "$fail FAILED" })"
if ($fail) { exit 1 }
