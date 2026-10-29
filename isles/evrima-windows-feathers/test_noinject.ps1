# Behaviour test for the comm-ban "not injecting" branches in start-evrima.ps1 (BUGS #3499).
# Runs the REAL lines lifted from the shipping wrapper, never a copy of them. The plane is a
# local HttpListener; the report job posts to it over real HTTP.
#   powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_noinject.ps1
$ErrorActionPreference = 'Stop'
$lines = Get-Content (Join-Path $PSScriptRoot 'start-evrima.ps1')

function Lift([string]$from, [string]$to, [int]$dropLast) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { throw "anchor not found: $from" }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { throw "end anchor not found: $to" }
    return (($lines[($a-1)..($a+$b-2)] | Select-Object -SkipLast $dropLast) -join "`n")
}
$envOr    = Lift 'function EnvOr(' 'function EnvOr(' 0
$decide   = Lift 'function Invoke-Retried(' '# MassMigrationTime = 48 h' 1
$report   = Lift '$cbHist = Join-Path $tmpl' 'Dbg "launching (server will detach' 1
$drain    = Lift 'function Show-SkipReport {' '$pos = 0' 1
Write-Host "lifted: decide $(($decide -split "`n").Count) lines, report $(($report -split "`n").Count), drain $(($drain -split "`n").Count)`n"
Invoke-Expression $envOr

$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  ok   $label" } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}

# ---- the world the decide block sees ----
$KEY = 'phsk_' + ('ab' * 24)
$work = Join-Path $env:TEMP ('ni_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Reset-World {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    $script:binDirWin = Join-Path $work 'bin'; $script:tmpl = Join-Path $work '_primal'
    New-Item -ItemType Directory -Force -Path $script:binDirWin, $script:tmpl | Out-Null
    $script:phsk = $KEY; $env:PRIMAL_COMMBAN = '1'; $env:P_SERVER_UUID = 'test-uuid'
    $script:net = @{ manifestCalls = 0; manifestFails = 0; manifest = $null; downloadCalls = 0; downloadFails = 0; bytes = 'GOOD-DLL'; slept = 0 }
    $script:cm = $null; $script:cbSkip = $null; $script:cbReady = $false
}
function Sha([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return (-join ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }))
}
function Manifest([string]$name = 'commban.dll', [string]$content = 'GOOD-DLL') {
    return [pscustomobject]@{ version = '1.2.0'; files = @([pscustomobject]@{ name = $name; url = "https://r2.test/$name"; sha256 = (Sha $content); size = $content.Length }) }
}
# The manifest read, the download and the back-off, replaced for the decide block only (functions win over cmdlets).
function Invoke-RestMethod { param([string]$Uri, [int]$TimeoutSec)
    $script:net.manifestCalls++
    if ($script:net.manifestCalls -le $script:net.manifestFails) { throw "The operation has timed out. ($Uri)" }
    return $script:net.manifest
}
function Save-Download { param([string]$Uri, [string]$OutFile)
    $script:net.downloadCalls++
    if ($script:net.downloadCalls -le $script:net.downloadFails) { throw "The remote name could not be resolved: 'r2.test'" }
    [IO.File]::WriteAllText($OutFile, $script:net.bytes, [Text.Encoding]::ASCII)
}
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:net.slept += $Seconds }
# The lifted blocks run at SCRIPT scope (a function would keep their variables to itself).

Write-Host "A - which boots inject, and what the others are called"
Reset-World; $env:PRIMAL_COMMBAN = ''
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'off: not ready, and NOT a skip (an unarmed server reports nothing)' (-not $cbReady -and $null -eq $cbSkip -and $out -match 'off \(PRIMAL_COMMBAN != 1\)')

Reset-World; $net.manifest = Manifest
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'healthy: ready, no skip, the DLL and its ini are in place' ($cbReady -and $null -eq $cbSkip -and (Test-Path (Join-Path $binDirWin 'commban.dll')) -and (Test-Path (Join-Path $binDirWin 'commban.ini'))) $out
Ok 'healthy: one manifest read, one download, no back-off' ($net.manifestCalls -eq 1 -and $net.downloadCalls -eq 1 -and $net.slept -eq 0)

Reset-World; $net.manifest = Manifest; $net.manifestFails = 2
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a manifest read that fails TWICE is retried and the boot injects' ($cbReady -and $null -eq $cbSkip -and $net.manifestCalls -eq 3 -and $net.slept -eq 7) "calls=$($net.manifestCalls) slept=$($net.slept) $out"
Ok '...and each failed try is said on the console' (([regex]::Matches($out, 'manifest read failed \(attempt \d of 3\)')).Count -eq 2)

Reset-World; $net.manifest = Manifest; $net.manifestFails = 3
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a manifest read that fails three times: NOT ready, skip prepare_failed' (-not $cbReady -and $cbSkip.code -eq 'prepare_failed' -and $net.manifestCalls -eq 3) "$($cbSkip.code) calls=$($net.manifestCalls)"
Ok '...the reason names the step and the error' ($cbSkip.reason -match '^the manifest read failed: ' -and $cbSkip.reason -match 'timed out') $cbSkip.reason
Ok '...and no ini holding the key is left behind' (-not (Test-Path (Join-Path $binDirWin 'commban.ini')))

Reset-World; $net.manifest = [pscustomobject]@{ version = '1.2.0'; files = @() }
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a manifest with no files[]: skip prepare_failed, naming it' (-not $cbReady -and $cbSkip.code -eq 'prepare_failed' -and $cbSkip.reason -match 'no files\[\]') $cbSkip.reason

Reset-World; $net.manifest = Manifest; $net.downloadFails = 3
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a download that fails three times: skip prepare_failed, naming the file' (-not $cbReady -and $cbSkip.code -eq 'prepare_failed' -and $cbSkip.reason -match '^the download of commban\.dll failed: ' -and $net.downloadCalls -eq 3) $cbSkip.reason

Reset-World; $net.manifest = Manifest; $net.downloadFails = 1
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a download that fails ONCE is retried and the boot injects' ($cbReady -and $null -eq $cbSkip -and $net.downloadCalls -eq 2)

Reset-World; $net.manifest = Manifest; $net.bytes = 'TAMPERED'
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a download whose sha does not match: skip sha_mismatch, nothing placed' (-not $cbReady -and $cbSkip.code -eq 'sha_mismatch' -and -not (Test-Path (Join-Path $binDirWin 'commban.dll')) -and $cbSkip.reason -match '1 of 1 downloaded file\(s\) failed sha256 against manifest v1\.2\.0') $cbSkip.reason

Reset-World; $net.manifest = Manifest 'other.dll'
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a manifest that does not carry commban.dll: skip dll_missing, naming what it carried' (-not $cbReady -and $cbSkip.code -eq 'dll_missing' -and $cbSkip.reason -match 'other\.dll') $cbSkip.reason

Reset-World; $net.manifest = Manifest; $phsk = ''
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'no key: skip no_key, and no ini is written' (-not $cbReady -and $cbSkip.code -eq 'no_key' -and -not (Test-Path (Join-Path $binDirWin 'commban.ini'))) $cbSkip.reason

Reset-World; $net.manifest = Manifest
$null = Invoke-Expression $decide 6>&1 | Out-String
$net.manifestCalls = 0; $net.manifestFails = 3; $cbSkip = $null
$out = Invoke-Expression $decide 6>&1 | Out-String
Ok 'a DLL left in place by the last boot is NOT injected when this boot cannot read the manifest' (-not $cbReady -and $cbSkip.code -eq 'prepare_failed')
Remove-Item Function:\Invoke-RestMethod, Function:\Save-Download, Function:\Start-Sleep

# ---- B: the report, over real HTTP ----
Write-Host "`nB - the plane is told, by name, and the post is never ack-once"
$port = 0
$listener = $null
foreach ($try in 1..20) {
    $port = Get-Random -Minimum 20000 -Maximum 60000
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    try { $listener.Start(); break } catch { $listener = $null }
}
if (-not $listener) { throw 'could not open a local listener' }
$env:PRIMAL_DATA_BASE = "http://localhost:$port"
$env:PRIMAL_INJECT_WATCH_S = '1'
$volRoot = 'C:\feathers\volumes\test-uuid'
# Take one request (or $null after $waitMs), answer it with $status.
function Take([int]$status, [int]$waitMs = 30000) {
    $t = $listener.GetContextAsync()
    if (-not $t.Wait($waitMs)) { return $null }
    $ctx = $t.Result
    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd()
    $seen = @{ method = $ctx.Request.HttpMethod; path = $ctx.Request.Url.AbsolutePath; auth = $ctx.Request.Headers['Authorization']; type = $ctx.Request.ContentType; json = ($body | ConvertFrom-Json) }
    $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true,"recorded":true,"alert":"deferred","paged":false}')
    $ctx.Response.StatusCode = $status; $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
    return $seen
}
function Drain([int]$waitMs = 20000) {
    if ($script:cbSkipJob) { [void](Wait-Job $script:cbSkipJob -Timeout ([int]($waitMs / 1000))) }
    return (Show-SkipReport 6>&1 | Out-String)
}
function Read-Hist { if (Test-Path (Join-Path $tmpl 'primal-commban-history.log')) { return (Get-Content (Join-Path $tmpl 'primal-commban-history.log') -Raw) } else { return '' } }
Invoke-Expression $drain

Reset-World
$cbOn = $true; $cbReady = $false; $cbSkip = @{ code = 'prepare_failed'; reason = 'the manifest read failed: The operation has timed out.' }
$t0 = Get-Date
$out = Invoke-Expression $report 6>&1 | Out-String
$seen = Take 200
$took = ((Get-Date) - $t0).TotalSeconds
Ok 'a not-injecting boot POSTs /v1/boot-report with the server''s own key' ($seen -and $seen.method -eq 'POST' -and $seen.path -eq '/v1/boot-report' -and $seen.auth -eq "Bearer $KEY" -and $seen.type -like 'application/json*') ($seen | Out-String)
Ok '...inside a minute of deciding' ($took -lt 60) "$took s"
Ok '...as a FAILED inject verdict an older plane already accepts' ($seen.json.stage -eq 'inject' -and $seen.json.ok -eq $false -and $seen.json.dll -eq 'commban.dll' -and $seen.json.game -eq 'evrima' -and $seen.json.attempts -eq 0)
Ok '...that NAMES why: the code, and the reason in words' ($seen.json.skipped -eq 'prepare_failed' -and $seen.json.reason -eq 'not injected (prepare_failed): the manifest read failed: The operation has timed out.') $seen.json.reason
Ok '...and carries no key in its body' (($seen.json | ConvertTo-Json -Compress) -notmatch 'phsk_')
Ok 'the console says it loudly' ($out -match 'COMM-BAN DLL NOT INJECTED THIS BOOT \(prepare_failed\)')
$drained = Drain
Ok 'the acknowledged post ends the job and is said' ($drained -match 'reported to the plane on try 1 \(alert=deferred, paged=False\)' -and $null -eq $cbSkipJob) $drained
$h = Read-Hist
Ok 'the history keeps the reason and the outcome' ($h -match 'NOT INJECTED \(prepare_failed\): the manifest read failed' -and $h -match 'skip report: reported to the plane on try 1') $h

Reset-World
$cbOn = $true; $cbReady = $false; $cbSkip = @{ code = 'sha_mismatch'; reason = '1 of 1 downloaded file(s) failed sha256 against manifest v1.2.0' }
$null = Invoke-Expression $report 6>&1 | Out-String
$first = Take 503
$second = Take 200
Ok 'a post the plane could not record (503) is sent AGAIN' ($first -and $second -and $second.json.skipped -eq 'sha_mismatch')
$drained = Drain
Ok '...and both tries are said' ($drained -match 'REPORT FAILED' -and $drained -match 'reported to the plane on try 2') $drained

Reset-World
$cbOn = $true; $cbReady = $false; $cbSkip = @{ code = 'dll_missing'; reason = 'commban.dll is not on disk' }
$null = Invoke-Expression $report 6>&1 | Out-String
$first = Take 400
$again = Take 200 4000
$drained = Drain
Ok 'a post the plane REFUSES (400) is not retried, and says so' ($first -and $null -eq $again -and $drained -match 'REPORT REFUSED by the plane \(HTTP 400\) on try 1 - not retried') $drained

Reset-World
$cbOn = $true; $cbReady = $false; $phsk = ''; $cbSkip = @{ code = 'no_key'; reason = 'PHSK_KEY is missing' }
$out = Invoke-Expression $report 6>&1 | Out-String
Ok 'no key: no job, and both the console and the history say it was NOT reported' ($null -eq $cbSkipJob -and $out -match 'NOT REPORTED off-box' -and (Read-Hist) -match 'not reported off-box: no PHSK_KEY')
Ok '...and nothing reached the plane' ($null -eq (Take 200 2500))

Reset-World
$cbOn = $false; $cbReady = $false; $cbSkip = $null
$out = Invoke-Expression $report 6>&1 | Out-String
Ok 'off: no job, no banner, one history line' ($null -eq $cbSkipJob -and $out -notmatch 'NOT INJECTED' -and (Read-Hist) -match 'off \(PRIMAL_COMMBAN != 1\)')

Reset-World
$cbOn = $true; $cbReady = $true; $cbSkip = $null; $cm = [pscustomobject]@{ version = '1.2.0' }
$out = Invoke-Expression $report 6>&1 | Out-String
Ok 'armed and ready: no skip report (the verify job owns the verdict)' ($null -eq $cbSkipJob -and $out -notmatch 'NOT INJECTED' -and (Read-Hist) -match 'armed v1\.2\.0: verify\+heal started')
Ok '...and nothing reached the plane' ($null -eq (Take 200 2500))

Reset-World
$cbOn = $false
$null = Invoke-Expression $report 6>&1 | Out-String
1..260 | ForEach-Object { Add-CommbanHistory "line $_" }
$kept = @(Get-Content (Join-Path $tmpl 'primal-commban-history.log'))
Ok 'the history is capped at 200 lines, newest kept' ($kept.Count -eq 200 -and $kept[-1] -match 'line 260$') "$($kept.Count)"

$listener.Stop()
Get-Job -Name primal-commban-skip -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nnoinject: $pass passed, $fail failed"
if ($fail) { exit 1 }
