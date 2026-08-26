<#
.SYNOPSIS
Writes a string to a file atomically using a temporary file and rename.
.PARAMETER Path
The target file path for the output.
.PARAMETER Value
The string value to write to the file. Accepts pipeline input.
.PARAMETER Encoding
The text encoding to use. Defaults to UTF8.

## Constraints
- Temp file must be on same volume as target for atomic rename via MoveFileEx
- Cross-volume fallback uses System.IO.File.Move (not atomic on all platforms)
- Requires kernel32.dll MoveFileEx on Windows for same-volume atomicity

## Lessons Learned
- Set-Content to temp then rename prevents partial writes from being read
- Cross-volume rename cannot be atomic on Windows — always isolate temp and target on same volume
- MoveFileEx with MOVEFILE_REPLACE_EXISTING is the correct Windows API for atomic replace
#>
function Write-AtomicFile {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Value,
        [string]$Encoding = "UTF8"
    )
    end {
        $parent = [System.IO.Path]::GetDirectoryName($Path)
        $tmpPath = [System.IO.Path]::Combine($parent, [System.IO.Path]::GetRandomFileName())

        # Check if temp and target are on the same volume
        $targetRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        $tempRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($tmpPath))
        $sameVolume = $targetRoot -eq $tempRoot

        $isWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

        if ($isWindowsPlatform -and -not ([System.Management.Automation.PSTypeName]'AtomicMove').Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class AtomicMove {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "MoveFileExW")]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);
    public const uint MOVEFILE_REPLACE_EXISTING = 0x00000001;
}
"@
        }

        try {
            $Value | Set-Content -Path $tmpPath -Encoding $Encoding -ErrorAction Stop
            if ($isWindowsPlatform -and $sameVolume) {
                $ok = [AtomicMove]::MoveFileEx($tmpPath, $Path, [AtomicMove]::MOVEFILE_REPLACE_EXISTING)
                if (-not $ok) { throw "MoveFileEx failed for atomic write to '$Path'" }
            } else {
                [System.IO.File]::Move($tmpPath, $Path, $true)
            }
        } catch {
            try { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction Stop } catch { Write-Warning "Write-AtomicFile: failed to clean up temp file '$tmpPath': $_" }
            throw
        }
    }
}
