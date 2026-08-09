# Synth test for the Primal DLL mod delivery step (download-by-version + sha256 verify).
# Mirrors the download block in _primal/start-legacy.ps1, run against the LIVE R2 manifest.
$ErrorActionPreference = 'Stop'
$fails = @(); $n = 0
function Check($cond, $msg) { $script:n++; if (-not $cond) { $script:fails += $msg } }

$primalDir = Join-Path $env:TEMP ("primaldlltest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $primalDir -Force | Out-Null
$primalDll = Join-Path $primalDir 'LegacyMod.dll'
$primalVerFile = Join-Path $primalDir 'primal-mod.version'
$manifestUrl = 'https://pub-fb6fdcc2ce914775ba41c9813f80dc10.r2.dev/primal-mod/latest.json'

function Sync-Dll {
    $ProgressPreference = 'SilentlyContinue'
    $m = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 20
    $haveVer = if (Test-Path $primalVerFile) { (Get-Content $primalVerFile -Raw).Trim() } else { '' }
    if ($m.version -ne $haveVer -or -not (Test-Path $primalDll)) {
        Invoke-WebRequest -Uri $m.dll_url -OutFile $primalDll -UseBasicParsing
        $sha = (Get-FileHash $primalDll -Algorithm SHA256).Hash.ToLower()
        if ($sha -ne ("" + $m.sha256).ToLower()) { Remove-Item $primalDll -Force; return @{ action = 'mismatch'; m = $m } }
        Set-Content -Path $primalVerFile -Value $m.version -Encoding ascii
        return @{ action = 'downloaded'; m = $m; sha = $sha }
    }
    return @{ action = 'uptodate'; m = $m }
}

# Run 1: fresh (nothing local) -> downloads + verifies
$r1 = Sync-Dll
Check ($r1.action -eq 'downloaded') "run1 downloads (got '$($r1.action)')"
Check (Test-Path $primalDll) "run1 wrote DLL"
Check ((Get-Item $primalDll).Length -eq $r1.m.size) "run1 DLL size matches manifest ($($r1.m.size))"
Check ($r1.sha -eq ("" + $r1.m.sha256).ToLower()) "run1 sha256 matches manifest"
Check ((Get-Content $primalVerFile -Raw).Trim() -eq $r1.m.version) "run1 pinned version '$($r1.m.version)'"

# Run 2: same version already local -> no re-download
$r2 = Sync-Dll
Check ($r2.action -eq 'uptodate') "run2 is a no-op (got '$($r2.action)')"

# Run 3: simulate a published newer version -> re-downloads
Set-Content -Path $primalVerFile -Value '0.0.1-old' -Encoding ascii
$r3 = Sync-Dll
Check ($r3.action -eq 'downloaded') "run3 re-downloads on version change (got '$($r3.action)')"
Check ((Get-Content $primalVerFile -Raw).Trim() -eq $r3.m.version) "run3 re-pins to manifest version"

# Run 4: DLL deleted but version file present -> heals (re-download)
Remove-Item $primalDll -Force
$r4 = Sync-Dll
Check ($r4.action -eq 'downloaded') "run4 heals a missing DLL (got '$($r4.action)')"

Remove-Item $primalDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "ran $n assertions"
if ($fails.Count) { Write-Output "FAIL:"; $fails | ForEach-Object { Write-Output "  - $_" }; exit 1 }
Write-Output "ALL PASS - DLL delivery: fresh download, sha256 verify, version pin, no-op re-run, version-change re-download, missing-DLL self-heal"
