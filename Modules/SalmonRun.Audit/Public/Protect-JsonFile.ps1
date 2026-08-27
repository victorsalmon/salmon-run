function Protect-JsonFile {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$PassThru
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Protect-JsonFile: file not found at '$Path'"
        return
    }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $redacted = Invoke-RedactJsonContent -Content $raw
    $redacted | Set-Content -LiteralPath $Path -NoNewline -Encoding utf8 -ErrorAction Stop
    if ($PassThru) { return $redacted }
}

function Invoke-RedactJsonContent {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Content
    )
    if ([string]::IsNullOrWhiteSpace($Content)) { return $Content }
    try {
        $parsed = $Content | ConvertFrom-Json -ErrorAction Stop
        $scrubbed = Invoke-RedactContentRecursive -InputObject $parsed
        $result = $scrubbed | ConvertTo-Json -Compress -Depth 20 -ErrorAction Stop
        $result = Invoke-RedactContentPatterns -Text $result
        return $result
    } catch {
        $result = Invoke-RedactContentPatterns -Text $Content
        return $result
    }
}

function Invoke-RedactContentRecursive {
    param([psobject]$InputObject)
    if (-not $InputObject) { return $InputObject }
    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Value -is [string]) {
            $redacted = Invoke-RedactContentPatterns -Text $prop.Value
            $InputObject.$($prop.Name) = $redacted
        } elseif ($prop.Value -is [psobject] -or $prop.Value -is [hashtable]) {
            $null = Invoke-RedactContentRecursive -InputObject $prop.Value
        } elseif ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string]) {
            $idx = 0
            foreach ($item in $prop.Value) {
                if ($item -is [psobject] -or $item -is [hashtable]) {
                    $null = Invoke-RedactContentRecursive -InputObject $item
                } elseif ($item -is [string]) {
                    $prop.Value[$idx] = Invoke-RedactContentPatterns -Text $item
                }
                $idx++
            }
        }
    }
    return $InputObject
}

function Invoke-RedactContentPatterns {
    [OutputType([string])]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    foreach ($pattern in $script:SecretPatterns.ContentPatterns) {
        $Text = $Text -replace $pattern, '***REDACTED***'
    }
    return $Text
}
