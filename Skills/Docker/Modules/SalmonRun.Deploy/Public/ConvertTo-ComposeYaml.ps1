<#
.SYNOPSIS
    Converts a PowerShell object to a Docker Compose YAML string.
.DESCRIPTION
    Recursively serializes hashtables, ordered dictionaries, arrays, and scalar values
    into indented YAML following Docker Compose conventions. Handles nested structures,
    empty collections, and multi-line scalar formatting. Used by New-FleetCompose to
    generate docker-compose.interclaw.yml.
.PARAMETER InputObject
    The PowerShell object to serialize (hashtable, ordered dictionary, array, or scalar).
.PARAMETER Indent
    Current indentation level (each level = 2 spaces). Default 0.
#>
function ConvertTo-ComposeYaml {
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [int]$Indent = 0
    )

    $IndentStr = "  " * $Indent
    $Lines = [System.Collections.Generic.List[string]]::new()

    if ($InputObject -is [hashtable] -or $InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($Key in $InputObject.Keys) {
            $Value = $InputObject[$Key]
            if ($null -eq $Value) {
                $Lines.Add("$IndentStr${Key}:")
            }
            elseif ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
                if ($Value.Count -eq 0) {
                    $Lines.Add("$IndentStr${Key}: {}")
                }
                else {
                    $Lines.Add("$IndentStr${Key}:")
                    $Lines.Add($(ConvertTo-ComposeYaml -InputObject $Value -Indent ($Indent + 1)))
                }
            }
            elseif ($Value -is [array] -or $Value -is [System.Collections.IList]) {
                if ($Value.Count -eq 0) {
                    $Lines.Add("$IndentStr${Key}: []")
                }
                else {
                    $Lines.Add("$IndentStr${Key}:")
                    foreach ($Item in $Value) {
                        if ($Item -is [hashtable] -or $Item -is [System.Collections.Specialized.OrderedDictionary]) {
                            $First = $true
                            foreach ($SubKey in $Item.Keys) {
                                $SubValue = $Item[$SubKey]
                                if ($First) {
                                    $Lines.Add("$IndentStr  - $SubKey`: $(ConvertTo-ComposeYamlScalar -Value $SubValue)")
                                    $First = $false
                                }
                                else {
                                    $Lines.Add("$IndentStr    $SubKey`: $(ConvertTo-ComposeYamlScalar -Value $SubValue)")
                                }
                            }
                        }
                        else {
                            $Lines.Add("$IndentStr  - $(ConvertTo-ComposeYamlScalar -Value $Item)")
                        }
                    }
                }
            }
            else {
                $Lines.Add("$IndentStr${Key}: $(ConvertTo-ComposeYamlScalar -Value $Value)")
            }
        }
    }
    elseif ($InputObject -is [array] -or $InputObject -is [System.Collections.IList]) {
        foreach ($Item in $InputObject) {
            if ($Item -is [hashtable] -or $Item -is [System.Collections.Specialized.OrderedDictionary]) {
                $First = $true
                foreach ($SubKey in $Item.Keys) {
                    $SubValue = $Item[$SubKey]
                    if ($First) {
                        $Lines.Add("$IndentStr- $SubKey`: $(ConvertTo-ComposeYamlScalar -Value $SubValue)")
                        $First = $false
                    }
                    else {
                        $Lines.Add("$IndentStr  $SubKey`: $(ConvertTo-ComposeYamlScalar -Value $SubValue)")
                    }
                }
            }
            else {
                $Lines.Add("$IndentStr- $(ConvertTo-ComposeYamlScalar -Value $Item)")
            }
        }
    }
    else {
        $Lines.Add($(ConvertTo-ComposeYamlScalar -Value $InputObject))
    }

    return ($Lines -join "`n")
}
