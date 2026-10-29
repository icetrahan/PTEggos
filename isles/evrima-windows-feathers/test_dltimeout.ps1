# Behaviour test for the sigbypass + pak downloads in start-evrima.ps1 (BUGS #4275).
# Runs the REAL lines lifted from the shipping wrapper, in a child powershell, against a local
# TCP server that can answer, never answer, stall mid-body or trickle. A child still running
# past its budget is killed and counted as a hung boot.
#   powershell -NoProfile -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_dltimeout.ps1
$ErrorActionPreference = 'Stop'
$lines = Get-Content (Join-Path $PSScriptRoot 'start-evrima.ps1')

function Lift([string]$from, [string]$to, [int]$dropLast) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { throw "anchor not found: $from" }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { throw "end anchor not found: $to" }
    return (($lines[($a-1)..($a+$b-2)] | Select-Object -SkipLast $dropLast) -join "`n")
}
$envOr = Lift 'function EnvOr(' 'function EnvOr(' 0
$dbgFn = Lift 'function Dbg(' 'function Dbg(' 0
$block = Lift '$paksDir    = Join-Path $game' '# PRIMAL COMM-BAN DLL' 2
Write-Host "lifted: $(($block -split "`n").Count) lines (sigbypass + pak)`n"

# Seconds the child is given before it counts as hung. The child's own limits are 2 s stall / 6 s whole file.
$BUDGET = 25
$STALL = 2; $MAX = 6

$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  ok   $label" } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}
function Sha([byte[]]$b) {
    $s = [Security.Cryptography.SHA256]::Create()
    return (-join ($s.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }))
}
function Bytes([string]$t) { return [Text.Encoding]::ASCII.GetBytes($t) }

# ---- the server: routes /sb.json, /pak.json, /f/<mode>/<name> (mode = ok | silent | stall | trickle) ----
$state = [hashtable]::Synchronized(@{ sb = '{}'; pak = '{}'; files = @{}; held = (New-Object System.Collections.ArrayList); hits = (New-Object System.Collections.ArrayList) })
$listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$base = "http://127.0.0.1:$port"
$serve = {
    param($listener, $state)
    function Send($s, [string]$head, [byte[]]$body) {
        $h = [Text.Encoding]::ASCII.GetBytes($head)
        $s.Write($h, 0, $h.Length); if ($body) { $s.Write($body, 0, $body.Length) }; $s.Flush()
    }
    while ($true) {
        try { $c = $listener.AcceptTcpClient() } catch { return }
        try {
            $s = $c.GetStream()
            $rd = New-Object IO.StreamReader($s, [Text.Encoding]::ASCII, $false, 1, $true)
            $req = $rd.ReadLine()
            while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq '') { break } }
            $path = ($req -split ' ')[1]
            [void]$state.hits.Add($path)
            if ($path -eq '/sb.json' -or $path -eq '/pak.json') {
                $b = [Text.Encoding]::ASCII.GetBytes($(if ($path -eq '/sb.json') { $state.sb } else { $state.pak }))
                Send $s "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n`r`n" $b
                $c.Close(); continue
            }
            $null, $null, $mode, $name = $path -split '/'
            $body = $state.files[$name]
            if ($mode -eq 'ok') {
                Send $s "HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n" $body
                $c.Close(); continue
            }
            if ($mode -eq 'silent') { [void]$state.held.Add($c); continue }
            Send $s "HTTP/1.1 200 OK`r`nContent-Length: $($body.Length + 100000)`r`nConnection: close`r`n`r`n" ([byte[]]($body[0..9]))
            if ($mode -eq 'stall') { [void]$state.held.Add($c); continue }
            # trickle: one byte every 300 ms, never finishing, until the client hangs up
            for ($i = 0; $i -lt 400; $i++) { Start-Sleep -Milliseconds 300; $s.WriteByte(65); $s.Flush() }
            $c.Close()
        } catch { try { $c.Close() } catch {} }
    }
}
$ps = [powershell]::Create()
[void]$ps.AddScript($serve).AddArgument($listener).AddArgument($state)
$srv = $ps.BeginInvoke()

$work = Join-Path $env:TEMP ('dlt_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Manifest([string]$ver, [object[]]$files) {
    $list = @($files | ForEach-Object {
        $script:state.files[$_.name] = $_.bytes
        [ordered]@{ name = $_.name; url = "$base/f/$($_.mode)/$($_.name)"; sha256 = (Sha $_.bytes); size = $_.bytes.Length }
    })
    return (@{ version = $ver; build = "BUILD $ver"; files = $list } | ConvertTo-Json -Depth 5)
}
function F([string]$name, [string]$text, [string]$mode = 'ok') { return @{ name = $name; bytes = (Bytes $text); mode = $mode } }

# One boot of the lifted block. $have = files already on disk (relative path -> text). Returns what it saw.
function Run-Boot([string]$label, [hashtable]$have) {
    $root = Join-Path $work ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $game = Join-Path $root 'server'; $tmpl = Join-Path $root '_primal'
    New-Item -ItemType Directory -Force -Path $game, $tmpl | Out-Null
    foreach ($k in $have.Keys) {
        $p = Join-Path $root $k
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, $have[$k], [Text.Encoding]::ASCII)
    }
    $child = Join-Path $root 'boot.ps1'
    $prelude = @(
        "`$ErrorActionPreference = 'Stop'",
        "`$game = '$game'; `$tmpl = '$tmpl'",
        "`$script:dbg = Join-Path `$tmpl 'wrapper-debug.log'",
        "`$env:ENABLE_PRIMAL_MOD = '1'; `$env:PHSK_KEY = 'x'",
        "`$env:PRIMAL_SIGBYPASS_MANIFEST = '$base/sb.json'; `$env:PRIMAL_MOD_MANIFEST = '$base/pak.json'",
        "`$env:PRIMAL_DL_STALL_S = '$STALL'; `$env:PRIMAL_DL_MAX_S = '$MAX'"
    ) -join "`n"
    Set-Content -Path $child -Value ($prelude + "`n" + $envOr + "`n" + $dbgFn + "`n" + $block + "`n'BLOCK-DONE'") -Encoding ascii
    $out = Join-Path $root 'out.txt'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $child) -RedirectStandardOutput $out -RedirectStandardError "$out.err" -NoNewWindow -PassThru
    $done = $p.WaitForExit($BUDGET * 1000)
    if (-not $done) { try { $p.Kill() } catch {}; [void]$p.WaitForExit(5000) }
    $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    foreach ($c in @($state.held)) { try { $c.Close() } catch {} }; $state.held.Clear()
    $dbgLog = Join-Path $tmpl 'wrapper-debug.log'
    $r = @{
        root = $root; hung = (-not $done); secs = $secs
        out = $(if (Test-Path $out) { Get-Content $out -Raw } else { '' })
        dbg = $(if (Test-Path $dbgLog) { Get-Content $dbgLog -Raw } else { '' })
    }
    Write-Host "  [$label] $(if ($r.hung) { "HUNG - killed after $BUDGET s" } else { "returned in $secs s" })"
    if ($env:DLT_VERBOSE) { Write-Host $r.out; if (Test-Path "$out.err") { Write-Host (Get-Content "$out.err" -Raw) } }
    return $r
}
function Read-At($r, [string]$rel) { $p = Join-Path $r.root $rel; if (Test-Path $p) { return [IO.File]::ReadAllText($p) } else { return $null } }

$PAK = 'server\TheIsle\Content\Paks'
$WIN = 'server\TheIsle\Binaries\Win64'
$VER = '_primal\primal-pak.version'
$sbOld = @{ "$WIN\dsound.dll" = 'SB-DSOUND' }
$state.sb = Manifest 'sb1' @((F 'dsound.dll' 'SB-DSOUND'))
$oldPak = @{ "$PAK\pakchunk50-Windows_P.pak" = 'OLD-PAK-BYTES'; "$PAK\pakchunk50-Windows_P.ucas" = 'OLD-UCAS-BYTES'; $VER = '173' }

foreach ($mode in @('silent', 'stall', 'trickle')) {
    Write-Host "`nA/$mode - the pak server $(switch ($mode) { 'silent' { 'never answers' } 'stall' { 'sends headers + 10 bytes, then nothing' } 'trickle' { 'sends one byte every 300 ms, forever' } })"
    $state.pak = Manifest '174' @((F 'pakchunk50-Windows_P.pak' 'NEW-PAK-BYTES-0123456789'), (F 'pakchunk50-Windows_P.ucas' 'NEW-UCAS-BYTES-0123456789' $mode))
    $state.hits.Clear()
    $r = Run-Boot $mode ($sbOld + $oldPak)
    Ok "the wrapper really asked for the $mode file" ($state.hits -contains "/f/$mode/pakchunk50-Windows_P.ucas") "hits=$($state.hits -join ',')"
    Ok "the step returns before the $BUDGET s budget" (-not $r.hung) "(hung)"
    Ok "the step returns within the stall/whole-file limit (+ startup)" ($r.secs -le ($MAX + 10)) "($($r.secs) s)"
    Ok "the block runs to its end" ($r.out -match 'BLOCK-DONE')
    Ok "the old .pak is untouched" ((Read-At $r "$PAK\pakchunk50-Windows_P.pak") -eq 'OLD-PAK-BYTES')
    Ok "the old .ucas is untouched" ((Read-At $r "$PAK\pakchunk50-Windows_P.ucas") -eq 'OLD-UCAS-BYTES')
    Ok "the version record still says the old pak" ((Read-At $r $VER) -match '^173')
    Ok "wrapper-debug.log names the file that timed out and the pak in use" ($r.dbg -match 'pakchunk50-Windows_P\.ucas.*timed out.*previous pak 173 stays in use') "dbg=[$($r.dbg.Trim())]"
}

Write-Host "`nB - no pak on disk yet, and the download stalls"
$state.pak = Manifest '174' @((F 'pakchunk50-Windows_P.pak' 'NEW-PAK-BYTES-0123456789' 'stall'))
$r = Run-Boot 'first-boot stall' $sbOld
Ok "the step returns before the budget" (-not $r.hung)
Ok "no partial pak is left in Paks" (-not (Test-Path (Join-Path $r.root "$PAK\pakchunk50-Windows_P.pak")))
Ok "wrapper-debug.log says there is no previous pak" ($r.dbg -match 'pakchunk50-Windows_P\.pak.*timed out.*no previous pak') "dbg=[$($r.dbg.Trim())]"

Write-Host "`nC - the sigbypass file stalls; the old one stays"
$state.sb = Manifest 'sb2' @((F 'dsound.dll' 'SB-DSOUND-NEW' 'stall'))
$state.pak = Manifest '173' @((F 'pakchunk50-Windows_P.pak' 'OLD-PAK-BYTES'), (F 'pakchunk50-Windows_P.ucas' 'OLD-UCAS-BYTES'))
$r = Run-Boot 'sigbypass stall' ($sbOld + $oldPak)
Ok "the step returns before the budget" (-not $r.hung)
Ok "the old dsound.dll is untouched" ((Read-At $r "$WIN\dsound.dll") -eq 'SB-DSOUND')
Ok "no .download temp file is left" (-not (Test-Path (Join-Path $r.root "$WIN\dsound.dll.download")))
Ok "the pak check still ran after it" ($r.out -match '\(primal-pak\) up to date')
Ok "wrapper-debug.log names the sigbypass file" ($r.dbg -match 'dsound\.dll.*timed out') "dbg=[$($r.dbg.Trim())]"

Write-Host "`nD - everything answers: the new pak is placed (the download itself works)"
$state.sb = Manifest 'sb1' @((F 'dsound.dll' 'SB-DSOUND'))
$state.pak = Manifest '174' @((F 'pakchunk50-Windows_P.pak' 'NEW-PAK-BYTES-0123456789'), (F 'pakchunk50-Windows_P.ucas' 'NEW-UCAS-BYTES-0123456789'))
$r = Run-Boot 'all ok' $oldPak
Ok "the step returns before the budget" (-not $r.hung)
Ok "the new .pak is placed" ((Read-At $r "$PAK\pakchunk50-Windows_P.pak") -eq 'NEW-PAK-BYTES-0123456789')
Ok "the new .ucas is placed" ((Read-At $r "$PAK\pakchunk50-Windows_P.ucas") -eq 'NEW-UCAS-BYTES-0123456789')
Ok "the sigbypass file is placed" ((Read-At $r "$WIN\dsound.dll") -eq 'SB-DSOUND')
Ok "the version record moves to 174" ((Read-At $r $VER) -match '^174')
Ok "no timeout line is written" ($r.dbg -notmatch 'timed out') "dbg=[$($r.dbg.Trim())]"

$listener.Stop(); try { [void]$ps.EndInvoke($srv) } catch {}; $ps.Dispose()
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$pass passed, $fail failed"
if ($fail) { exit 1 }
