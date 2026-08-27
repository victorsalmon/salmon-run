function Invoke-RedactUri {
    param(
        [string]$Uri,
        [string[]]$SkipRedactKeys = @()
    )
    if ([string]::IsNullOrWhiteSpace($Uri)) { return $Uri }

    $qmarkIndex = $Uri.IndexOf('?')
    if ($qmarkIndex -lt 0 -or $qmarkIndex -eq $Uri.Length - 1) { return $Uri }

    $basePart = $Uri.Substring(0, $qmarkIndex)
    $queryString = $Uri.Substring($qmarkIndex + 1)

    $sensitiveKeyPatterns = @('api_key', 'token', 'secret', 'password', 'key', 'access_token', 'refresh_token', 'auth', 'passwd', 'pwd', 'apikey', 'bearer', 'credential')

    $redactedParams = @()
    foreach ($param in $queryString -split '&') {
        if ([string]::IsNullOrWhiteSpace($param)) { continue }
        $eqIndex = $param.IndexOf('=')
        if ($eqIndex -lt 0) { $redactedParams += $param; continue }

        $key = $param.Substring(0, $eqIndex)
        $value = $param.Substring($eqIndex + 1)

        $skip = $false
        foreach ($skipKey in $SkipRedactKeys) {
            if ($key -like $skipKey) { $skip = $true; break }
        }
        if (-not $skip) {
            foreach ($pattern in $sensitiveKeyPatterns) {
                if ($key -like "*$pattern*") { $value = '***'; break }
            }
        }
        $redactedParams += "$key=$value"
    }

    return "$basePart`?$($redactedParams -join '&')"
}

function Invoke-RedactSecrets {
    param(
        [hashtable]$Headers,
        [string]$Body,
        [psobject]$Response,
        [string[]]$SkipRedactKeys = @()
    )
    $redactedHeaders = @{}
    if ($Headers) {
        foreach ($key in $Headers.Keys) {
            $skip = $false
            foreach ($skipKey in $SkipRedactKeys) {
                if ($key -like $skipKey) { $skip = $true; break }
            }
            if ($skip) {
                $redactedHeaders[$key] = $Headers[$key]
            } else {
                $matched = $false
                foreach ($pattern in $script:SecretPatterns.Headers) {
                    if ($key -like $pattern) { $matched = $true; break }
                }
                $redactedHeaders[$key] = if ($matched) { '***' } else { $Headers[$key] }
            }
        }
    }
    $redactedBody = ''
    if ($Body) {
        try {
            $parsed = $Body | ConvertFrom-Json -ErrorAction Stop
            $redactedObj = Invoke-RedactObject -InputObject $parsed -SkipKeys $SkipRedactKeys
            $redactedBody = $redactedObj | ConvertTo-Json -Compress -Depth 10
        } catch {
            $redactedBody = ($Body -replace '(api_key|client_secret|client_id|refresh_token|access_token|password|secret|token|bearer|auth)=[^&]+', '$1=***')
        }
    }
    $redactedResponse = $null
    if ($Response) {
        try {
            $respJson = $Response | ConvertTo-Json -Compress -Depth 5 -ErrorAction Stop
            $respParsed = $respJson | ConvertFrom-Json -ErrorAction Stop
            $respRedacted = Invoke-RedactObject -InputObject $respParsed -SkipKeys $SkipRedactKeys
            $redactedResponse = $respRedacted | ConvertTo-Json -Compress -Depth 5
        } catch {
            $redactedResponse = '***'
        }
    }
    return @{
        Headers   = $redactedHeaders
        Body      = $redactedBody
        Response  = $redactedResponse
    }
}

function Invoke-RedactObject {
    param([psobject]$InputObject, [string[]]$SkipKeys)
    try {
        $result = $InputObject | ConvertTo-Json -Depth 10 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result = $InputObject.PSObject.Copy()
    }
    $foundUnredacted = @()
    $redacted = Invoke-RedactObjectRecursive -InputObject $result -SkipKeys $SkipKeys -FoundUnredacted ([ref]$foundUnredacted)
    if ($foundUnredacted.Count -gt 0) {
        Write-Warning "Invoke-RedactObject: unredacted credential-like fields detected after processing: $($foundUnredacted -join ', ')"
    }
    return $redacted
}

function Invoke-RedactObjectRecursive {
    param([psobject]$InputObject, [string[]]$SkipKeys, [ref]$FoundUnredacted)
    if (-not $InputObject) { return $InputObject }
    $sensitivePatterns = $script:SecretPatterns.BodyFields

    foreach ($prop in $InputObject.PSObject.Properties) {
        $skip = $false
        foreach ($skipKey in $SkipKeys) {
            if ($prop.Name -like $skipKey) { $skip = $true; break }
        }
        if (-not $skip) {
            $matchedPattern = $null
            foreach ($pattern in $sensitivePatterns) {
                if ($prop.Name -like "*$pattern*") { $matchedPattern = $pattern; break }
            }
            if ($matchedPattern) {
                $propValue = $InputObject.$($prop.Name)
                if ($propValue -and $propValue -ne '***') {
                    $FoundUnredacted.Value += "$($prop.Name)=$propValue"
                }
                $InputObject.$($prop.Name) = '***'
            } elseif ($prop.Value -is [psobject] -or $prop.Value -is [hashtable]) {
                $null = Invoke-RedactObjectRecursive -InputObject $prop.Value -SkipKeys $SkipKeys -FoundUnredacted $FoundUnredacted
            }
        }
    }
    return $InputObject
}
