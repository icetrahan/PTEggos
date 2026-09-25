# #2700 + A230 acceptance - the boot verify+heal job picks ITS OWN server's process, retries
# (a burst, then forever while the process lives), re-injects a DLL that disappears, and reports.
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
# A230 cases: a broken DLL that is fixed AFTER the burst still ends VERIFIED (no give-up); a DLL
# unloaded from a verified pid is re-injected (WATCHDOG); a DLL the in-process primal-loader
# loaded is VERIFIED "via primal-loader" with no injection. The job never ends on its own now,
# so the harness reads its lines as they come and stops it.
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

# The job inherits these: no loader grace (nothing loads in-process here unless a case says so),
# a 2 s watchdog/retry cadence instead of 60 s.
$env:PRIMAL_INJECT_GRACE_S = '0'; $env:PRIMAL_INJECT_WATCH_S = '2'
function Run-Injector([string]$vol, $before, [datetime]$at, [int]$tries, [string]$url = "http://127.0.0.1:$port/v1/boot-report") {
    $log = Join-Path $vol "_primal\$jobName.log"
    $dll = Join-Path $vol "_primal\$dllName"
    $ldr = Join-Path $vol '_primal\primal-loader.log'
    # THIS boot's log carries the world-up line (written after launch, as the engine would)
    $isle = Join-Path $vol 'server\TheIsle\Saved\Logs\TheIsle.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $isle) | Out-Null
    Start-Sleep -Milliseconds 50
    'LogLoad: Took 1.5 seconds to LoadMap(/Game/TheIsle/Maps/Game/Gateway/Gateway)' | Out-File $isle -Encoding ascii
    if ($Egg -eq 'evrima') {
        $a = @($dll, $before, $log, $isle, $at, $vol, $findSrc, $tries, $url, 'phsk_TEST_NOT_A_KEY', $ldr)
    } else {
        $a = @($dll, $before, $log, $vol, $at, $findSrc, $tries, $url, 'phsk_TEST_NOT_A_KEY', $isle, $ldr)
    }
    $j = Start-Job -ScriptBlock ([scriptblock]::Create($injectSrc)) -ArgumentList $a
    return @{ job = $j; log = $log; seen = (New-Object System.Collections.Generic.List[string]) }
}
# The next verdict line the job emits that matches $like (or any line), within $sec. The job keeps running.
function Next-Line($r, [string]$like = '*', [int]$sec = 240) {
    $until = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $until) {
        foreach ($l in @(Receive-Job $r.job -ErrorAction SilentlyContinue)) { $r.seen.Add(('' + $l).Trim()) }
        $hit = $r.seen | Where-Object { $_ -like $like } | Select-Object -First 1
        if ($hit) { [void]$r.seen.Remove($hit); return $hit }
        if ($r.job.State -ne 'Running' -and $r.job.State -ne 'NotStarted') {
            foreach ($l in @(Receive-Job $r.job -ErrorAction SilentlyContinue)) { $r.seen.Add(('' + $l).Trim()) }
            $hit = $r.seen | Where-Object { $_ -like $like } | Select-Object -First 1
            if ($hit) { [void]$r.seen.Remove($hit) }
            return $hit
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}
function Stop-Run($r) { Stop-Job $r.job -ErrorAction SilentlyContinue; Remove-Job $r.job -Force -ErrorAction SilentlyContinue }
function Finish($r) { $v = Next-Line $r; Stop-Run $r; return ('' + $v).Trim() }
# FreeLibrary the DLL inside another process (what a module "disappearing" looks like to the watchdog).
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class PFree {
  [DllImport("kernel32", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool inh, uint pid);
  [DllImport("kernel32", CharSet=CharSet.Ansi)] public static extern IntPtr GetModuleHandleA(string n);
  [DllImport("kernel32", CharSet=CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
  [DllImport("kernel32", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr sa, uint sz, IntPtr start, IntPtr arg, uint fl, IntPtr tid);
  [DllImport("kernel32")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr h);
}
'@
function Unload-In([int]$procId, [string]$modName) {
    $m = Get-Process -Id $procId -Module | Where-Object { $_.ModuleName -ieq $modName } | Select-Object -First 1
    if (-not $m) { return $false }
    $h = [PFree]::OpenProcess(0x1F0FFF, $false, [uint32]$procId)
    $fl = [PFree]::GetProcAddress([PFree]::GetModuleHandleA('kernel32.dll'), 'FreeLibrary')
    for ($k = 0; $k -lt 8 -and (Get-Process -Id $procId -Module | Where-Object { $_.ModuleName -ieq $modName }); $k++) {
        $t = [PFree]::CreateRemoteThread($h, [IntPtr]::Zero, 0, $fl, $m.BaseAddress, 0, [IntPtr]::Zero); [void][PFree]::WaitForSingleObject($t, 5000); [void][PFree]::CloseHandle($t)
    }
    [void][PFree]::CloseHandle($h)
    return -not (Get-Process -Id $procId -Module | Where-Object { $_.ModuleName -ieq $modName })
}
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
    Check 'ambiguous -> FAILED' ($vd -like 'FAILED after 2 attempt(s), still retrying: AMBIGUOUS*') "'$vd'"
    Check 'ambiguous -> nothing injected' ((@(Get-Process -Id $p1.Id, $p2.Id -Module | Where-Object { $_.ModuleName -ieq $dllName }).Count) -eq 0) "$dllName in neither pid"
    Stop-Process -Id $p1.Id, $p2.Id -Force -ErrorAction SilentlyContinue

    # the reports the plane would have received
    Start-Sleep -Milliseconds 500
    $reps = @(Get-ChildItem $capDir -Filter *.json | Sort-Object { [int]$_.BaseName } | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Check 'one report per injector run' ($reps.Count -eq 6) "$($reps.Count) POSTs captured"
    $baseReports = $reps.Count

    # A230 1: NO GIVE-UP. The DLL is unloadable through the whole burst (FAILED reported), then fixed:
    # the job must keep trying and end VERIFIED - one ok=false then one ok=true report.
    $dllC = Join-Path $volC "_primal\$dllName"
    [IO.File]::WriteAllText($dllC, 'not a dll')
    $before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $at = Get-Date; $pc = Start-Fake $volC
    $rc = Run-Injector $volC $before $at 2
    $f1 = Next-Line $rc 'FAILED*'
    Check 'no-give-up: burst FAILED is reported, still retrying' ($f1 -like 'FAILED after 2 attempt(s), still retrying:*') "'$f1'"
    Start-Sleep -Seconds 3
    Check 'no-give-up: the job is still running after the burst' ($rc.job.State -eq 'Running') "job state $($rc.job.State)"
    Copy-Item $srcDll $dllC -Force
    $v1 = Next-Line $rc 'VERIFIED*' 60
    Check 'no-give-up: fixed DLL -> VERIFIED by the injector, same pid' ($v1 -like "VERIFIED pid $($pc.Id) via the injector*") "'$v1'"

    # A230 2: WATCHDOG. Unload the DLL from the verified pid: the job must notice and re-inject.
    $gone = Unload-In $pc.Id $dllName
    $v2 = Next-Line $rc 'VERIFIED*' 60
    $wd = Select-String -Path $rc.log -Pattern "WATCHDOG: $dllName was GONE from verified pid $($pc.Id)" -SimpleMatch -Quiet
    Check 'watchdog: unloaded DLL is re-injected' ($gone -and $wd -and $v2 -like "VERIFIED pid $($pc.Id) via the injector*") "unloaded=$gone watchdog-line=$wd then '$v2'"
    if (-not ($gone -and $wd)) {
        Write-Host "--- watchdog debug: job state $($rc.job.State); log:"; Get-Content $rc.log | ForEach-Object { Write-Host "  $_" }
        $rc.job.ChildJobs | ForEach-Object { $_.Error } | ForEach-Object { Write-Host "  JOB ERROR: $_" }
        Write-Host "  modules now: $((Get-Process -Id $pc.Id -Module | Where-Object { $_.ModuleName -like 'LegacyMod*' -or $_.ModuleName -like 'commban*' } | ForEach-Object ModuleName) -join ',')"
    }
    Stop-Run $rc; Stop-Process -Id $pc.Id -Force -ErrorAction SilentlyContinue

    # A230 3: the in-process loader already loaded it -> VERIFIED "via primal-loader", NOTHING injected.
    # Stand-in for primal-loader: get the DLL into the process first (a one-off run, stopped at
    # VERIFIED), write the loader's own log line for that pid, then start the real job fresh.
    $before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $at = Get-Date; $pa = Start-Fake $volA
    Start-Sleep -Milliseconds 300
    $pre = Run-Injector $volA $before $at 1; [void](Next-Line $pre 'VERIFIED*' 60); Stop-Run $pre
    "2026-09-25T00:00:00Z pid $($pa.Id) LOADED: $volA\_primal\$dllName handle=0x0" | Out-File (Join-Path $volA '_primal\primal-loader.log') -Encoding ascii
    $ra = Run-Injector $volA $before $at 2
    $v3 = Next-Line $ra 'VERIFIED*' 60
    $injected = Select-String -Path $ra.log -Pattern 'injecting into pid' -SimpleMatch -Quiet
    Check 'loader-loaded: VERIFIED via primal-loader, no injection' ($v3 -like "VERIFIED pid $($pa.Id) via primal-loader*" -and -not $injected) "'$v3' injected-by-job=$injected"
    Stop-Run $ra; Stop-Process -Id $pa.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $all = @(Get-ChildItem $capDir -Filter *.json | Sort-Object { [int]$_.BaseName } | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    $newer = @($all | Select-Object -Skip $baseReports)
    # no-give-up: fail + ok; watchdog: ok; the pre-load run: ok; loader-loaded: ok
    Check 'A230 reports: first FAILED, then each VERIFIED' ($newer.Count -eq 5 -and $newer[0].body.ok -eq $false -and @($newer | Select-Object -Skip 1 | Where-Object { -not $_.body.ok }).Count -eq 0) (($newer | ForEach-Object { "ok=$($_.body.ok)" }) -join ' ')

    # A230 4: THE PLANE IS DOWN when the job verifies (09-25 19:46Z Noobz L1: the VERIFIED POST timed out
    # once and was dropped). The verdict must be re-sent on a later pass and arrive once the plane is up.
    $port2 = Get-Random -Minimum 40001 -Maximum 50000
    $cap2 = Join-Path $work 'reports2'; New-Item -ItemType Directory -Force -Path $cap2 | Out-Null
    $before = @(Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $at = Get-Date; $pb = Start-Fake $volB
    $rr = Run-Injector $volB $before $at 2 "http://127.0.0.1:$port2/v1/boot-report"
    $v4 = Next-Line $rr 'VERIFIED*' 60
    Check 'plane-down: VERIFIED, and says the report FAILED' ($v4 -like "VERIFIED pid $($pb.Id)*report FAILED*") "'$v4'"
    $late = Start-Job -ArgumentList $port2, $cap2 -ScriptBlock {
        param($port, $dir)
        $l = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $l.Start()
        $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $s.ReadTimeout = 5000
        $buf = New-Object byte[] 65536; $got = 0
        do { $n = $s.Read($buf, $got, $buf.Length - $got); $got += $n; $req = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
             $he = $req.IndexOf("`r`n`r`n"); $len = if ($req -match 'Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        } while ($n -gt 0 -and ($he -lt 0 -or $got -lt $he + 4 + $len))
        $req.Substring($he + 4) | Out-File (Join-Path $dir 'late.json') -Encoding utf8
        $resp = '{"ok":true,"recorded":true,"paged":false}'
        $out = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($resp.Length)`r`nConnection: close`r`n`r`n$resp")
        $s.Write($out, 0, $out.Length); $s.Flush(); $c.Close(); $l.Stop()
    }
    $t0 = Get-Date
    while (-not (Test-Path (Join-Path $cap2 'late.json')) -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 300 }
    Start-Sleep -Milliseconds 500
    $lateBody = if (Test-Path (Join-Path $cap2 'late.json')) { Get-Content (Join-Path $cap2 'late.json') -Raw | ConvertFrom-Json } else { $null }
    $retryLine = Select-String -Path $rr.log -Pattern 'verdict reached the plane on a retry' -SimpleMatch -Quiet
    Check 'plane-down: the SAME verdict arrives once the plane is up' ($lateBody -and $lateBody.ok -eq $true -and $lateBody.pid -eq $pb.Id -and $retryLine) "late POST ok=$($lateBody.ok) pid=$($lateBody.pid); log says retried=$retryLine"
    Stop-Run $rr; Stop-Job $late -ErrorAction SilentlyContinue; Remove-Job $late -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $pb.Id -Force -ErrorAction SilentlyContinue
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
