# #2700 end-to-end: the WHOLE start-legacy.ps1 (not lifted pieces) boots a fake volume while
# rival "servers" from another volume start around it every 200 ms - the 01:01:05Z race, on
# purpose. Then it reads what a human would read: the console, _primal/primal-inject.log and
# the POST the plane would have received.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_launch_e2e.ps1 [-Old <old-wrapper.ps1>]
#
# The fake game exe is compiled here (C#): run bare, it re-spawns itself detached with
# `--child N` and exits - the measured Legacy behaviour ("supervising detached server pid") -
# and the child lives N seconds. LegacyMod.dll is a renamed system DLL (a real LoadLibrary).
# Case OK  : new wrapper, rivals racing -> VERIFIED in ITS OWN pid, console + report agree.
# Case FAIL: LegacyMod.dll is not a DLL -> FAILED banner on the console + ok=false report.
# -Old     : the pre-fix wrapper under the same race, reported (not asserted) for contrast.
param([string]$Old)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$new  = Join-Path $here 'start-legacy.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ("launch-e2e-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fakeExe = Join-Path $work 'fake.exe'
Add-Type -OutputAssembly $fakeExe -OutputType ConsoleApplication -TypeDefinition @'
using System; using System.Diagnostics; using System.Threading;
public static class FakeIsle {
  public static void Main(string[] a) {
    if (a.Length >= 2 && a[0] == "--child") { Thread.Sleep(int.Parse(a[1]) * 1000); return; }
    string life = Environment.GetEnvironmentVariable("FAKE_LIFE"); if (string.IsNullOrEmpty(life)) life = "60";
    var psi = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--child " + life);
    psi.UseShellExecute = false; psi.CreateNoWindow = true;
    Process.Start(psi);
  }
}
'@

# the plane stand-in: GET /v1/boot-config -> 503 (the wrapper's egg-var rung), POST /v1/boot-report -> captured
$port = Get-Random -Minimum 20000 -Maximum 40000
$cap = Join-Path $work 'reports'; New-Item -ItemType Directory -Force -Path $cap | Out-Null
$listener = Start-Job -ArgumentList $port, $cap -ScriptBlock {
    param($port, $dir)
    $l = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $l.Start()
    for ($k = 0; $k -lt 100; $k++) {
        $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $s.ReadTimeout = 5000
        $buf = New-Object byte[] 65536; $got = 0; $req = ''
        do { $n = $s.Read($buf, $got, $buf.Length - $got); $got += $n; $req = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
             $he = $req.IndexOf("`r`n`r`n"); $len = if ($req -match 'Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        } while ($n -gt 0 -and ($he -lt 0 -or $got -lt $he + 4 + $len))
        if ($req -like 'POST /v1/boot-report*') {
            $req.Substring($he + 4) | Out-File (Join-Path $dir "$k.json") -Encoding utf8
            $resp = '{"ok":true,"recorded":true,"alert":"raised","paged":true,"mode":"discord"}'; $st = '200 OK'
        } else { $resp = '{"error":"test stand-in"}'; $st = '503 Service Unavailable' }
        $out = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $st`r`nContent-Type: application/json`r`nContent-Length: $($resp.Length)`r`nConnection: close`r`n`r`n$resp")
        $s.Write($out, 0, $out.Length); $s.Flush(); $c.Close()
    }
}
Start-Sleep -Milliseconds 700

function New-Root([string]$name, [bool]$goodDll) {
    $r = Join-Path $work $name
    $bin = Join-Path $r 'server\TheIsle\Binaries\Win64'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $r '_primal'), (Join-Path $r '_mods') | Out-Null
    Copy-Item $fakeExe (Join-Path $bin 'TheIsleServer-Win64-Shipping.exe')
    $dll = Join-Path $r '_primal\LegacyMod.dll'
    if ($goodDll) { Copy-Item (Join-Path $env:WINDIR 'System32\msimg32.dll') $dll } else { [IO.File]::WriteAllText($dll, 'not a dll') }
    return $r
}
$rivalRoot = New-Root 'rival' $true
$rivalExe  = Join-Path $rivalRoot 'server\TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe'
$rivals = New-Object System.Collections.Generic.List[int]

function Boot([string]$wrapper, [string]$root, [hashtable]$extra) {
    $envSave = @{}
    $vars = @{ ENABLE_PRIMAL_MOD = '1'; PRIMAL_MOD_MANIFEST = "http://127.0.0.1:$port/no-manifest.json"; PHSK_KEY = 'phsk_TEST_NOT_A_KEY'
               PRIMAL_DATA_BASE = "http://127.0.0.1:$port"; SERVER_NAME = 'e2e'; MAP = 'Isle V3'; GAME_MODE = 'Survival'; MAX_PLAYERS = '10'
               SERVER_PORT = '17780'; SERVER_PORT_1 = '17781'; MULTIHOME_AUTO = '0'; FAKE_LIFE = '60'; PRIMAL_INJECT_ATTEMPTS = '2' }
    foreach ($k in $extra.Keys) { $vars[$k] = $extra[$k] }
    foreach ($k in $vars.Keys) { $envSave[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    $outF = Join-Path $root 'console.txt'
    try {
        $w = Start-Process powershell -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $wrapper -WorkingDirectory $root -RedirectStandardOutput $outF -RedirectStandardError (Join-Path $root 'console.err.txt') -WindowStyle Hidden -PassThru
    } finally { foreach ($k in $envSave.Keys) { [Environment]::SetEnvironmentVariable($k, $envSave[$k]) } }
    # rivals: another volume's server starting every 200 ms from ~1 s before to ~6 s after launch
    $deadline = (Get-Date).AddSeconds(25)
    $launched = $false
    while ((Get-Date) -lt $deadline) {
        if (-not $launched -and (Test-Path $outF) -and (Select-String -Path $outF -Pattern '\(start\) .* launching' -Quiet)) { $launched = $true; $until = (Get-Date).AddSeconds(6) }
        if ($launched -and (Get-Date) -gt $until) { break }
        if ($launched) { $p = Start-Process $rivalExe -ArgumentList '--child', '90' -WindowStyle Hidden -PassThru; $rivals.Add($p.Id) }
        Start-Sleep -Milliseconds 200
    }
    [void]$w.WaitForExit(150000)
    if (-not $w.HasExited) { Stop-Process -Id $w.Id -Force }
    return @{ out = (Get-Content $outF -Raw -ErrorAction SilentlyContinue); log = (Get-Content (Join-Path $root '_primal\primal-inject.log') -Raw -ErrorAction SilentlyContinue) }
}

$fail = 0; $lines = New-Object System.Collections.Generic.List[string]
function Check([string]$n, [bool]$c, [string]$d) { $script:lines.Add(("{0}  {1}  {2}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $n, $d)); if (-not $c) { $script:fail++ } }
function Reports { @(Get-ChildItem $cap -Filter *.json -ErrorAction SilentlyContinue | Sort-Object { [int]$_.BaseName } | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }

try {
    # ── OK: the new wrapper, racing ──
    $ok = New-Root 'ok' $true
    $r = Boot $new $ok @{}
    $sup = [regex]::Match("$($r.out)", 'supervising detached server pid (\d+) \(([^)]*)\)')
    $ver = [regex]::Match("$($r.log)", 'VERIFIED: LegacyMod.dll is loaded in pid (\d+) \(([^)]*)\)')
    Check 'ok: supervised its own process' ($sup.Success -and $sup.Groups[2].Value.StartsWith("$ok\", 'OrdinalIgnoreCase')) $sup.Value
    Check 'ok: inject VERIFIED in its own process' ($ver.Success -and $ver.Groups[2].Value.StartsWith("$ok\", 'OrdinalIgnoreCase') -and $ver.Groups[1].Value -eq $sup.Groups[1].Value) $ver.Value
    Check 'ok: console carries the verdict' ("$($r.out)" -match '\(primal-mod\) inject VERIFIED pid') ([regex]::Match("$($r.out)", '\(primal-mod\) inject [^\r\n]*').Value)
    Check 'ok: rivals were racing it' ($rivals.Count -ge 10) "$($rivals.Count) rival processes started around the launch"
    $rep = @(Reports | Where-Object { $_.volume -like "*\ok" })
    Check 'ok: one ok=true report with its own exe' ($rep.Count -eq 1 -and $rep[0].ok -eq $true -and "$($rep[0].exePath)".StartsWith("$ok\", 'OrdinalIgnoreCase')) (($rep | ConvertTo-Json -Compress))
    Write-Host '--- ok: primal-inject.log ---'; "$($r.log)".Trim() -split "`r?`n" | ForEach-Object { Write-Host "  $_" }

    # ── FAIL: LoadLibrary cannot load it -> banner + ok=false ──
    $bad = New-Root 'bad' $false
    $r2 = Boot $new $bad @{}
    Check 'fail: log says FAILED' ("$($r2.log)" -match 'FAILED: the mod is NOT loaded after 2 attempt\(s\)') ([regex]::Match("$($r2.log)", 'FAILED: [^\r\n]*').Value)
    Check 'fail: console banner' ("$($r2.out)" -match '\*\*\* MOD NOT LOADED:') ([regex]::Match("$($r2.out)", '\*\*\* MOD NOT LOADED:[^\r\n]*').Value)
    $rep2 = @(Reports | Where-Object { $_.volume -like "*\bad" })
    Check 'fail: one ok=false report with a reason' ($rep2.Count -eq 1 -and $rep2[0].ok -eq $false -and $rep2[0].reason) (($rep2 | ConvertTo-Json -Compress))
    Check 'fail: the boot still continued (supervised to the end)' ("$($r2.out)" -match 'Legacy server process ended') ''
    Write-Host '--- fail: console (primal-mod lines) ---'; "$($r2.out)" -split "`r?`n" | Where-Object { $_ -match 'primal-mod|\(start\) supervising' } | ForEach-Object { Write-Host "  $_" }

    # ── OLD, same race, for the record ──
    if ($Old) {
        $o = New-Root 'old' $true
        $r3 = Boot $Old $o @{}
        $pick = [regex]::Match("$($r3.log)", 'injecting into pid (\d+)')
        $what = if ($pick.Success) {
            $procId = [int]$pick.Groups[1].Value
            if ($rivals -contains $procId) { "pid $procId = a RIVAL (another volume's server)" } else { "pid $procId = its own (or its launcher)" }
        } else { 'no pick' }
        $lines.Add("INFO  old wrapper under the same race: $what; log tail: $((("$($r3.log)".Trim() -split "`r?`n") | Select-Object -Last 2) -join ' | ')")
    }
} finally {
    foreach ($id in $rivals) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Get-Process TheIsleServer-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like "$work\*" } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Job $listener -ErrorAction SilentlyContinue; Remove-Job $listener -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
$lines | ForEach-Object { Write-Host $_ }
Write-Host ("e2e: {0} check(s) failed" -f $fail)
exit ([int]($fail -gt 0))
