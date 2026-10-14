# Behaviour test for the clean-pull update block in start-evrima.ps1 (BACKLOG A702).
# Runs the REAL lines lifted from the shipping wrapper against a fake steamcmd that reproduces the
# stale-appmanifest bug: with steamapps present it trusts its manifest and does not move the build.
#   powershell -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_cleanupdate.ps1
$ErrorActionPreference = 'Stop'
$lines = Get-Content (Join-Path $PSScriptRoot 'start-evrima.ps1')

# From the line holding $from up to, NOT including, the line holding $to.
function Lift([string]$from, [string]$to) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { throw "anchor not found: $from" }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { throw "end anchor not found: $to" }
    return ($lines[($a-1)..($a+$b-3)] -join "`n")
}
$block = Lift '# 1b) Update (skippable via AUTO_UPDATE=0)' 'Dbg "update phase done"'
function EnvOr([string]$v, [string]$fb) { if ([string]::IsNullOrWhiteSpace($v)) { return $fb } else { return $v } }

$work = Join-Path ([IO.Path]::GetTempPath()) ("a702-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fake = Join-Path $work 'steamcmd.ps1'
@'
$log = Join-Path $env:FAKE_DIR 'calls.log'
if ($args -contains '+app_info_print') {
    Add-Content $log 'info'
    if ($env:FAKE_LATEST) {
        "AppID : 412680, change number : 1/1, last change : now"
        "`"412680`"`n{`n`t`"depots`"`n`t{`n`t`t`"branches`"`n`t`t{`n`t`t`t`"public`"`n`t`t`t{`n`t`t`t`t`"buildid`"`t`t`"555`"`n`t`t`t}`n`t`t`t`"evrima`"`n`t`t`t{`n`t`t`t`t`"buildid`"`t`t`"$($env:FAKE_LATEST)`"`n`t`t`t`t`"timeupdated`"`t`t`"1`"`n`t`t`t}`n`t`t}`n`t}`n}"
    }
    return
}
Add-Content $log 'update'
if ($env:FAKE_PULL_FAILS -eq '1') { return }
$g = $args[[array]::IndexOf($args, '+force_install_dir') + 1]
$apps = Join-Path $g 'steamapps'; $man = Join-Path $apps 'appmanifest_412680.acf'
$win = Join-Path $g 'TheIsle\Binaries\Win64'; $exe = Join-Path $win 'TheIsleServer-Win64-Shipping.exe'
New-Item -ItemType Directory -Force -Path $apps, $win | Out-Null
if (-not (Test-Path $man)) {
    Set-Content $exe "build $($env:FAKE_LATEST)"
    Set-Content $man "`"AppState`" { `"buildid`"  `"$($env:FAKE_LATEST)`" }"
} elseif (-not (Test-Path $exe)) {
    $bid = ([regex]::Match((Get-Content $man -Raw), '"buildid"\s+"(\d+)"')).Groups[1].Value
    Set-Content $exe "build $bid"
}
'@ | Set-Content -Path $fake -Encoding ascii

$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}

# One server folder per case: installed build, our clean-pull record, what Steam says.
function Run-Case([string]$installed, [string]$mark, [string]$latest, [hashtable]$opt = @{}) {
    $root = Join-Path $work ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $script:game = Join-Path $root 'server'; $script:tmpl = Join-Path $root '_primal'; $script:steam = $fake
    $win = Join-Path $game 'TheIsle\Binaries\Win64'
    New-Item -ItemType Directory -Force -Path $win, $tmpl, (Join-Path $game 'steamapps') | Out-Null
    if ($installed) {
        Set-Content (Join-Path $win 'TheIsleServer-Win64-Shipping.exe') "build $installed"
        Set-Content (Join-Path $game 'steamapps\appmanifest_412680.acf') "`"AppState`" { `"buildid`"  `"$installed`" }"
    }
    Set-Content (Join-Path $win 'dsound.dll') 'asi loader'
    Set-Content (Join-Path $win 'commban.log') 'history'
    if ($mark) { Set-Content (Join-Path $tmpl 'primal-clean-build.txt') $mark }
    if ($opt.leftover) { New-Item -ItemType Directory -Force -Path (Join-Path $game 'TheIsle\Binaries.preupdate\Win64') | Out-Null }
    $env:FAKE_DIR = $root; $env:FAKE_LATEST = $latest
    $env:FAKE_PULL_FAILS = $(if ($opt.fails) { '1' } else { '' })
    $env:FORCE_CLEAN_UPDATE = $(if ($opt.force) { '1' } else { '0' })
    $env:AUTO_UPDATE = $(if ($opt.noupdate) { '0' } else { '1' })
    $out = Invoke-Expression $block 6>&1 | Out-String
    $exe = Join-Path $win 'TheIsleServer-Win64-Shipping.exe'
    $markFile = Join-Path $tmpl 'primal-clean-build.txt'
    return @{
        out = $out
        exe = $(if (Test-Path $exe) { (Get-Content $exe -Raw).Trim() } else { '' })
        mark = $(if (Test-Path $markFile) { (Get-Content $markFile -Raw).Trim() } else { '' })
        dsound = (Test-Path (Join-Path $win 'dsound.dll'))
        log = (Test-Path (Join-Path $win 'commban.log'))
        prev = (Test-Path (Join-Path $game 'TheIsle\Binaries.preupdate'))
        updates = @(Get-Content (Join-Path $root 'calls.log') -ErrorAction SilentlyContinue | Where-Object { $_ -eq 'update' }).Count
    }
}

Write-Host "parse - the evrima branch, never public's"
$vdf = "`"branches`" { `"public`" { `"buildid`" `"1`" } `"evrima`" { `"buildid`" `"2`" `"description`" `"x`" } }"
Invoke-Expression (Lift 'function Read-BranchBuildId' 'function Read-ManifestBuildId')
Ok 'evrima id' ((Read-BranchBuildId $vdf 'evrima') -eq '2')
Ok 'missing branch is empty' ((Read-BranchBuildId $vdf 'legacy') -eq '')
Ok 'no output is empty' ((Read-BranchBuildId '' 'evrima') -eq '')

Write-Host "A - a new Isle build is pulled clean, and dsound.dll survives it"
$r = Run-Case '100' '100' '101'
Ok 'new build running' ($r.exe -eq 'build 101') $r.exe
Ok 'dsound.dll kept' $r.dsound
Ok 'other placed files kept' $r.log
Ok 'record moved to 101' ($r.mark -eq '101') $r.mark
Ok 'nothing left aside' (-not $r.prev)
Ok 'said so' ($r.out -match '-> new-build' -and $r.out -match 'kept across the clean pull: .*dsound\.dll')

Write-Host "B - the stale-manifest bug: an in-place update would NOT have moved the build"
$r = Run-Case '100' '' '101'
Ok 'first boot with a stale install pulls clean' ($r.exe -eq 'build 101' -and $r.mark -eq '101') "$($r.exe) / $($r.mark)"

Write-Host "C - same build: plain validate, nothing set aside"
$r = Run-Case '101' '101' '101'
Ok 'untouched' ($r.exe -eq 'build 101' -and -not $r.prev -and $r.updates -eq 1 -and $r.out -match '-> current')

Write-Host "D - first boot with this code on a current install: adopt, no re-download"
$r = Run-Case '101' '' '101'
Ok 'adopted' ($r.mark -eq '101' -and $r.out -match '-> adopt' -and $r.updates -eq 1)

Write-Host "E - Steam's build unreadable: said, plain validate, record unchanged"
$r = Run-Case '100' '100' ''
Ok 'unknown said' ($r.out -match '-> unknown' -and $r.out -match 'WARNING Steam')
Ok 'record unchanged, build unchanged' ($r.mark -eq '100' -and $r.exe -eq 'build 100')

Write-Host "F - the pull fails: the PREVIOUS build boots, loudly, and the next restart retries"
$r = Run-Case '100' '100' '101' @{ fails = $true }
Ok 'previous exe back' ($r.exe -eq 'build 100') $r.exe
Ok 'dsound.dll back' $r.dsound
Ok 'FAILED said' ($r.out -match 'FAILED: the clean pull left no server exe')
Ok 'record NOT moved' ($r.mark -eq '100') $r.mark
Ok 'self-heal retried once' ($r.updates -eq 2) "$($r.updates)"

Write-Host "G - FORCE_CLEAN_UPDATE=1 pulls clean with no new build"
$r = Run-Case '101' '101' '101' @{ force = $true }
Ok 'forced' ($r.out -match '-> force' -and $r.out -match 'clean pull: TheIsle' -and $r.exe -eq 'build 101' -and $r.dsound)

Write-Host "H - a Binaries.preupdate left by a boot stopped mid-pull is cleared"
$r = Run-Case '101' '101' '101' @{ leftover = $true }
Ok 'cleared' (-not $r.prev)

Write-Host "I - AUTO_UPDATE=0 skips the whole phase"
$r = Run-Case '100' '100' '101' @{ noupdate = $true }
Ok 'skipped' ($r.out -match 'skipped \(AUTO_UPDATE=0' -and $r.exe -eq 'build 100' -and $r.updates -eq 0)

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
foreach ($v in 'FAKE_DIR', 'FAKE_LATEST', 'FAKE_PULL_FAILS', 'FORCE_CLEAN_UPDATE', 'AUTO_UPDATE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "test_cleanupdate: $pass passed, $fail failed"
if ($fail) { exit 1 }
