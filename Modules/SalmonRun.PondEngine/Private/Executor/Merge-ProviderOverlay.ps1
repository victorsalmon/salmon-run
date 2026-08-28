function Merge-ProviderOverlay {
    <#
    .SYNOPSIS
        Recursively merge a provider overlay fragment into a base hashtable.

    .DESCRIPTION
        Used by Get-PondExecutorRegistry to apply ~/.salmon/providers/*.json
        files over the built-in harness-defaults.json and model-router-catalog.json.

        - Hashtable keys are merged recursively.
        - The 'models' array is merged by canonicalName: an overlay model with the
          same canonicalName replaces the base model; otherwise it is appended.
        - Other arrays are appended.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [object]$Base,

        [Parameter(Mandatory)]
        [object]$Overlay,

        [string]$Key = ''
    )

    if ($null -eq $Overlay) { return $Base }

    if ($Overlay -is [hashtable] -and $Base -is [hashtable]) {
        foreach ($k in $Overlay.Keys) {
            if ($Base.ContainsKey($k)) {
                $Base[$k] = Merge-ProviderOverlay -Base $Base[$k] -Overlay $Overlay[$k] -Key $k
            } else {
                $Base[$k] = $Overlay[$k]
            }
        }
        return $Base
    }

    if (($Overlay -is [array] -or $Overlay -is [System.Collections.IList]) -and
        ($Base -is [array] -or $Base -is [System.Collections.IList])) {
        if ($Key -eq 'models') {
            $result = [System.Collections.ArrayList]::new()
            if ($null -ne $Base) { foreach ($item in $Base) { $null = $result.Add($item) } }

            foreach ($overlayItem in $Overlay) {
                $canonicalName = if ($overlayItem -is [hashtable]) { $overlayItem['canonicalName'] } else { $null }
                if (-not [string]::IsNullOrWhiteSpace($canonicalName)) {
                    $replaced = $false
                    for ($i = 0; $i -lt $result.Count; $i++) {
                        if ($result[$i] -is [hashtable] -and $result[$i]['canonicalName'] -eq $canonicalName) {
                            $result[$i] = Merge-ProviderOverlay -Base $result[$i] -Overlay $overlayItem -Key $Key
                            $replaced = $true
                            break
                        }
                    }
                    if (-not $replaced) { $null = $result.Add($overlayItem) }
                } else {
                    $null = $result.Add($overlayItem)
                }
            }
            return [array]$result
        } else {
            return [array]($Base + $Overlay)
        }
    }

    return $Overlay
}

