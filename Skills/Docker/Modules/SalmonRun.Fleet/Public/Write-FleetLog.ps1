<#
.SYNOPSIS
    Writes a log entry via Write-SetupLog with timestamp and severity.
.PARAMETER Message
    Log message text.
.PARAMETER Level
    Severity level (INFO, WARN, ERROR, OK). Defaults to INFO.
.OUTPUTS
    None.
#>
function Write-FleetLog {
    [OutputType([void])]
    param([string]$Message, [string]$Level = "INFO")
    Write-SetupLog -Message $Message -Level $Level
}
