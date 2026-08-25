function Test-ModuleLoaderDrift {
    [CmdletBinding()]
    param(
        [string]$ModuleName,
        [switch]$PassThru
    )

    $modulesDir = Join-Path $PSScriptRoot '..\..'
    $moduleDirs = if ($ModuleName) {
        $path = Join-Path $modulesDir $ModuleName
        if (Test-Path $path) { @(Get-Item $path) } else { @() }
    } else {
        Get-ChildItem -Path $modulesDir -Directory -Filter 'Interclaw.*'
    }

    $results = @()
    $wrapperPatterns = @('Interclaw.Constants', 'Interclaw.Config', 'Interclaw.Core', 'Interclaw.Paths',
                         'Interclaw.Diagnostics', 'Interclaw.Ports')

    foreach ($dir in $moduleDirs) {
        $name = $dir.Name
        $psm1 = Join-Path $dir.FullName "$name.psm1"
        $ps1  = Join-Path $dir.FullName "$name.ps1"

        if (-not (Test-Path $psm1) -or -not (Test-Path $ps1)) {
            $results += [PSCustomObject]@{ Module=$name; HasDrift=$true; DriftType='MissingLoader'; Details=''; Psm1Lines=0; Ps1Lines=0 }
            continue
        }

        $psm1Text = Get-Content $psm1 -Raw
        $ps1Text  = Get-Content $ps1 -Raw
        $psm1Lines = ($psm1Text -split "`r?`n").Count
        $ps1Lines  = ($ps1Text -split "`r?`n").Count

        $isWrapper = $name -in $wrapperPatterns
        $driftType = @()

        if ($isWrapper) {
            $results += [PSCustomObject]@{
                Module=$name; HasDrift=$false; IsWrapper=$true; DriftType='Wrapper'; Details='.psm1 delegates to .ps1'
                Psm1Lines=$psm1Lines; Ps1Lines=$ps1Lines
            }
            continue
        }

        # Detect thin-wrapper pattern: .ps1 just Import-Module's or dot-sources the .psm1
        $isThinWrapper = ($ps1Text -match 'Import-Module.*\.psm1' -or
                          $ps1Text -match '\.\s+\(Join-Path.*\.psm1') -and
                         $ps1Lines -le 6
        if ($isThinWrapper) {
            $results += [PSCustomObject]@{
                Module=$name; HasDrift=$false; IsWrapper=$false; DriftType='ThinWrapper'; Details='.ps1 delegates to .psm1 via Import-Module'
                Psm1Lines=$psm1Lines; Ps1Lines=$ps1Lines
            }
            continue
        }

        # Extract the loading logic: lines between the header comment/requires and any trailing aliases/exports
        # Remove comment-only lines, blank lines for comparison
        function Get-LoaderCore($text) {
            $lines = $text -split "`r?`n"
            $result = @()
            $inHeader = $true
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq '' -or $trimmed -match '^<#|^#>$|^\.SYNOPSIS|^\.DESCRIPTION|^#Requires|^# =+') { continue }
                if ($trimmed -match '^# ') { continue }
                if ($trimmed -match '^Set-Alias' -or $trimmed -match '^Export-ModuleMember') { continue }
                $result += $trimmed
            }
            return $result -join "`n"
        }

        $psm1Core = Get-LoaderCore $psm1Text
        $ps1Core  = Get-LoaderCore $ps1Text

        # Check $script:ModuleRoot vs $ModuleRoot (normalize for comparison)
        $psm1Norm = $psm1Core -replace '\$script:ModuleRoot', '$$ModuleRoot'
        $ps1Norm  = $ps1Core  -replace '\$script:ModuleRoot', '$$ModuleRoot'
        $psm1Norm = $psm1Norm -replace '\$ModuleRoot\b', '$$ModuleRoot'
        $ps1Norm  = $ps1Norm  -replace '\$ModuleRoot\b', '$$ModuleRoot'

        # Normalize variable names ($PrivatePath/$PublicPath/$PrivateDir/$PublicDir)
        $psm1Norm = $psm1Norm -replace '\$(PrivatePath|PublicPath|PrivateDir|PublicDir|__\w+Path|__\w+PublicPath|__\w+PrivatePath)\b', '$$Path'
        $ps1Norm  = $ps1Norm  -replace '\$(PrivatePath|PublicPath|PrivateDir|PublicDir|__\w+Path|__\w+PublicPath|__\w+PrivatePath)\b', '$$Path'

        # Normalize quotes
        $psm1Norm = $psm1Norm -replace '"', "'"
        $ps1Norm  = $ps1Norm  -replace '"', "'"

        # Normalize whitespace
        $psm1Norm = ($psm1Norm -split "`n" | ForEach-Object { $_.Trim() }) -join "`n"
        $ps1Norm  = ($ps1Norm  -split "`n" | ForEach-Object { $_.Trim() }) -join "`n"

        # Remove -ErrorAction SilentlyContinue for comparison
        $psm1Norm = $psm1Norm -replace '-ErrorAction SilentlyContinue', ''
        $ps1Norm  = $ps1Norm  -replace '-ErrorAction SilentlyContinue', ''

        # Check for guard clause
        $psm1HasGuard = $psm1Text -match 'if \(\$script:\w+Loaded\)'
        $ps1HasGuard  = $ps1Text -match 'if \(\$script:\w+Loaded\)'
        if ($psm1HasGuard -xor $ps1HasGuard) { $driftType += 'GuardClause' }

        # Check Export-ModuleMember
        $psm1HasExport = $psm1Text -match 'Export-ModuleMember'
        $ps1HasExport  = $ps1Text -match 'Export-ModuleMember'
        if ($psm1HasExport -xor $ps1HasExport) { $driftType += 'ExportMember' }

        # Check #Requires
        $psm1HasReq = $psm1Text -match '#Requires -Version 7\.0'
        $ps1HasReq  = $ps1Text -match '#Requires -Version 7\.0'
        if ($psm1HasReq -xor $ps1HasReq) { $driftType += 'Requires' }

        # Check $script: scope
        $psm1Scoped = $psm1Core -match '\$script:ModuleRoot'
        $ps1Scoped  = $ps1Core -match '\$script:ModuleRoot'
        if ($psm1Scoped -xor $ps1Scoped) { $driftType += 'VarScope' }

        # Compare the core loading structure
        if ($psm1Norm -ne $ps1Norm) { $driftType += 'LoaderStructure' }

        $hasDrift = $driftType.Count -gt 0
        $results += [PSCustomObject]@{
            Module=$name; HasDrift=$hasDrift; IsWrapper=$isWrapper
            DriftType=if ($driftType) { $driftType -join ', ' } else { 'None' }
            Details=if ($hasDrift) { "Loader structure differs: $($driftType -join ', ')" } else { 'Loaders match' }
            Psm1Lines=$psm1Lines; Ps1Lines=$ps1Lines
        }
    }

    if ($PassThru) { return $results }

    $drifted = $results | Where-Object HasDrift
    $clean = $results | Where-Object { -not $_.HasDrift -and $_.DriftType -eq 'None' }
    $wrappers = $results | Where-Object { $_.DriftType -eq 'Wrapper' }
    $thinWrappers = $results | Where-Object { $_.DriftType -eq 'ThinWrapper' }

    Write-Verbose "Module Loader Drift Report: Total=$($results.Count) Clean=$($clean.Count) ThinWrapper=$($thinWrappers.Count) Wrapper=$($wrappers.Count) Drifted=$($drifted.Count)"
    foreach ($d in $drifted) {
        Write-Warning "Module loader drift: $($d.Module) ($($d.DriftType))"
    }
    return $drifted.Count -eq 0
}
