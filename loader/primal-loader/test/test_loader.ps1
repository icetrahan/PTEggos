# primal-loader harness (A230). Real Ultimate ASI Loader dsound.dll (the sha-pinned sigbypass binary)
# + the built primal-loader.asi + a stand-in game exe that statically imports DSOUND.dll.
#   powershell -File test_loader.ps1 -Dsound <path to dsound.dll>
param([Parameter(Mandatory)][string]$Dsound)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$asi  = Join-Path $here '..\build\primal-loader.asi'
$exeB = Join-Path $here 'build\fake_game.exe'
$prb  = Join-Path $here 'build\probe.dll'
$pass = 0; $fail = 0
function Case([string]$name, [scriptblock]$setup, [int]$world, [int]$run, [int]$openAfter, [bool]$wantLoaded, [string]$wantLog) {
    $d = Join-Path $here "run\$name"
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    $bin = New-Item -ItemType Directory -Force (Join-Path $d 'Binaries\Win64')
    $pd  = New-Item -ItemType Directory -Force (Join-Path $d '_primal')
    Copy-Item $exeB (Join-Path $bin 'TheIsleServer-Win64-Shipping.exe')
    Copy-Item $Dsound (Join-Path $bin 'dsound.dll')
    Copy-Item $asi (Join-Path $bin 'primal-loader.asi')
    Copy-Item $prb (Join-Path $pd 'LegacyMod.dll')
    $gameLog = Join-Path $d 'TheIsle.log'
    $ini = @("[loader]", "log=$pd\primal-loader.log", "world_log=$gameLog", "world_match=LogWorld: Bringing World", "world_timeout_s=12",
             "settle_s=1", "retry_s=1", "retries=2", "load=$pd\LegacyMod.dll") -join "`r`n"
    Set-Content -Path (Join-Path $bin 'primal-loader.ini') -Value $ini -Encoding ascii
    & $setup $d $bin $pd $gameLog
    $p = Start-Process -FilePath (Join-Path $bin 'TheIsleServer-Win64-Shipping.exe') -ArgumentList "`"$gameLog`" $world $run `"$pd\LegacyMod.dll`" $openAfter" -PassThru -Wait -NoNewWindow -RedirectStandardOutput (Join-Path $d 'stdout.txt')
    $out = Get-Content (Join-Path $d 'stdout.txt') -Raw
    $loaded = $out -match 'probe_loaded=yes'
    $ll = if (Test-Path "$pd\primal-loader.log") { Get-Content "$pd\primal-loader.log" -Raw } elseif (Test-Path "$bin\primal-loader.log") { Get-Content "$bin\primal-loader.log" -Raw } else { '' }
    $ok = ($loaded -eq $wantLoaded) -and ($ll -match $wantLog)
    if ($ok) { $script:pass++ } else { $script:fail++ }
    "{0} {1,-26} loaded={2} (want {3}) log~/{4}/" -f $(if ($ok) {'PASS'} else {'FAIL'}), $name, $loaded, $wantLoaded, $wantLog
    if (-not $ok) { "---- loader log`n$ll---- stdout`n$out" }
    $ll.Trim().Split("`n") | Select-Object -Last 3 | ForEach-Object { "      $_" }
}
$none = { param($d, $bin, $pd, $gl) }
# 1. the happy path: world at 3 s -> loaded after it, +settle
Case 'happy' $none 3 9 0 $true 'world up after [3-5] s[\s\S]*LOADED: '
# 2. the previous boot's log (world line inside, last written an hour ago) sits there for 4 s and the
#    new boot's world arrives at 7 s: the loader must NOT take the stale line.
Case 'stale-log-then-world' { param($d, $bin, $pd, $gl) Set-Content $gl "LogWorld: Bringing World /Game/OLD up for play" -Encoding ascii; (Get-Item $gl).LastWriteTime = (Get-Date).AddHours(-1) } 7 13 4 $true 'world up after [6-9] s[\s\S]*LOADED: '
# 3. stale log and this boot's world NEVER comes: nothing loads, and it says so.
Case 'stale-log-no-world' { param($d, $bin, $pd, $gl) Set-Content $gl "LogWorld: Bringing World /Game/OLD up for play" -Encoding ascii; (Get-Item $gl).LastWriteTime = (Get-Date).AddHours(-1) } -1 16 4 $false 'NOT LOADED: the world never came up'
# 4. no ini: nothing loads and it says so
Case 'no-ini' { param($d, $bin, $pd, $gl) Remove-Item (Join-Path $bin 'primal-loader.ini') } 2 6 0 $false 'NOTHING TO LOAD: no primal-loader.ini'
# 5. ini lists no load= (mod off)
Case 'mod-off' { param($d, $bin, $pd, $gl) Set-Content (Join-Path $bin 'primal-loader.ini') "log=$pd\primal-loader.log`r`nworld_log=$gl`r`nworld_match=LogWorld: Bringing World" -Encoding ascii } 2 6 0 $false 'NOTHING TO LOAD: primal-loader.ini lists no load='
# 6. the DLL is missing: retries, then FAILED by name
Case 'dll-missing' { param($d, $bin, $pd, $gl) Remove-Item (Join-Path $pd 'LegacyMod.dll') } 2 10 0 $false 'FAILED: .*NOT loaded after 2 attempt'
# 7. control: no primal-loader.asi -> the probe is never loaded (the ASI loader IS the mechanism)
Case 'control-no-asi' { param($d, $bin, $pd, $gl) Remove-Item (Join-Path $bin 'primal-loader.asi') } 2 7 0 $false '^$'
"== $pass pass, $fail fail"
exit $fail
