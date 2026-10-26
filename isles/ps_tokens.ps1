# Writes what PowerShell's own parser sees in a script, as JSON, for
# strip_comments_test.py: parse errors, comment tokens, and every other token
# (runs of newlines collapsed to one, since dropping a comment line removes one).
param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Out)
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
$comments = New-Object System.Collections.Generic.List[object]
$code = New-Object System.Collections.Generic.List[string]
$lastNewLine = $false
foreach ($t in $tokens) {
    if ($t.Kind -eq 'Comment') {
        $comments.Add(@{ line = $t.Extent.StartLineNumber; text = $t.Text })
        continue
    }
    if ($t.Kind -eq 'NewLine') {
        if ($lastNewLine) { continue }
        $lastNewLine = $true
        $code.Add('NewLine')
        continue
    }
    $lastNewLine = $false
    $code.Add("$($t.Kind):$($t.Text)")
}
$result = @{
    errors   = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" })
    comments = $comments.ToArray()
    tokens   = $code.ToArray()
}
[IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding $false))
