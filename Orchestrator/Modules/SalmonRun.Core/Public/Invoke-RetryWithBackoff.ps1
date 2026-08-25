function Invoke-RetryWithBackoff {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [int]$MaxAttempts,

        [int[]]$Schedule = @(2, 4, 8, 16, 32),

        [ValidateRange(0.0, 1.0)]
        [double]$JitterFraction = 0.25,

        [int]$MaxDelay = 300,

        [string]$Label,

        [System.Management.Automation.ActionPreference]$ErrorActionPreference = 'Stop'
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $result = & $ScriptBlock
            if ($Label) { Write-Verbose "[Retry:$Label] Attempt $attempt succeeded" }
            return $result
        } catch {
            $lastError = $_
            if ($Label) { Write-Verbose "[Retry:$Label] Attempt $attempt failed: $($_.Exception.Message)" }
            if ($attempt -ge $MaxAttempts) { throw }
            $delay = Get-BackoffDelay -Attempt $attempt -Schedule $Schedule -JitterFraction $JitterFraction -MaxDelay $MaxDelay
            Write-Warning "[Retry:$Label] Attempt $attempt/$MaxAttempts failed. Retrying in ${delay}s: $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
        }
    }
}
