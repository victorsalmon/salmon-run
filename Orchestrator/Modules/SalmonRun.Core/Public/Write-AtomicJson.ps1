<#
.SYNOPSIS
    Writes JSON to a file atomically via a temporary file and rename.
.DESCRIPTION
    Converts input objects to JSON and writes to a .tmp file, then atomically
    moves the temporary file to the target path. Prevents partial writes from
    being read by other processes.

## Constraints
- Temp file must be on same volume as target for atomic rename
- Uses .tmp extension adjacent to target file to ensure same-volume move
- Encoding is always UTF8NoBOM

## Lessons Learned
- .tmp extension adjacent to target guarantees same-volume atomic move
- ConvertTo-Json depth limits prevent circular reference errors
- System.IO.File.Move with overwrite=true replaces Move-Item for atomicity
.PARAMETER Path
    The target file path for the JSON output.
.PARAMETER InputObject
    The object(s) to serialize to JSON. Accepts pipeline input.
.PARAMETER Depth
    The JSON serialization depth. Default 3.
.PARAMETER Compress
    If set, produces compact (non-pretty-printed) JSON.
.PARAMETER NoNewline
    If set, omits the trailing newline from the output file.
#>
function Write-AtomicJson {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$InputObject,
        [int]$Depth = 3,
        [switch]$Compress,
        [switch]$NoNewline
    )
    begin {
        $objects = [System.Collections.Generic.List[object]]::new()
    }
    process {
        $objects.Add($InputObject)
    }
    end {
        $parent = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        $tmpPath = "$Path.tmp"
        $json = $objects | ConvertTo-Json -Depth $Depth -Compress:$Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        [System.IO.File]::WriteAllBytes($tmpPath, $bytes)
        if (-not (Test-Path $tmpPath)) { throw "Write-AtomicJson temp file not created: $tmpPath" }
        [System.IO.File]::Move($tmpPath, $Path, $true)
    }
}
