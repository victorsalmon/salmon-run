<#
.SYNOPSIS
    Safely parses a PID string, returning $null for non-numeric or invalid values.
.DESCRIPTION
    Reads PID file content (which may contain non-numeric strings like agent IDs)
    and returns a valid [int] only when the value is a positive integer.
    Returns $null for empty, whitespace, non-numeric, zero, or negative values.
.PARAMETER Value
    Raw string from a PID file to parse.
.OUTPUTS
    [int] if the value is a valid positive integer, $null otherwise.
.EXAMPLE
    Convert-PidSafe "123"   # returns 123
    Convert-PidSafe "coder-abc"  # returns $null
    Convert-PidSafe ""     # returns $null
    Convert-PidSafe " 456 "  # returns 456
#>
function Convert-PidSafe {
    param([string]$Value)
    $pidNum = 0
    if (-not [string]::IsNullOrWhiteSpace($Value) -and [int]::TryParse($Value.Trim(), [ref]$pidNum) -and $pidNum -gt 0) {
        return $pidNum
    }
    return $null
}
