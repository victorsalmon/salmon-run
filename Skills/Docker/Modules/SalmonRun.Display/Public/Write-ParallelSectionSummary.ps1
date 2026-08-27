<#
.SYNOPSIS
    Prints a formatted summary of parallel section results to the information stream.
.DESCRIPTION
    Iterates over an array of result objects and prints each with a status prefix
    ([OK], [FAIL], [WARN]) coloured by the DefaultColor/DefaultFailColor parameters.
    Supports hashtable, PSCustomObject, and plain string entries. The output tag
    is determined by the Passed or Status property of each result.
.PARAMETER Title
    Heading text displayed above the summary block.
.PARAMETER Results
    Array of result objects. Each entry may have Name, Detail, Passed, Status,
    and Color properties.
.PARAMETER DefaultColor
    Console color for OK/default status entries. Default Green.
.PARAMETER DefaultFailColor
    Console color for FAIL entries. Default Red.
.OUTPUTS
    None. Writes to the information stream.
#>
function Write-ParallelSectionSummary {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [array]$Results,
        [ConsoleColor]$DefaultColor = "Green",
        [ConsoleColor]$DefaultFailColor = "Red"
    )
    Write-Information -MessageData "" -Tags "INFO"
    Write-Information -MessageData "`u{2514}`u{2500}`u{2500} $Title Summary `u{2500}`u{2500}" -Tags "INFO"
    foreach ($r in $Results) {
        $name = if ($r -is [hashtable] -or $r -is [pscustomobject]) { $r.Name } else { "$r" }
        $detail = if ($r -is [hashtable] -or $r -is [pscustomobject]) { $r.Detail } else { "" }

        if ($r -is [hashtable] -or $r -is [pscustomobject]) {
            if ($null -ne $r.Passed -and -not $r.Passed) {
                Write-Information -MessageData "  [FAIL] ${name}: ${detail}" -Tags "ERROR"
            } elseif ($null -ne $r.Status) {
                if ($r.Status -eq "WARN") {
                    Write-Information -MessageData "  [$($r.Status)] ${name}: ${detail}" -Tags "WARN"
                } else {
                    Write-Information -MessageData "  [$($r.Status)] ${name}: ${detail}" -Tags "INFO"
                }
            } elseif ($r.ContainsKey('Color') -or (Get-Member -InputObject $r -Name 'Color' -ErrorAction SilentlyContinue)) {
                Write-Information -MessageData "  ${name}: ${detail}" -Tags "INFO"
            } else {
                Write-Information -MessageData "  [OK] ${name}: ${detail}" -Tags "INFO"
            }
        } else {
            Write-Information -MessageData "  $r" -Tags "INFO"
        }
    }
}

