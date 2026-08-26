<#
.SYNOPSIS
    Makes an HTTP API call with audit logging and optional retry logic.
.PARAMETER Uri
    Full request URL.
.PARAMETER Method
    HTTP method (GET, POST, PUT, PATCH, DELETE). Defaults to GET.
.PARAMETER Headers
    Optional hashtable of HTTP headers.
.PARAMETER Body
    Request body object. Will be serialized to JSON when ContentType is application/json.
.PARAMETER ContentType
    Content-Type header value. Defaults to application/json.
.PARAMETER TimeoutSec
    Request timeout in seconds. Defaults to 30.
.PARAMETER Domain
    Audit domain namespace for logging this API call.
.PARAMETER Action
    Descriptive action label for the audit entry (e.g. 'CreateExpense', 'SearchContacts').
.PARAMETER SessionRef
    Optional session or transaction identifier for correlating audit entries.
.PARAMETER ReturnRaw
    If set, returns the raw Invoke-WebRequest response instead of Invoke-RestMethod.
.PARAMETER RetryCount
    Number of automatic retries on failure (excluding the initial attempt).
.PARAMETER RetryDelayMs
    Base delay in milliseconds between retries (used with exponential backoff).
.PARAMETER SkipRedactKeys
    Array of header or body keys to skip during secret redaction for audit logging.
#>
function Invoke-ApiCall {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [object]$Body,
        [string]$ContentType = 'application/json',
        [int]$TimeoutSec = 30,
        [Parameter(Mandatory)][string]$Domain,
        [string]$Action = '',
        [string]$SessionRef = '',
        [switch]$ReturnRaw,
        [int]$RetryCount = 0,
        [int]$RetryDelayMs = 1000,
        [string[]]$SkipRedactKeys = @()
    )
    [OutputType([object])]
    $startTime = Get-Date
    $agentId = if ($env:OC_RESERVATION_AGENT_ID) { $env:OC_RESERVATION_AGENT_ID } else { $script:agentId }
    if (-not $agentId) { $agentId = 'unknown' }

    $splat = @{
        Uri                  = $Uri
        Method               = $Method
        ContentType          = $ContentType
        UseBasicParsing      = $true
        TimeoutSec           = $TimeoutSec
        ErrorAction          = 'Stop'
    }
    if ($Headers.Count -gt 0) { $splat.Headers = $Headers }
    if ($Body) { $splat.Body = $Body }

    $redacted = Invoke-RedactSecrets -Headers $Headers -Body ($Body | ConvertTo-Json -Compress -Depth 10 -ErrorAction SilentlyContinue) -SkipRedactKeys $SkipRedactKeys

    if ($SkipRedactKeys.Count -gt 0) {
        $keysList = $SkipRedactKeys -join ', '
        Write-SetupLog "Invoke-ApiCall: SkipRedactKeys active for keys: $keysList (action=$Action domain=$Domain)" -Level WARN
    }

    $lastError = $null
    $response = $null

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        if ($attempt -gt 0) {
            $delaySec = Get-BackoffDelay -Attempt $attempt -Schedule @(1, 2, 4, 8, 16)
            Start-Sleep -Seconds $delaySec
        }
        try {
            if ($ReturnRaw) {
                $response = Invoke-WebRequest @splat
            } else {
                $response = Invoke-RestMethod @splat
            }
            $lastError = $null
            break
        } catch {
            $lastError = $_
            # Loop will retry if $attempt < $RetryCount, otherwise exits
        }
    }

    $endTime = Get-Date
    $durationMs = [math]::Round(($endTime - $startTime).TotalMilliseconds, 0)

    $auditEntry = @{
        ts      = $startTime.ToString('o')
        agent   = $agentId
        action  = $Action
        session = $SessionRef
        domain  = $Domain
        req     = @{
            uri            = Invoke-RedactUri -Uri $Uri -SkipRedactKeys $SkipRedactKeys   # redacted canonical URI for audit
            method         = $Method
            headers        = $redacted.Headers
            body           = $redacted.Body
        }
        ms      = $durationMs
    }

    if ($lastError) {
        $auditEntry.error = $lastError.Exception.Message
        Write-AuditEntry -Entry $auditEntry -Domain $Domain
        throw $lastError
    }

    if ($ReturnRaw) {
        $redactedResp = $null
        try {
            $redactedResp = "StatusCode: $($response.StatusCode)"
        } catch {
            $redactedResp = '***'
        }
        $auditEntry.res = $redactedResp
    } else {
        $redacted = Invoke-RedactSecrets -Response $response -SkipRedactKeys $SkipRedactKeys
        $auditEntry.res = $redacted.Response
    }
    Write-AuditEntry -Entry $auditEntry -Domain $Domain
    return $response
}
