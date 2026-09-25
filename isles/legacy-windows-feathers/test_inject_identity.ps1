# #2700 acceptance - the boot injector picks ITS OWN server's process, retries, and reports.
#
# Runs the REAL code out of start-legacy.ps1 (Find-OwnServer + the primal-inject job's
# scriptblock, lifted by AST - no copy that could drift) against fake volumes on THIS box:
#   volA\server\...\TheIsleServer-Win64-Shipping.exe   (a renamed copy of a 64-bit system exe)
#   volB\server\...\TheIsleServer-Win64-Shipping.exe
# Both are started in the SAME second - the 09-24 01:01:05Z race - in both orders, and the
# injector for each volume must choose its own pid and VERIFY a DLL (a renamed system DLL)
# in that pid's module list. Then the failure paths: nothing under the volume, two under
# it (AMBIGUOUS), each must end FAILED and POST a report (captured by a local listener).
# The pre-fix one-liner is run beside it on the same race so the difference is on record.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_inject_identity.ps1
# Exit 0 = every case PASS. Needs no admin; kills only the pids it started.
# -Egg evrima runs the same cases against the Evrima wrapper's comm-ban injector (it also
# waits for a world-up line in THIS boot's TheIsle.log, which the harness writes).
# -Wrapper <path> runs them against another copy (mutant runs).
param([ValidateSet('legacy', 'evrima')][string]$Egg = 'legacy', [string]$Wrapper)
$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = if ($Wrapper) { $Wrapper } elseif ($Egg -eq 'evrima') { Join-Path $here '..\evrima-windows-feathers\start-evrima.ps1' } else { Join-Path $here 'start-legacy.ps1' }
$jobName = if ($Egg -eq 'evrima') { 'primal-commban-inject' } else { 'primal-inject' }
$dllName = if ($Egg -eq 'evrima') { 'commban.dll' } else { 'LegacyMod.dll' }
$work    = Join-Path ([IO.Path]::GetTempPath()) ("inject-identity-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# ── lift the real code out of the wrapper ────────────────────────────────────
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tok, [ref]$err)
if ($err.Count) { throw "wrapper does not parse: $($err[0].Message)" }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Find-OwnServer' }, $true)
if (-not $fn) { throw 'Find-OwnServer not found in the wrapper' }
# Define it from its own text, then hand the job ${function:...}.ToString() - exactly what the wrapper passes.
Invoke-Expression $fn.Extent.Text
$findSrc = ${function:Find-OwnServer}.ToString()
$job = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Job' -and $n.Extent.Text -match "-Name $jobName " }, $true)
if (-not $job) { throw "$jobName Start-Job not found in the wrapper" }
$sbAst = $job.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1
$injectSrc = $sbAst.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}')

# ── fake volumes ─────────────────────────────────────────────────────────────
$srcExe = Join-Path $env:WINDIR 'System32\PING.EXE'
$srcDll = Join-Path $env:WINDIR 'System32\msimg32.dll'
function New-Vol([string]$n) {
    $v = Join-Path $work $n
    $bin = Join-Path $v 'server\TheIsle\Binaries\Win64'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $v '_primal') | Out-Null
    Copy-Item $srcExe (Join-Path $bin 'TheIsleServer-Win64-Shipping.exe')
    Copy-Item $srcDll (Join-Path $v "_primal\$dllName")
    return $v
}
$volA = New-Vol 'volA'; $volB = New-Vol 'volB'; $volC = New-Vol 'volC'
$started = New-Object System.Collections.Generic.List[int]
function Start-Fake([string]$vol) {
    $p = Start-Process -FilePath (Join-Path $vol 'server\TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe') -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru
    $started.Add($p.Id); return $p
}

# ── a local stand-in for POST /v1/boot-report (captures the body, answers like the plane) ──
$port = Get-Random -Minimum 20000 -Maximum 40000
$capDir = Join-Path $work 'reports'; New-Item -ItemType Directory -Force -Path $capDir | Out-Null
$listener = Start-Job -ArgumentList $port, $capDir -ScriptBlock {
    param($port, $dir)
    $l = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $l.Start()
    for ($k = 0; $k -lt 50; $k++) {
        $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $s.ReadTimeout = 5000
        $buf = New-Object byte[] 65536; $got = 0; $req = ''
        do { $n = $s.Read($buf, $got, $buf.Length - $got); $got += $n; $req = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
             $hdrEnd = $req.IndexOf("`r`n`r`n"); $len = if ($req -match 'Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        } while ($n -gt 0 -and ($hdrEnd -lt 0 -or $got -lt $hdrEnd + 4 + $len))
        $body = $req.Substring($hdrEnd + 4)
        $auth = if ($req -match 'Authorization:\s*Bearer (\S+)') { $Matches[1] } else { '' }
        @{ auth = $auth; body = ($body | ConvertFrom-Json) } | ConvertTo-Json -Depth 5 | Out-File (Join-Path $dir "$k.json") -Encoding utf8
        $resp = '{"ok":true,"recorded":true,"paged":true}'
        $out = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($resp.Length)`r`nConnection: close`r`n`r`n$resp")
        $s.Write($out, 0, $out.Length); $s.Flush(); $c.Close()
    }
}
Start-Sleep -Milliseconds 700

function Run-Injector([string]$vol, $before, [datetime]$at, [int]$tries) {
    $log = Join-Path $vol "_primal\$jobName.log"
    $dll = Join-Path $vol "_primal\$dllName"
    $url = "http://127.0.0.1:$port/v1/boot-report"
    if ($Egg -eq 'evrima') {
        # THIS boot's log carries the world-up line (written after launch, as the engine would)
        $isle = Join-Path $vol 'server\TheIsle\Saved\Logs\TheIsle.log'
        New-Item -ItemType Directory -Force -Path (Split-Path $isle) | Out-Null
        Start-Sleep -Milliseconds 50
        'LogLoad: Took 1.5 seconds to LoadMap(/Game/TheIsle/Maps/Game/Gateway/Gateway)' | Out-File $isle -Encoding ascii
        $a = @($dll, $before, $log, $isle, $at, $vol, $findSrc, $tries, $url, 'phsk_TEST_NOT_A_KEY')
    } else {
        $a = @($dll, $before, $log, $vol, $at, $findSrc, $tries, $url, 'phsk_TEST_NOT_A_KEY')
    }
    $j = Start-Job -ScriptBlock ([scriptblock]::Create($injectSrc)) -ArgumentList $a
    return @{ job = $j; log = $log }
}
function Finish($r) { [void](Wait-Job $r.job -Timeout 240); $v = ('' + (Receive-Job $r.job | Select-Object -Last 1)).Trim(); Remove-Job $r.job -Force; return $v }
function Old-Pick($before) { (Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } | Select-Object -First 1).Id }

$results = New-Object System.Collections.Generic.List[string]
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    $script:results.Add(("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail))
    if (-not $ok) { $script:fail++ }
}

try {
    foreach ($order in @('A-then-B', 'B-then-A')) {
        $before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        $at = Get-Date
        if ($order -eq 'A-then-B') { $pa = Start-Fake $volA; $pb = Start-Fake $volB } else { $pb = Start-Fake $volB; $pa = Start-Fake $volA }
        $gap = [Math]::Abs(($pa.StartTime - $pb.StartTime).TotalMilliseconds)
        $old = Old-Pick $before
        $ra = Run-Injector $volA $before $at 2; $rb = Run-Injector $volB $before $at 2
        $va = Finish $ra; $vb = Finish $rb
        Check "race $order volA" ($va -like "VERIFIED pid $($pa.Id) *") "A=$($pa.Id) B=$($pb.Id) started $([int]$gap) ms apart; old rule picked $old; new -> '$va'"
        Check "race $order volB" ($vb -like "VERIFIED pid $($pb.Id) *") "new -> '$vb'"
        Check "race $order no cross-load" ((@(Get-Process -Id $pb.Id -Module | Where-Object { $_.FileName -like "$volA\*" }).Count -eq 0) -and (@(Get-Process -Id $pa.Id -Module | Where-Object { $_.FileName -like "$volB\*" }).Count -eq 0)) "volA's DLL absent from B's pid and volB's from A's"
        Stop-Process -Id $pa.Id, $pb.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500
    }

    # FAILURE 1: nothing of volC's is running (volB's process is, in the same second)
    $before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $at = Get-Date; $pb = Start-Fake $volB
    $vc = Finish (Run-Injector $volC $before $at 2)
    Check 'missing -> FAILED' ($vc -like 'FAILED*no process of THIS server*') "'$vc' (old rule would have picked $(Old-Pick $before) = volB's)"
    Stop-Process -Id $pb.Id -Force -ErrorAction SilentlyContinue

    # FAILURE 2: two new processes under volA -> refuse by name, never guess
    $before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $at = Get-Date; $p1 = Start-Fake $volA; $p2 = Start-Fake $volA
    $vd = Finish (Run-Injector $volA $before $at 2)
    Check 'ambiguous -> FAILED' ($vd -like 'FAILED after 2 attempt(s): AMBIGUOUS*') "'$vd'"
    Check 'ambiguous -> nothing injected' ((@(Get-Process -Id $p1.Id, $p2.Id -Module | Where-Object { $_.ModuleName -ieq $dllName }).Count) -eq 0) "$dllName in neither pid"
    Stop-Process -Id $p1.Id, $p2.Id -Force -ErrorAction SilentlyContinue

    # the reports the plane would have received
    Start-Sleep -Milliseconds 500
    $reps = @(Get-ChildItem $capDir -Filter *.json | Sort-Object { [int]$_.BaseName } | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Check 'one report per injector run' ($reps.Count -eq 6) "$($reps.Count) POSTs captured"
    Check 'reports carry the server key' (@($reps | Where-Object { $_.auth -ne 'phsk_TEST_NOT_A_KEY' }).Count -eq 0) 'Bearer = the phsk_ passed in'
    $bad = @($reps | Where-Object { -not $_.body.ok })
    Check 'failures reported as ok=false' ($bad.Count -eq 2 -and @($bad | Where-Object { $_.body.stage -ne 'inject' -or -not $_.body.reason -or $_.body.game -ne $Egg }).Count -eq 0) (($bad | ForEach-Object { "ok=$($_.body.ok) reason='$($_.body.reason)'" }) -join ' | ')
    $good = @($reps | Where-Object { $_.body.ok })
    Check 'successes carry the exe path inside their volume' (@($good | Where-Object { -not ("$($_.body.exePath)".StartsWith("$($_.body.volume)\", 'OrdinalIgnoreCase')) }).Count -eq 0 -and $good.Count -eq 4) (($good | ForEach-Object { "pid $($_.body.pid) $($_.body.exePath)" }) -join ' | ')
    Write-Host "--- volA $jobName.log (last run) ---"
    Get-Content (Join-Path $volA "_primal\$jobName.log") | ForEach-Object { Write-Host "  $_" }
} finally {
    foreach ($id in $started) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Stop-Job $listener -ErrorAction SilentlyContinue; Remove-Job $listener -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
$results | ForEach-Object { Write-Host $_ }
Write-Host ("[{2}] {0} case(s), {1} failed" -f $results.Count, $fail, $Egg)
exit ([int]($fail -gt 0))
