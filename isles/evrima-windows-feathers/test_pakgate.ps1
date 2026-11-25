# Behaviour test for the pak gate in start-evrima.ps1: the pak mounts only on a game build its manifest
# lists in `gameBuilds`; anything else moves the triplet to _primal\pak-held, removes the bypass and
# tells the plane. Runs the REAL lines lifted from the shipping wrapper against fake manifests and installs.
#   powershell -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_pakgate.ps1 [wrapper]
param([string]$Wrapper = (Join-Path $PSScriptRoot 'start-evrima.ps1'))
$ErrorActionPreference = 'Stop'
$lines = Get-Content $Wrapper

# From the line holding $from up to, NOT including, the first later line that STARTS with $to.
function Lift([string]$from, [string]$to) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { Write-Host "FAIL anchor not found: $from"; exit 1 }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -Pattern ('^' + [regex]::Escape($to)) | Select-Object -First 1).LineNumber
    if (-not $b) { Write-Host "FAIL end anchor not found: $to"; exit 1 }
    return ($lines[($a-1)..($a+$b-3)] -join "`n")
}
$gate = Lift '# PAK GATE: the pak mounts only on a game build it is proven on.' 'if ($pakGate.open) {'
$readBid = Lift 'function Read-ManifestBuildId([string]$path) {' '# force | new-build = clean pull'
function EnvOr([string]$v, [string]$fb) { if ([string]::IsNullOrWhiteSpace($v)) { return $fb } else { return $v } }
. ([scriptblock]::Create($readBid))

# The manifest GET answers $script:fakeManifest ($null = unreachable); boot reports are recorded.
function Invoke-RestMethod { param([string]$Uri, [int]$TimeoutSec) if ($null -eq $script:fakeManifest) { throw 'unreachable' }; return ($script:fakeManifest | ConvertFrom-Json) }
function Start-BootReport([string]$label, [hashtable]$body, [string]$clearMark) { $script:reports += , @{ label = $label; body = $body; clear = $clearMark } }
function New-TestManifest([string]$ver, [string]$builds, [string]$sha = 'x') {
    $gb = if ($builds) { ",`"gameBuilds`":$builds" } else { '' }
    return "{`"version`":`"$ver`",`"build`":`"BUILD $ver`"$gb,`"files`":[{`"name`":`"pakchunk50-Windows_P.ucas`",`"url`":`"u`",`"sha256`":`"$sha`",`"size`":1}]}"
}
# The sha256 of a file Set-Content writes with $text, the way Run-Case writes a held triplet.
function Sha-Of([string]$text) {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $f = Join-Path $work 'sha.tmp'; Set-Content $f $text
    return (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("pakgate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') { if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "  FAIL $label $detail" } }

function Run-Case([string]$installed, $manifest, [string]$modOn, [hashtable]$opt = @{}) {
    $r = Join-Path $work ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $script:root = $r; $script:game = Join-Path $r 'server'; $script:tmpl = Join-Path $r '_primal'
    $script:paksDir = Join-Path $game 'TheIsle\Content\Paks'; $script:binDirWin = Join-Path $game 'TheIsle\Binaries\Win64'
    $script:pakVerFile = Join-Path $tmpl 'primal-pak.version'; $script:sbVerFile = Join-Path $tmpl 'primal-sigbypass.version'
    New-Item -ItemType Directory -Force -Path $paksDir, $binDirWin, $tmpl, (Join-Path $game 'steamapps') | Out-Null
    foreach ($e in 'pak', 'ucas', 'utoc') { Set-Content (Join-Path $paksDir "pakchunk50-Windows_P.$e") 'old' }
    Set-Content (Join-Path $binDirWin 'UniversalSigBypasser.asi') 'asi'; Set-Content (Join-Path $binDirWin 'dsound.dll') 'loader'
    Set-Content $pakVerFile '193'; Set-Content $sbVerFile '1.2'
    if ($installed) { Set-Content (Join-Path $game 'steamapps\appmanifest_412680.acf') "`"AppState`" { `"buildid`"  `"$installed`" }" }
    if ($opt.kept) { Set-Content (Join-Path $tmpl 'primal-pak.gamebuilds') $opt.kept }
    if ($opt.mark) { Set-Content (Join-Path $tmpl 'primal-pakgate.pending') 'pak_game_build_unproven' }
    if ($opt.held) { New-Item -ItemType Directory -Force -Path (Join-Path $tmpl 'pak-held') | Out-Null; Set-Content (Join-Path $tmpl 'pak-held\pakchunk50-Windows_P.ucas') $opt.held }
    $script:fakeManifest = $manifest; $env:ENABLE_PRIMAL_MOD = $modOn; $env:PRIMAL_MOD_MANIFEST = ''
    $script:reports = @()
    $script:out = (& { . ([scriptblock]::Create($gate)); "GATE=$($pakGate.open) $($pakGate.code)" } *>&1 | Out-String)
}
function Mounted { (Test-Path (Join-Path $paksDir 'pakchunk50-Windows_P.ucas')) -and (Test-Path (Join-Path $binDirWin 'UniversalSigBypasser.asi')) }
function Held {
    (Test-Path (Join-Path $tmpl 'pak-held\pakchunk50-Windows_P.ucas')) -and
    -not @(Get-ChildItem $paksDir -Filter 'pakchunk50-Windows_P.*').Count -and
    -not (Test-Path (Join-Path $binDirWin 'UniversalSigBypasser.asi')) -and
    (Test-Path (Join-Path $binDirWin 'dsound.dll')) -and -not (Test-Path $pakVerFile)
}

try {
    Run-Case '26883482' (New-TestManifest '194' '["24664709","26883482"]') '1'
    Ok 'proven build keeps the pak and the bypass' (Mounted)
    Ok 'proven build reads open/proven' ($out -match 'GATE=True proven') $out
    Ok 'a proven boot with no pending mark reports nothing' ($reports.Count -eq 0)

    Run-Case '26883482' (New-TestManifest '193' '["24664709"]') '1'
    Ok 'unproven build holds the pak and removes the bypass, keeps dsound.dll' (Held)
    Ok 'unproven boot says so in the log' ($out -match [regex]::Escape('(pak-gate) game build 26883482, pak 193 from the manifest -> VANILLA (pak_game_build_unproven)')) $out
    $b = if ($reports.Count) { $reports[0].body } else { @{} }
    Ok 'unproven boot is reported to the plane, distinguishably' ($reports.Count -eq 1 -and $b.ok -eq $false -and $b.skipped -eq 'pak_game_build_unproven' -and $b.gameBuild -eq '26883482' -and $b.dll -eq 'pakchunk50')
    Ok 'unproven boot leaves the mark the reopening boot clears' (Test-Path (Join-Path $tmpl 'primal-pakgate.pending'))

    Run-Case '26883482' (New-TestManifest '193' '') '1'
    Ok 'a manifest with no gameBuilds holds the pak (fail closed)' (Held)
    Ok 'no list reads pak_proof_missing' ($out -match 'GATE=False pak_proof_missing') $out

    Run-Case '26883482' (New-TestManifest '193' '[]') '1'
    Ok 'an empty gameBuilds holds the pak' (Held)

    Run-Case '26883482' (New-TestManifest 'lab' '["*"]') '1'
    Ok 'a lab manifest ["*"] mounts on any build' (Mounted)
    Ok 'lab manifest reads any_build' ($out -match 'GATE=True any_build') $out

    Run-Case '' (New-TestManifest '194' '["26883482"]') '1'
    Ok 'an unreadable installed build holds the pak' (Held)
    Ok 'no appmanifest reads game_build_unknown' ($out -match 'GATE=False game_build_unknown') $out

    Run-Case '26883482' $null '1' @{ kept = '{"version":"193","gameBuilds":["26883482"]}' }
    Ok 'manifest unreachable: the list kept with the same pak decides (open)' (Mounted)
    Ok 'the kept list is named in the log' ($out -match 'from the list kept with pak 193') $out

    Run-Case '26883482' $null '1' @{ kept = '{"version":"190","gameBuilds":["26883482"]}' }
    Ok 'manifest unreachable: a kept list for ANOTHER pak version does not open the gate' (Held)

    Run-Case '26883482' $null '1'
    Ok 'manifest unreachable and nothing kept: held' (Held)

    Run-Case '26883482' (New-TestManifest '194' '["26883482"]') '0'
    Ok 'ENABLE_PRIMAL_MOD=0 takes a pak and bypass left on disk off too' (Held)
    Ok 'mod off is reported as mod_off, so the plane does not restart it to bring the pak back' (@($reports | Where-Object { $_.body.skipped -eq 'mod_off' -and -not $_.body.ok }).Count -eq 1)
    Ok 'mod off prints no vanilla banner' ($out -notmatch 'BOOTING VANILLA')

    Run-Case '26883482' (New-TestManifest '194' '["26883482"]') '1' @{ mark = $true }
    Ok 'a proven pak mounts again after a held boot' (Mounted)
    Ok 'the reopening boot tells the plane, clearing the mark once recorded' ($reports.Count -eq 1 -and $reports[0].body.ok -eq $true -and $reports[0].clear -like '*primal-pakgate.pending')

    Run-Case '26883482' (New-TestManifest '193' '["2688348"]') '1'
    Ok 'a listed prefix of the build is not the build' (Held)

    $heldDir = { Join-Path $tmpl 'pak-held' }
    Run-Case '26883482' (New-TestManifest '194' '["26883482"]') '1' @{ held = 'pak 193 bytes' }
    Ok 'an open gate clears a held triplet of another pak' (-not (Test-Path (& $heldDir))) $out
    Ok 'the clearing is in the log, naming the manifest pak' ($out -match [regex]::Escape('(pak-gate) cleared _primal\pak-held: it held another pak than 194')) $out
    Ok 'clearing pak-held leaves the mounted pak alone' (Mounted)

    Run-Case '26883482' (New-TestManifest '194' '["26883482"]' (Sha-Of 'pak 194 bytes')) '1' @{ held = 'pak 194 bytes' }
    Ok 'an open gate keeps a held triplet that is the manifest''s own pak' (Test-Path (Join-Path (& $heldDir) 'pakchunk50-Windows_P.ucas')) $out
    Ok 'a kept pak-held is not reported as cleared' ($out -notmatch 'cleared _primal') $out

    Run-Case '26883482' $null '1' @{ kept = '{"version":"193","gameBuilds":["26883482"]}'; held = 'pak 190 bytes' }
    Ok 'manifest unreachable: pak-held is left as it is (nothing to compare with)' (Test-Path (Join-Path (& $heldDir) 'pakchunk50-Windows_P.ucas')) $out

    Run-Case '26883482' (New-TestManifest '193' '["24664709"]') '1' @{ held = 'pak 190 bytes' }
    Ok 'a held boot over an older pak-held still holds (the triplet is moved over it)' (Held)
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    $env:ENABLE_PRIMAL_MOD = $null; $env:PRIMAL_MOD_MANIFEST = $null
}
Write-Host "pak gate (windows): $pass passed, $fail failed"
if ($fail) { exit 1 }
