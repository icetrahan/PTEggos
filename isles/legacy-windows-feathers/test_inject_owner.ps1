# 09-25 hotfix acceptance - the boot injector's owner rule (Test-OurOwner), lifted by AST out of the REAL
# wrappers (no copy that could drift). The 09-25 16:37Z case is here verbatim: the node ran 9900080's game as
# 'pt_d0e7cefe' (its volume uuid starts d0e7cefe) while the wrapper ran as the machine account 'NS1006204$',
# and the old one-user check refused the RIGHT pid.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_inject_owner.ps1
# Exit 0 = every case PASS, for both the Legacy and the Evrima wrapper.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrappers = @((Join-Path $here 'start-legacy.ps1'), (Join-Path $here '..\evrima-windows-feathers\start-evrima.ps1'))
$vol = 'C:\Pterodactyl\volumes\d0e7cefe-e503-4394-99d4-4f0d03bfd6d1'
$cases = @(
    @('pt_d0e7cefe', $vol, 'NS1006204$', $true,  '09-25: the node per-server user owns THIS volume''s game'),
    @('PT_D0E7CEFE', $vol, 'NS1006204$', $true,  'case-insensitive'),
    @('pt_a4d6e187', $vol, 'NS1006204$', $false, 'ANOTHER server''s per-server user - refused'),
    @('NS1006204$',  $vol, 'NS1006204$', $true,  'the wrapper''s own user'),
    @('someoneelse', $vol, 'NS1006204$', $false, 'a stranger - refused'),
    @('',            $vol, 'NS1006204$', $true,  'owner unread - not a refusal (volume identity holds)'),
    @('someoneelse', $vol, '',           $true,  'no USERNAME to compare - not a refusal (pre-fix semantics)')
)
$fail = 0
foreach ($w in $wrappers) {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $w), [ref]$tok, [ref]$err)
    if ($err.Count) { throw "$w does not parse: $($err[0].Message)" }
    foreach ($name in 'Get-VolumeUser', 'Test-OurOwner') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "$name not found in $w" }
        Invoke-Expression $fn.Extent.Text
    }
    foreach ($c in $cases) {
        $got = Test-OurOwner $c[0] $c[1] $c[2]
        $ok = ($got -eq $c[3])
        if (-not $ok) { $fail++ }
        '{0} {1,-6} {2}: owner={3} me={4} -> {5} (want {6})' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), (Split-Path $w -Leaf).Substring(6, 6), $c[4], $c[0], $c[2], $got, $c[3]
    }
    Remove-Item function:Test-OurOwner, function:Get-VolumeUser
}
if ($fail) { "FAILED: $fail case(s)"; exit 1 }
'ALL PASS'
