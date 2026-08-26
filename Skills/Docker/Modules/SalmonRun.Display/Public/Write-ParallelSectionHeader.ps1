<#
.SYNOPSIS
    Prints a formatted section header with worker names to the information stream.
.DESCRIPTION
    Renders a Unicode box-drawing header with the section title and a list of
    participating workers. Uses Cyan colour for the header frame and DarkGray
    for worker entries.
.PARAMETER Title
    Section title displayed in the header box.
.PARAMETER Workers
    Array of worker names to list below the title.
.OUTPUTS
    None. Writes to the information stream.
#>
function Write-ParallelSectionHeader {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string[]]$Workers
    )
    Write-Information -MessageData "" -Tags "INFO"
    Write-Information -MessageData ("`u{2552}`u{2550}`u{2550} $Title ") -Tags "INFO"
    Write-Information -MessageData ("`u{2550}" * [Math]::Max(1, 68 - $Title.Length - 3)) -Tags "INFO"
    Write-Information -MessageData "`u{2557}" -Tags "INFO"
    foreach ($w in $Workers) {
        Write-Information -MessageData "`u{2551}  `u{25C6} $w" -Tags "INFO"
    }
    Write-Information -MessageData "`u{255A}$("`u{2550}" * 72)`u{255D}" -Tags "INFO"
}

