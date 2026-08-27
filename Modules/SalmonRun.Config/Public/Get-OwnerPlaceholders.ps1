<#
.SYNOPSIS
    Reads owner placeholder values from the owner config JSON file.
.DESCRIPTION
    Loads the JSON file at $script:OwnerConfigPath and returns a hashtable
    of placeholder key-value pairs. Returns empty hashtable if file not found.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    Hashtable of placeholder name-value pairs.
#>
function Get-OwnerPlaceholders {
    [OutputType([hashtable])]
    param()
    if ([string]::IsNullOrWhiteSpace($script:OwnerConfigPath)) { return @{} }
    if (-not (Test-Path $script:OwnerConfigPath)) { return @{} }
    try {
        $json = Get-Content -LiteralPath $script:OwnerConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $json.PSObject.Properties) { $map[$prop.Name] = "$($prop.Value)" }
        return $map
    } catch {
        $type = $_.Exception.GetType().Name
        $msg = $_.Exception.Message
        Write-SetupLog "Get-OwnerPlaceholders: $type — $msg" -Level WARN
        if ($type -match 'JsonReaderException|UnauthorizedAccessException|IOException') {
            throw
        }
        return @{}
    }
}
