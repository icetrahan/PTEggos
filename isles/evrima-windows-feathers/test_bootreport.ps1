# Behaviour test: a boot that leaves the signature bypass out, or stops before launch, tells the
# plane by name (BUGS #4288). Runs the REAL lines lifted from the shipping wrapper; the plane is a
# local HttpListener and the report goes to it over real HTTP.
#   powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_bootreport.ps1
$ErrorActionPreference = 'Stop'
$lines = Get-Content (Join-Path $PSScriptRoot 'start-evrima.ps1')

$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  ok   $label" } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}
# A missing anchor is a failed check, not a crash, so the wrapper this test predates reads as red.
function Lift([string]$from, [string]$to, [int]$dropLast) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { Ok "anchor present: $from" $false; return '$null = 0' }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { Ok "end anchor present: $to" $false; return '$null = 0' }
    return (($lines[($a-1)..($a+$b-2)] | Select-Object -SkipLast $dropLast) -join "`n")
}
$envOr     = Lift 'function EnvOr(' 'function EnvOr(' 0
$helpers   = Lift '# BOOT REPORTS' '$binDirWin  = Join-Path $game' 1
$sigbypass = Lift '$binDirWin  = Join-Path $game' '$pakManifestUrl = EnvOr' 2
$exeCheck  = Lift '$exe = Join-Path $game ''TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe''' '# Multihome:' 1
$drain     = Lift 'function Show-BootReports {' '$pos = 0' 1
Invoke-Expression $envOr

# ---- the plane ----
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
$pending = $null
# Take one request (or $null after $waitMs), answer it with $status and $answer.
function Take([int]$status, [int]$waitMs = 20000, [string]$answer = '{"ok":true,"recorded":true,"alert":"deferred","paged":false}') {
    if (-not $script:pending) { $script:pending = $listener.GetContextAsync() }
    if (-not $script:pending.Wait($waitMs)) { return $null }
    $ctx = $script:pending.Result; $script:pending = $null
    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd()
    $seen = @{ method = $ctx.Request.HttpMethod; path = $ctx.Request.Url.AbsolutePath; auth = $ctx.Request.Headers['Authorization']; raw = $body; json = ($body | ConvertFrom-Json) }
    $bytes = [Text.Encoding]::UTF8.GetBytes($answer)
    $ctx.Response.StatusCode = $status; $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
    return $seen
}
function Drain([int]$waitS = 20) {
    foreach ($r in @($script:bootReports)) { if ($r -and $r.job) { [void](Wait-Job $r.job -Timeout $waitS) } }
    if (Get-Command Show-BootReports -ErrorAction SilentlyContinue) { return (Show-BootReports 6>&1 | Out-String) }
    return ''
}

# ---- the world the sigbypass block sees ----
$KEY = 'phsk_' + ('cd' * 24)
$work = Join-Path $env:TEMP ('br_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Reset-World {
    Get-Job -Name 'primal-report-*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    $script:game = Join-Path $work 'server'; $script:tmpl = Join-Path $work '_primal'
    New-Item -ItemType Directory -Force -Path $script:game, $script:tmpl | Out-Null
    $script:phsk = $KEY; $env:ENABLE_PRIMAL_MOD = '1'; $script:volRoot = $work
    $script:bootReports = @()
    $script:net = @{ manifestFails = 0; manifest = $null; downloadFails = 0; bytes = @{} }
}
# The marker paths are fixed by $tmpl, which every Reset-World keeps.
Reset-World
Invoke-Expression $helpers
Invoke-Expression $drain
function Sha([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return (-join ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }))
}
function Manifest {
    $script:net.bytes = @{ 'dsound.dll' = 'GOOD-DSOUND'; 'UniversalSigBypasser.asi' = 'GOOD-ASI' }
    return [pscustomobject]@{ version = '1.2'; files = @(
        [pscustomobject]@{ name = 'dsound.dll'; url = 'https://r2.test/dsound.dll'; sha256 = (Sha 'GOOD-DSOUND'); size = 11 },
        [pscustomobject]@{ name = 'UniversalSigBypasser.asi'; url = 'https://r2.test/UniversalSigBypasser.asi'; sha256 = (Sha 'GOOD-ASI'); size = 8 }) }
}
# Only the manifest GET and the file downloads are faked: the report posts from a job, which
# runs in its own process and so reaches the real cmdlet.
function Invoke-RestMethod { param([string]$Uri, [int]$TimeoutSec)
    if ($script:net.manifestFails -gt 0) { $script:net.manifestFails--; throw 'The operation has timed out.' }
    return $script:net.manifest
}
function Invoke-WebRequest { param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    if ($script:net.downloadFails -gt 0) { $script:net.downloadFails--; throw "The remote name could not be resolved: 'r2.test'" }
    $name = Split-Path $Uri -Leaf
    [IO.File]::WriteAllText($OutFile, $script:net.bytes[$name], [Text.Encoding]::ASCII)
}
$binOf = { Join-Path $game 'TheIsle\Binaries\Win64' }
$verOf = { Join-Path $tmpl 'primal-sigbypass.version' }

Write-Host "A - the bypass is placed: no report, the version is written"
Reset-World; $net.manifest = Manifest
$out = Invoke-Expression $sigbypass 6>&1 | Out-String
Ok 'both files placed' ((Test-Path (Join-Path (& $binOf) 'dsound.dll')) -and (Test-Path (Join-Path (& $binOf) 'UniversalSigBypasser.asi'))) $out
Ok 'the version file says 1.2' ((Test-Path (& $verOf)) -and (Get-Content (& $verOf)).Trim() -eq '1.2')
Ok 'nothing reaches the plane' ($null -eq (Take 200 2500))

Write-Host "`nB - a file that fails its sha256"
Reset-World; $net.manifest = Manifest; Set-Content -Path (& $verOf) -Value '1.1' -Encoding ascii
$net.bytes['UniversalSigBypasser.asi'] = 'TAMPERED'
$out = Invoke-Expression $sigbypass 6>&1 | Out-String
Ok 'the bad file is not placed' (-not (Test-Path (Join-Path (& $binOf) 'UniversalSigBypasser.asi')))
Ok 'the version file is NOT written (and the stale one is gone)' (-not (Test-Path (& $verOf))) $(if (Test-Path (& $verOf)) { Get-Content (& $verOf) })
Ok 'the console says the mod will not mount' ($out -match 'MOD PAK WILL NOT MOUNT') $out
$seen = Take 200
Ok 'the plane is told with the server''s own key' ($seen -and $seen.method -eq 'POST' -and $seen.path -eq '/v1/boot-report' -and $seen.auth -eq "Bearer $KEY")
Ok '...as a skipped inject the plane already reads: sha_mismatch' ($seen.json.stage -eq 'inject' -and $seen.json.ok -eq $false -and $seen.json.skipped -eq 'sha_mismatch' -and $seen.json.dll -eq 'UniversalSigBypasser.asi' -and $seen.json.game -eq 'evrima') $seen.raw
Ok '...naming the file' ($seen.json.reason -match 'UniversalSigBypasser\.asi' -and $seen.json.reason -match 'sha256') $seen.json.reason
Ok '...and no key in the body' ($seen.raw -notmatch 'phsk_')
$d = Drain
Ok 'the drained job says it was recorded' ($d -match 'recorded on try 1') $d
Ok 'a pending marker is left for the next good boot to clear' (Test-Path (Join-Path $tmpl 'primal-sigbypass-report.pending'))

Write-Host "`nC - the next boot places it: the plane is told it is back, the marker goes"
$net.manifest = Manifest
$out = Invoke-Expression $sigbypass 6>&1 | Out-String
$seen = Take 200
Ok 'an ok verdict for the same file' ($seen -and $seen.json.stage -eq 'inject' -and $seen.json.ok -eq $true -and $seen.json.dll -eq 'UniversalSigBypasser.asi' -and $null -eq $seen.json.skipped) $seen.raw
$d = Drain
Ok '...and the marker is gone once recorded' (-not (Test-Path (Join-Path $tmpl 'primal-sigbypass-report.pending'))) $d
$null = Invoke-Expression $sigbypass 6>&1 | Out-String
Ok 'a third, healthy boot sends nothing' ($null -eq (Take 200 2500))

Write-Host "`nD - the manifest or a download fails"
Reset-World; $net.manifest = Manifest; $net.manifestFails = 1
$out = Invoke-Expression $sigbypass 6>&1 | Out-String
$seen = Take 200
Ok 'a failed manifest read: skipped prepare_failed (a restart re-fetches)' ($seen -and $seen.json.ok -eq $false -and $seen.json.skipped -eq 'prepare_failed' -and $seen.json.reason -match 'timed out') $seen.raw
$null = Drain
Reset-World; $net.manifest = Manifest; $net.downloadFails = 1; Set-Content -Path (& $verOf) -Value '1.1' -Encoding ascii
$out = Invoke-Expression $sigbypass 6>&1 | Out-String
$seen = Take 200
Ok 'a failed download: skipped prepare_failed, naming the error' ($seen -and $seen.json.skipped -eq 'prepare_failed' -and $seen.json.reason -match 'could not be resolved') $seen.raw
Ok '...and no stale version file claims it is current' (-not (Test-Path (& $verOf)))
$null = Drain

Write-Host "`nE - the report is not ack-once"
Reset-World; $net.manifest = Manifest; $net.bytes['dsound.dll'] = 'TAMPERED'
$null = Invoke-Expression $sigbypass 6>&1 | Out-String
$first = Take 503
$second = Take 200
Ok 'a 503 is sent again' ($first -and $second -and $second.json.skipped -eq 'sha_mismatch')
$null = Drain
Reset-World; $net.manifest = Manifest; $net.bytes['dsound.dll'] = 'TAMPERED'
$null = Invoke-Expression $sigbypass 6>&1 | Out-String
$first = Take 200 20000 '{"ok":true}'
$second = Take 200
Ok 'a 200 that does not say recorded is sent again' ($first -and $second)
$null = Drain
Reset-World; $net.manifest = Manifest; $net.bytes['dsound.dll'] = 'TAMPERED'
$null = Invoke-Expression $sigbypass 6>&1 | Out-String
$first = Take 400
$again = Take 200 3000
$d = Drain
Ok 'a 400 is not retried, and says so' ($first -and $null -eq $again -and $d -match 'REFUSED by the plane \(HTTP 400\)') $d
Reset-World; $net.manifest = Manifest; $net.bytes['dsound.dll'] = 'TAMPERED'; $phsk = ''
$out = Invoke-Expression $sigbypass 6>&1 | Out-String
Ok 'no key: the console says it was NOT reported' ($out -match 'NOT reported off-box: no PHSK_KEY') $out
Ok '...and nothing reaches the plane' ($null -eq (Take 200 2500))
Reset-World; $net.manifest = Manifest; $net.bytes['dsound.dll'] = 'TAMPERED'; $env:ENABLE_PRIMAL_MOD = '0'
$null = Invoke-Expression $sigbypass 6>&1 | Out-String
Ok 'mod off: nothing reaches the plane' ($null -eq (Take 200 2500))
Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-WebRequest

Write-Host "`nF - the server binary is missing"
# The refusal posts before the stop, in line, so the check runs in a job and this side plays the plane.
function Start-ExeCheck {
    Start-Job -Name 'primal-test-exe' -ArgumentList $envOr, $helpers, $exeCheck, $game, $tmpl, $phsk, $env:PRIMAL_DATA_BASE -ScriptBlock {
        param($envOr, $helpers, $exeCheck, $game, $tmpl, $phsk, $base)
        $ErrorActionPreference = 'Stop'; $env:PRIMAL_DATA_BASE = $base; $env:PRIMAL_INJECT_WATCH_S = '1'
        Invoke-Expression $envOr; Invoke-Expression $helpers
        $out = ''
        try { Invoke-Expression $exeCheck 6>&1 | ForEach-Object { $out += "$_`n" }; $threw = '' } catch { $threw = "$_" }
        foreach ($r in @($script:bootReports)) { if ($r) { [void](Wait-Job $r.job -Timeout 20); $out += (Receive-Job $r.job | Out-String) } }
        @{ threw = $threw; out = $out }
    }
}
function Finish-ExeCheck($job) { [void](Wait-Job $job -Timeout 60); $r = Receive-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force; return $r }
Reset-World
$j = Start-ExeCheck
$seen = Take 200
$r = Finish-ExeCheck $j
Ok 'the start still stops' ($r.threw -match 'server binary missing') ($r | Out-String)
Ok 'the plane was told BEFORE the stop: a refused start' ($seen -and $seen.json.stage -eq 'start' -and $seen.json.ok -eq $false -and $seen.json.platform -eq 'windows' -and $seen.json.game -eq 'evrima' -and $seen.auth -eq "Bearer $KEY") $seen.raw
Ok '...with the code the plane already has an action for: binary_missing' ($seen.json.code -eq 'binary_missing' -and $seen.json.reason -match 'server binary missing') $seen.raw
Ok '...and the console says it was recorded' ($r.out -match 'refused start report: recorded on try 1') $r.out
Ok 'a refused marker is left' (Test-Path (Join-Path $tmpl 'boot-refused.pending'))
$exeDir = Join-Path $game 'TheIsle\Binaries\Win64'; New-Item -ItemType Directory -Force -Path $exeDir | Out-Null
Set-Content -Path (Join-Path $exeDir 'TheIsleServer-Win64-Shipping.exe') -Value 'x'
$j = Start-ExeCheck
$seen = Take 200
$r = Finish-ExeCheck $j
Ok 'the next boot that launches reports the start, clearing the page' (-not $r.threw -and $seen -and $seen.json.stage -eq 'start' -and $seen.json.ok -eq $true) "$($r.threw) $($seen.raw)"
Ok '...and the marker is gone once recorded' (-not (Test-Path (Join-Path $tmpl 'boot-refused.pending'))) $r.out
$j = Start-ExeCheck
$seen = Take 200 4000
$r = Finish-ExeCheck $j
Ok 'a normal launch sends nothing' (-not $r.threw -and $null -eq $seen) $seen.raw
Remove-Item (Join-Path $exeDir 'TheIsleServer-Win64-Shipping.exe')
$j = Start-ExeCheck
$first = Take 503; $second = Take 503; $third = Take 503; $fourth = Take 200 6000
$r = Finish-ExeCheck $j
Ok 'a plane that cannot record it: three tries, then the stop, saying NOT recorded' ($first -and $second -and $third -and $null -eq $fourth -and $r.threw -match 'server binary missing' -and $r.out -match 'NOT recorded after 3 tries: HTTP 503') $r.out
$phsk = ''
$j = Start-ExeCheck
$seen = Take 200 3000
$r = Finish-ExeCheck $j
Ok 'no key: the stop says it was NOT reported, and nothing is sent' ($null -eq $seen -and $r.threw -match 'server binary missing' -and $r.out -match 'NOT reported off-box: no PHSK_KEY') $r.out

$listener.Stop()
Get-Job -Name 'primal-*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nbootreport: $pass passed, $fail failed"
if ($fail) { exit 1 }
