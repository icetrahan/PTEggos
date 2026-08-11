# Behaviour test for the #1137 carry-forward block.
# ⭐ It extracts the REAL lines out of the shipping wrapper and executes those -
# a copy-pasted reimplementation would pass while the shipped file was broken.
$ErrorActionPreference = 'Stop'
$src   = Join-Path $PSScriptRoot 'start-evrima.ps1'
$lines = Get-Content $src

$start = ($lines | Select-String -SimpleMatch '$pakManaged = New-Object' | Select-Object -First 1).LineNumber
$end   = ($lines | Select-String -SimpleMatch 'if ($env:ENABLE_PRIMAL_MOD -eq ''1'' -and $phsk)' | Select-Object -First 1).LineNumber
if (-not $start -or -not $end) { throw 'could not locate the block in the real file' }
$block = ($lines[($start-1)..($end-2)] -join "`n")
Write-Host "extracted real block: lines $start..$($end-1) ($(($block -split "`n").Count) lines)`n"

$tmp = Join-Path $env:TEMP ('cf_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp | Out-Null

# A real boot's pakExtra, with SpeciesCapList CLEARED (omitted) on purpose.
function Get-PakExtra {
    [ordered]@{
        BodySweepOn='True'; BodySweepList='Triceratops'; BodyHoldSec='10.0'; BodyHoldSet='True'
        BodySweepLiftZ='150000'; BSLiftSet='True'; TreeKnockdownOn='False'; AIMaxCount='40'
        SpeciesCapEvery='30'
    }
}

# The pak section as it actually exists on fdff8b30 right now (token redacted).
$LIVE = @'
[SystemSettings]
PlayersRate=3

[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]
SpeciesCapEvery=20
SpeciesCapList=Stegosaurus:1,Dryosaurus:2
TreeKnockdownOn=True
ApiToken=phsk_REDACTED_FIXTURE_VALUE
PollURL=https://data.primalhosted.com/v1/commands/text
BodySweepOn=True
BodySweepList=Triceratops
BodyHoldSec=10.0
ForceDinoList=Oviraptor,Baryonyx
AIMaxCount=40

PrimalModLogging=Verbose
[Core.Log]
LogConsoleManager=off
IrisCensusOn=True
'@

$cases = @(
  @{ n='1 live fdff8b30 section (#1071 behaviour preserved)'; ini=$LIVE; want=@('PrimalModLogging') }
  @{ n='2 #1137: four new pak keys survive (file order)'; want=@('IrisCensusOn','IrisCensusEvery','IrisCensusDelay','IrisCensusCmds','PrimalModLogging')
     ini=$LIVE -replace '(?m)^PrimalModLogging=Verbose$', "IrisCensusOn=True`nIrisCensusEvery=600.0`nIrisCensusDelay=600.0`nIrisCensusCmds=replicated`nPrimalModLogging=Verbose" }
  @{ n='3 no leakage from [Core.Log] (IrisCensusOn there is NOT ours)'; ini=$LIVE; want=@('PrimalModLogging') }
  @{ n='4 CLEARED SpeciesCapList is not resurrected (un-clearable trap)'; ini=$LIVE; want=@('PrimalModLogging') }
  @{ n='5 no live Engine.ini at all (first boot)'; ini=$null; want=@() }
  @{ n='6 no pak section in the live file'; ini="[Core.Log]`nLogInit=off`n"; want=@() }
  @{ n='7 duplicate key: UE takes the FIRST copy'; want=@('Dup')
     ini="[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]`nDup=first`nDup=second`n" }
  @{ n='8 comments and blanks ignored'; want=@('Real')
     ini="[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]`n; Note=x`n# Other=y`n`nReal=1`n" }
  @{ n='9 section runs to EOF (no following section)'; want=@('Tail')
     ini="[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]`nApiToken=phsk_x`nTail=9`n" }
  @{ n='10 case-insensitive: apitoken is still OURS, not carried'; want=@()
     ini="[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]`napitoken=phsk_x`nBODYSWEEPON=False`n" }
)

$fail = 0
foreach ($c in $cases) {
    $cfgDir = $tmp
    $p = Join-Path $tmp 'Engine.ini'
    if ($null -eq $c.ini) { Remove-Item $p -ErrorAction SilentlyContinue }
    else { [IO.File]::WriteAllText($p, $c.ini) }

    $pakExtra = Get-PakExtra
    $carried  = $null
    Invoke-Expression $block

    $got = @($carried.Keys)
    $ok  = (($got -join ',') -eq (@($c.want) -join ','))
    if (-not $ok) { $fail++ }
    '{0}  {1}' -f $(if($ok){'PASS'}else{'FAIL'}), $c.n
    if (-not $ok) { "      want: [$(@($c.want) -join ', ')]`n      got:  [$($got -join ', ')]" }
}

# Value fidelity, not just key names.
$cfgDir = $tmp
[IO.File]::WriteAllText((Join-Path $tmp 'Engine.ini'),
  "[/Game/TheIsle/Core/Session/BP_TIGameSession.BP_TIGameSession_C]`nIrisCensusCmds=replicated,alwaysrelevant`n  Spaced = 7  `n")
$pakExtra = Get-PakExtra; $carried = $null
Invoke-Expression $block
$vok = ($carried['IrisCensusCmds'] -eq 'replicated,alwaysrelevant') -and ($carried['Spaced'] -eq '7')
if (-not $vok) { $fail++ }
'{0}  11 values preserved verbatim + whitespace trimmed (cmds={1} spaced={2})' -f $(if($vok){'PASS'}else{'FAIL'}), $carried['IrisCensusCmds'], $carried['Spaced']

Remove-Item $tmp -Recurse -Force
"`n$(if($fail -eq 0){'ALL GREEN'}else{"$fail FAILED"})"
if ($fail) { exit 1 }
