param()

$ErrorActionPreference = 'Stop'
$basePath = "C:\Users\Victor\intersite-orchestrator\Scripts\Modules"
$files = Get-ChildItem -Path "$basePath\ORCHESTRATOR.*\Public\*.ps1" -Recurse | Sort-Object FullName

$stats = @{
    total        = 0
    skipped      = @()
    void         = @()
    bool         = @()
    pscustomobject = @()
    hashtable    = @()
    string       = @()
    stringArray  = @()
    array        = @()
    int          = @()
    error        = @()
}

function Get-ReturnTypeFromBody {
    param([string]$Content, [string]$FileName)

    # Check .OUTPUTS comment block first
    if ($Content -match '(?s)\.OUTPUTS\s*\n\s*(?:#\s*)?(.+?)(?:\n|$)') {
        $outDesc = $Matches[1].Trim()
        if ($outDesc -match '(?i)\b(BOOLEAN|BOOL|TRUE|FALSE)\b' -or $outDesc -match '(?i)\$true|\$false') {
            return '[bool]'
        }
        if ($outDesc -match '(?i)\b(PSCUSTOMOBJECT|OBJECT|CUSTOM OBJECT)\b' -or $outDesc -match '(?i)Outputs a custom object|PSCustomObject with') {
            return '[pscustomobject]'
        }
        if ($outDesc -match '(?i)\b(HASHTABLE|HASH TABLE|DICTIONARY)\b' -or $outDesc -match '(?i)^Hashtable') {
            return '[hashtable]'
        }
        if ($outDesc -match '(?i)\b(INTEGER|INT)\b' -or $outDesc -match '(?i)^\d+$') {
            return '[int]'
        }
        if ($outDesc -match '(?i)\b(STRING\[\]|ARRAY OF STRING|STRING ARRAY)\b') {
            return '[string[]]'
        }
        if ($outDesc -match '(?i)\b(STRING)\b') {
            return '[string]'
        }
        if ($outDesc -match '(?i)\b(ARRAY)\b') {
            return '[array]'
        }
        if ($outDesc -match '(?i)\b(NONE|NOTHING|VOID)\b') {
            return '[void]'
        }
    }

    # Extract function body (between first { and matching })
    $funcMatch = [regex]::Match($Content, '(?s)function\s+\w+\s*\{')
    if (-not $funcMatch.Success) {
        return $null
    }
    $bodyStart = $funcMatch.Index + $funcMatch.Length - 1  # position of {
    $depth = 1
    $i = $bodyStart + 1
    $len = $Content.Length
    while ($depth -gt 0 -and $i -lt $len) {
        switch ($Content[$i]) {
            '{' { $depth++ }
            '}' { $depth-- }
        }
        $i++
    }
    $body = $Content.Substring($bodyStart, $i - $bodyStart)

    # Check for throw-only functions (no return, only throw or Write-Host)
    $hasReturn = $body -match '(?m)^[^#]*\breturn\b'

    if (-not $hasReturn) {
        # Check if the body does anything that produces output on the pipeline
        $hasNonCommentCode = $body -replace '<#.*?#>', '' -replace '#.*$', '' -replace 'Write-(Host|SetupLog|Debug|Verbose|Warning|Information)\s', '' -replace 'Out-Null', '' -replace '\$null\s*=', '' -replace '\$null\s*\|', '' -replace 'Remove-Item.*-ErrorAction SilentlyContinue', '' -replace '^\s*$', '' | Where-Object { $_.Trim().Length -gt 0 }
        if (-not $hasReturn) {
            # But check if function adds to the pipeline via Write-Output or implicit output
            $hasPipelineOutput = $false
            # Functions that have cmdlet calls without capturing output might implicitly return
            # But for now, if there's no explicit return, and only Write-Host/Set-Item/Remove-Item calls, it's void
            $codeLines = $body -split "`n" | ForEach-Object { $_.Trim() } | Where-Object {
                $line = $_ -replace '<#.*?#>', '' -replace '#.*$', ''
                $line.Trim().Length -gt 0
            }
            # Filter out comments, Write-Host, Out-Null, $null assignments, etc.
            # If all lines are void-like, it's void
            return '[void]'
        }
    }

    # Look at return statements
    $returnStmts = [regex]::Matches($body, '(?m)return\s+(.+)$')
    if ($returnStmts.Count -eq 0) {
        # Objects may be emitted implicitly (not using return keyword)
        # Check for implicit output patterns
        $bodyClean = $body -replace '<#.*?#>', '' -replace '(?m)#.*$', ''
        if ($bodyClean -match '(?m)^[^#]*\bWrite-(Output|Host|SetupLog|Debug|Verbose|Warning|Information)\b') {
            # Some Write-Output might be used
        }
        return '[void]'
    }

    $types = @()
    foreach ($stmt in $returnStmts) {
        $retExpr = $stmt.Groups[1].Value.Trim()
        # Remove trailing whitespace or comment
        $retExpr = $retExpr -replace '\s*#.*$', ''
        $retExpr = $retExpr.Trim()

        # Empty return or $null
        if ($retExpr -eq '' -or $retExpr -eq '$null') {
            continue
        }

        # $true / $false
        if ($retExpr -match '^\$true$' -or $retExpr -match '^\$false$') {
            $types += '[bool]'
            continue
        }

        # Boolean expression patterns
        if ($retExpr -match '^\$null\s+-[a-z]+\s+' -or $retExpr -match '^\$.*?\s+-[a-z]+\s+\$' -or $retExpr -match '^-not\b' -or $retExpr -match '^\$.*?\s+-match\b' -or $retExpr -match '^\$.*?\s+-like\b' -or $retExpr -match '^\$.*?\s+-contains\b' -or $retExpr -match '^\$.*?\s+-and\b' -or $retExpr -match '^\$.*?\s+-or\b' -or $retExpr -match '^\(.*?\)\s+-[a-z]+') {
            $types += '[bool]'
            continue
        }

        # [pscustomobject]@{...}
        if ($retExpr -match '^\[pscustomobject\]@\{' -or $retExpr -match '^\[PSCustomObject\]\$\{' -or $retExpr -match '^\[pscustomobject\]@\(') {
            $types += '[pscustomobject]'
            continue
        }

        # Variable assigned from [pscustomobject]@{...}
        if ($retExpr -match '^\$\w+$') {
            # Check if this variable is assigned a pscustomobject literal earlier
            $varName = $retExpr
            $esc = [regex]::Escape($varName)
            $assignPattern = "(?ms)^\s*${esc}\s*=\s*\[pscustomobject\]@"
            if ($body -match $assignPattern) {
                $types += '[pscustomobject]'
                continue
            }
            $assignPattern2 = "(?ms)^\s*${esc}\s*=\s*\[PSCustomObject\]@"
            if ($body -match $assignPattern2) {
                $types += '[pscustomobject]'
                continue
            }
            # Check if variable assigned from another command that returns pscustomobject (hard to trace)
            # Fall through to later checks
        }

        # Literal hashtable @{...}
        if ($retExpr -match '^@\{' -or $retExpr -match '^@\(') {
            # Check if it's a hashtable (keys with =) vs array
            if ($retExpr -match '@\{' -and $retExpr -match '=') {
                $types += '[hashtable]'
            } else {
                $types += '[array]'
            }
            continue
        }

        # Quoted string
        if ($retExpr -match '^"' -or $retExpr -match "^'" -or $retExpr -match '^@".*?"@' -or $retExpr -match "^@'.*?'@") {
            $types += '[string]'
            continue
        }

        # Integer literal
        if ($retExpr -match '^-?\d+$') {
            $types += '[int]'
            continue
        }

        # [string] cast
        if ($retExpr -match '^\[string\]' -or $retExpr -match '^\[String\]') {
            $types += '[string]'
            continue
        }

        # [int] cast
        if ($retExpr -match '^\[int\]' -or $retExpr -match '^\[Int\]') {
            $types += '[int]'
            continue
        }

        # [string[]] cast
        if ($retExpr -match '^\[string\[\]\]' -or $retExpr -match '^\[String\[\]\]') {
            $types += '[string[]]'
            continue
        }

        # [array] cast
        if ($retExpr -match '^\[array\]') {
            $types += '[array]'
            continue
        }

        # Variable - try to infer type from assignment
        if ($retExpr -match '^\$(\w+)$') {
            $varName = '${0}' -f $Matches[1]
            $esc = [regex]::Escape($retExpr)
            # Look for explicit type cast assignment: [type]$var = ...
            $typeCastMatch = [regex]::Match($body, "(?ms)^\s*\[(\w+(?:\[\])?)\]\s*${esc}\s*=")
            if ($typeCastMatch.Success) {
                $castType = $typeCastMatch.Groups[1].Value
                # Map to OutputType format
                switch -wildcard ($castType) {
                    'string'   { $types += '[string]'; continue }
                    'int'      { $types += '[int]'; continue }
                    'bool'     { $types += '[bool]'; continue }
                    'hashtable' { $types += '[hashtable]'; continue }
                    'string[]' { $types += '[string[]]'; continue }
                    'array'    { $types += '[array]'; continue }
                    Default   { $types += "[${castType}]"; continue }
                }
            }
            # Check for $var = [pscustomobject]@{ ... }
            $pscoMatch = [regex]::Match($body, "(?ms)^\s*${esc}\s*=\s*\[pscustomobject\]@")
            if ($pscoMatch.Success) {
                $types += '[pscustomobject]'
                continue
            }
            # Check for $var = @{ ... }
            $htMatch = [regex]::Match($body, "(?ms)^\s*${esc}\s*=\s*@\{")
            if ($htMatch.Success) {
                $types += '[hashtable]'
                continue
            }
            # Check for $var = @( ... )
            $arrMatch = [regex]::Match($body, "(?ms)^\s*${esc}\s*=\s*@\(")
            if ($arrMatch.Success) {
                $types += '[array]'
                continue
            }
            # Check for $var = " ... (string assignment)
            $strMatch = [regex]::Match($body, "(?ms)^\s*${esc}\s*=\s*[""']")
            if ($strMatch.Success) {
                $types += '[string]'
                continue
            }
            # Check for $var = someCommand (call)
            $cmdMatch = [regex]::Match($body, "(?ms)^\s*${esc}\s*=\s*(\w[\w-]+)")
            if ($cmdMatch.Success) {
                $cmdName = $cmdMatch.Groups[1].Value
                # Heuristic: some cmdlets return objects
                if ($cmdName -match '^Get-' -or $cmdName -match '^New-' -or $cmdName -match '^Invoke-' -or $cmdName -match '^Convert') {
                    # Can't determine type from cmdlet name alone, fall through to void-like
                }
            }
            # Unresolved variable - fall through
        }

        # Cmdlet invocation return
        if ($retExpr -match '^\w[\w-]+') {
            # It's a cmdlet/function call - hard to trace, skip
            continue
        }

        # Fallback - unknown expression type
        continue
    }

    if ($types.Count -eq 0) {
        return '[void]'
    }

    # Return the most common type
    $grouped = $types | Group-Object | Sort-Object Count -Descending
    return $grouped[0].Name
}

function Add-OutputType {
    param([string]$Content, [string]$OutputTypeAttr)

    # Find the position after the function opening brace but before param()
    # Strategy: find the last `param(` in the file (functions only have one)
    $paramIndex = $Content.IndexOf('param(')
    $braceIndex = $Content.IndexOf('{')

    if ($paramIndex -ge 0 -and $braceIndex -ge 0) {
        # Place BEFORE param() but after any comment or CmdletBinding.
        # Find the line start of the param statement.
        $lineStart = $Content.LastIndexOf("`n", $paramIndex)
        if ($lineStart -lt 0) { $lineStart = 0 }
        $precedingContent = $Content.Substring(0, $paramIndex)
        # Insert on a new line right before param(
        $indent = '    '
        $insertion = "${indent}${OutputTypeAttr}`n"
        $newContent = $Content.Substring(0, $paramIndex) + $insertion + $Content.Substring($paramIndex)
        return $newContent
    }
    else {
        # No param() block — place right after the first {
        if ($braceIndex -ge 0) {
            $afterBrace = $Content.Substring($braceIndex + 1)
            # Check if there's whitespace/newline after {
            $trimStart = $afterBrace -match '^\s*'
            $insertion = " ${OutputTypeAttr} "
            $newContent = $Content.Substring(0, $braceIndex + 1) + $insertion + $afterBrace.TrimStart()
            return $newContent
        }
    }

    return $Content
}

foreach ($file in $files) {
    $stats.total++
    $content = Get-Content -Path $file.FullName -Raw

    # Skip if already annotated
    if ($content -match '\[OutputType\(') {
        $stats.skipped += $file.Name
        Write-Host "  [SKIP] $($file.Name) — already annotated" -ForegroundColor Gray
        continue
    }

    $fullName = $file.FullName
    $fileNameOnly = $file.Name

    $outputType = Get-ReturnTypeFromBody -Content $content -FileName $fileNameOnly

    if (-not $outputType) {
        $stats.error += $fileNameOnly
        Write-Host "  [ERR]  $fileNameOnly — could not determine return type" -ForegroundColor Red
        continue
    }

    $newContent = Add-OutputType -Content $content -OutputTypeAttr $outputType

    # Verify the output type was actually injected
    if ($newContent -eq $content) {
        $stats.error += $fileNameOnly
        Write-Host "  [ERR]  $fileNameOnly — injection failed (no change)" -ForegroundColor Red
        continue
    }

    Set-Content -Path $fullName -Value $newContent -NoNewline -Encoding utf8

    # Record stats
    switch ($outputType) {
        '[void]'         { $stats.void += $fileNameOnly }
        '[bool]'         { $stats.bool += $fileNameOnly }
        '[pscustomobject]' { $stats.pscustomobject += $fileNameOnly }
        '[hashtable]'    { $stats.hashtable += $fileNameOnly }
        '[string]'       { $stats.string += $fileNameOnly }
        '[string[]]'     { $stats.stringArray += $fileNameOnly }
        '[array]'        { $stats.array += $fileNameOnly }
        '[int]'          { $stats.int += $fileNameOnly }
        default          { $stats.error += "${fileNameOnly}($outputType)" }
    }

    Write-Host "  [OK]   $fileNameOnly → $outputType" -ForegroundColor Green
}

Write-Host "`n==============================" -ForegroundColor Cyan
Write-Host "  OUTPUT TYPE ANNOTATION SUMMARY" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan
Write-Host "Total files processed: $($stats.total)"
Write-Host "Skipped (already annotated): $($stats.skipped.Count)"
Write-Host "  Breakdown: $($stats.skipped -join ', ')"
Write-Host "`nAnnotated files: $($stats.total - $stats.skipped.Count - $stats.error.Count)"
Write-Host "  [void]:         $($stats.void.Count)"
Write-Host "  [bool]:         $($stats.bool.Count)"
Write-Host "  [pscustomobject]: $($stats.pscustomobject.Count)"
Write-Host "  [hashtable]:    $($stats.hashtable.Count)"
Write-Host "  [string]:       $($stats.string.Count)"
Write-Host "  [string[]]:     $($stats.stringArray.Count)"
Write-Host "  [array]:        $($stats.array.Count)"
Write-Host "  [int]:          $($stats.int.Count)"
Write-Host "`nErrors: $($stats.error.Count)"
if ($stats.error.Count -gt 0) {
    $stats.error | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
