# Behaviour test for the two game-native lines start-evrima.ps1 renders from the panel's settings:
#   A  Game.ini   GlobalAISpawnLimit        <- mod_settings.aiMaxCount ("Most AI alive at once")
#   B  Engine.ini ti.TreeDestruction.Enabled <- mod_settings.treeKnockdownOn ("Tree knockdown")
# Runs the REAL lines lifted from the shipping wrapper, never a copy of them.
#   powershell -ExecutionPolicy Bypass -File isles/evrima-windows-feathers/test_treeaicap.ps1
param([string]$Wrapper = (Join-Path $PSScriptRoot 'start-evrima.ps1'))
$ErrorActionPreference = 'Stop'
$lines = Get-Content $Wrapper

function Lift([string]$from, [string]$to) {
    $a = ($lines | Select-String -SimpleMatch $from | Select-Object -First 1).LineNumber
    if (-not $a) { throw "anchor not found: $from" }
    $b = ($lines[($a-1)..($lines.Count-1)] | Select-String -SimpleMatch $to | Select-Object -First 1).LineNumber
    if (-not $b) { throw "end anchor not found: $to" }
    return ($lines[($a-1)..($a+$b-2)] -join "`n")
}
$blockA = Lift '# GlobalAISpawnLimit, the game''s own AI cap' '# --- AI LEARNING (#1099)'
$blockB = Lift '# Tree knockdown: the switch the pak reads' 'no Primal session block (mod disabled or no PHSK_KEY)'
$blockB = ($blockB -split "`n" | Select-Object -SkipLast 2) -join "`n"   # Lift keeps its end line: drop it and the branch's `} else {`

function Has($o, [string]$n) { return ($null -ne $o) -and ($null -ne $o.PSObject.Properties[$n]) }
$GTMPL = Get-Content (Join-Path $PSScriptRoot 'Game.ini.tmpl') -Raw
$ETMPL = Get-Content (Join-Path $PSScriptRoot 'Engine.ini.tmpl') -Raw
$pass = 0; $fail = 0
function Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "  FAIL $label $detail" }
}
function Count([string]$text, [string]$pattern) { return ([regex]::Matches($text, $pattern)).Count }
function Section([string]$ini, [string]$hdrRe) {
    return [regex]::Match($ini, "(?ms)^$hdrRe[^\n]*\n(.*?)(?=^\[|\z)").Groups[1].Value
}
$SESS = '\[/script/theisle\.tigamesession\]'
$CV = '\[ConsoleVariables\]'

function RunA($ms, [string]$mod = '1', [string]$key = 'phsk_test', [string]$tmpl = $GTMPL) {
    $env:ENABLE_PRIMAL_MOD = $mod; $script:phsk = $key; $script:ms = $ms; $script:gi = $tmpl
    $phsk = $script:phsk; $ms = $script:ms; $gi = $script:gi
    $out = Invoke-Expression $blockA 6>&1 | Out-String
    return @{ gi = $gi; out = $out }
}

Write-Host "A - GlobalAISpawnLimit from Most AI alive at once"
$cases = @(
    @{ n = '40 (the default)'; v = 40;     want = '40' },
    @{ n = '150';              v = 150;    want = '150' },
    @{ n = 'string "95"';      v = '95';   want = '95' },
    @{ n = '95.7 floors';      v = 95.7;   want = '95' },
    @{ n = '0 is never 0';     v = 0;      want = '1' },
    @{ n = '-3 is never 0';    v = -3;     want = '1' },
    @{ n = '330 (above the panel max) as stored'; v = 330; want = '330' }
)
foreach ($c in $cases) {
    $r = RunA ([pscustomobject]@{ aiMaxCount = $c.v })
    $body = Section $r.gi $SESS
    Ok "$($c.n): GlobalAISpawnLimit=$($c.want) in the session section" ($body -match "(?m)^GlobalAISpawnLimit=$($c.want)\r?$") $r.out
    Ok "$($c.n): exactly once" ((Count $r.gi '(?mi)^\s*GlobalAISpawnLimit\s*=') -eq 1)
    Ok "$($c.n): nothing else changed" ($r.gi.Replace("GlobalAISpawnLimit=$($c.want)`r`n", '') -eq $GTMPL)
    Ok "$($c.n): the boot says it" ($r.out -match "\(config\) Game.ini: GlobalAISpawnLimit=$($c.want) ")
}
$none = @(
    @{ n = 'mod off';                 ms = [pscustomobject]@{ aiMaxCount = 40 }; mod = '0'; key = 'phsk_test'; why = 'our mod is off' },
    @{ n = 'no key';                  ms = [pscustomobject]@{ aiMaxCount = 40 }; mod = '1'; key = '';          why = 'our mod is off' },
    @{ n = 'no plane config ($ms null)'; ms = $null;                             mod = '1'; key = 'phsk_test'; why = 'no plane config' },
    @{ n = 'block without the field'; ms = [pscustomobject]@{ treeKnockdownOn = $false }; mod = '1'; key = 'phsk_test'; why = 'no plane config' },
    @{ n = 'not a number';            ms = [pscustomobject]@{ aiMaxCount = 'abc' }; mod = '1'; key = 'phsk_test'; why = 'is not a number' }
)
foreach ($c in $none) {
    $r = RunA $c.ms $c.mod $c.key
    Ok "$($c.n): no line" ((Count $r.gi '(?mi)^\s*GlobalAISpawnLimit\s*=') -eq 0)
    Ok "$($c.n): Game.ini untouched" ($r.gi -eq $GTMPL)
    Ok "$($c.n): said why" ($r.out -match "GlobalAISpawnLimit not set - .*$([regex]::Escape($c.why))") $r.out
}
$hand = $GTMPL.Replace('AIDensity={{AIDensity}}', "AIDensity={{AIDensity}}`r`nglobalaispawnlimit = 999")
$r = RunA ([pscustomobject]@{ aiMaxCount = 40 }) '1' 'phsk_test' $hand
Ok 'a hand-set line is replaced, never doubled' ((Count $r.gi '(?mi)^\s*GlobalAISpawnLimit\s*=') -eq 1 -and $r.gi -notmatch '999')
$r = RunA ([pscustomobject]@{ aiMaxCount = 40 }) '1' 'phsk_test' ($GTMPL.Replace('[/script/theisle.tigamesession]', '[/script/theisle.other]'))
Ok 'no session section: said, not silent' ($r.out -match 'WARNING no \[/script/theisle.tigamesession\] section - GlobalAISpawnLimit NOT set')
Ok '...and nothing was added' ((Count $r.gi '(?mi)^\s*GlobalAISpawnLimit\s*=') -eq 0)

Write-Host "B - ti.TreeDestruction.Enabled from Tree knockdown"
function RunB([string]$tree, [string]$tmpl = $ETMPL) {
    $pakExtra = [ordered]@{ TreeKnockdownOn = $tree }; $eng = $tmpl
    $out = Invoke-Expression $blockB 6>&1 | Out-String
    return @{ eng = $eng; out = $out }
}
$r = RunB 'False'
$cv = Section $r.eng $CV
Ok 'off: the line is in [ConsoleVariables]' ($cv -match '(?m)^ti\.TreeDestruction\.Enabled=0\r?$') $r.out
Ok 'off: exactly once in the file' ((Count $r.eng '(?mi)^\s*ti\.TreeDestruction\.Enabled\s*=') -eq 1)
Ok 'off: the streaming cvars kept' ($cv -match 'wp\.Runtime\.EnableServerStreaming=1' -and $cv -match 'wp\.Runtime\.EnableServerStreamingOut=1')
Ok 'off: nothing else changed' ($r.eng.Replace("ti.TreeDestruction.Enabled=0`r`n", '') -eq $ETMPL)
Ok 'off: the boot says it' ($r.out -match 'ti\.TreeDestruction\.Enabled=0 \(Tree knockdown off')
foreach ($on in @('True', 'true')) {
    $r = RunB $on
    Ok "on ($on): no line" ((Count $r.eng '(?mi)ti\.TreeDestruction') -eq 0)
    Ok "on ($on): Engine.ini untouched" ($r.eng -eq $ETMPL)
    Ok "on ($on): the boot says it" ($r.out -match 'tree knockdown on \(the game')
}
$hand = $ETMPL.Replace("wp.Runtime.EnableServerStreamingOut=1", "wp.Runtime.EnableServerStreamingOut=1`r`nti.treedestruction.enabled = 1")
$r = RunB 'False' $hand
Ok 'off over a hand-set =1: one line, =0' ((Count $r.eng '(?mi)^\s*ti\.TreeDestruction\.Enabled\s*=') -eq 1 -and $r.eng -match '(?m)^ti\.TreeDestruction\.Enabled=0')
$r = RunB 'True' $hand
Ok 'on over a hand-set line: removed (the switch owns it)' ((Count $r.eng '(?mi)ti\.TreeDestruction') -eq 0)
$r = RunB 'False' ($ETMPL.Replace('[ConsoleVariables]', '[SomethingElse]'))
Ok 'no [ConsoleVariables]: said, not silent' ($r.out -match 'WARNING no \[ConsoleVariables\] section - tree knockdown NOT turned off')
Ok '...and nothing was added' ((Count $r.eng '(?mi)ti\.TreeDestruction') -eq 0)

Write-Host "C - placement"
$all = $lines -join "`n"
$iA = $all.IndexOf('# GlobalAISpawnLimit, the game''s own AI cap'); $iW = $all.IndexOf("Set-Content -Path (Join-Path `$cfgDir 'Game.ini')")
Ok 'the cap is set before Game.ini is written' ($iA -gt 0 -and $iW -gt $iA)
$iB = $all.IndexOf('# Tree knockdown: the switch the pak reads'); $iMod = $all.IndexOf("if (`$env:ENABLE_PRIMAL_MOD -eq '1' -and `$phsk) {`n    `$dataBase")
$iE = $all.IndexOf("[System.IO.File]::WriteAllText((Join-Path `$cfgDir 'Engine.ini')")
Ok 'the tree line is inside the mod-on session branch, before Engine.ini is written' ($iMod -gt 0 -and $iB -gt $iMod -and $iE -gt $iB)
$fallback = [regex]::Match($all, "(?m)^\s*TreeKnockdownOn = '(\w+)'").Groups[1].Value
Ok 'with no plane config the wrapper falls back to tree knockdown on (the game''s default)' ($fallback -eq 'True') "fallback '$fallback'"

Remove-Item Env:ENABLE_PRIMAL_MOD -ErrorAction SilentlyContinue
Write-Host ("{0} {1} passed, {2} failed" -f $(if ($fail) { 'FAIL' } else { 'PASS' }), $pass, $fail)
if ($fail) { exit 1 }
