<#
.SYNOPSIS
    Validates a SalmonRun JSON configuration object against its declared schema type.
    Returns a structured result with validation errors and warnings.
.PARAMETER Config
    The configuration object (hashtable or PSObject) loaded from JSON.
.PARAMETER ConfigType
    The type of config to validate: Provider, Agent, or Policy.
.OUTPUTS
    [pscustomobject]@{ Valid = <bool>; Errors = <string[]>; Warnings = <string[]> }
#>
function Test-SalmonRunConfigSchema {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Provider", "Agent", "Policy", "Install")]
        [string]$ConfigType
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Config) {
        $Errors.Add("Config object is null")
        return [pscustomobject]@{ Valid = $false; Errors = $Errors.ToArray(); Warnings = $Warnings.ToArray() }
    }

    switch ($ConfigType) {
        "Provider" {
            if (-not $Config.models) {
                $Errors.Add("Missing top-level 'models' section")
            }
            elseif (-not $Config.models.providers) {
                $Errors.Add("Missing 'models.providers' section")
            }
            else {
                $Providers = $Config.models.providers.PSObject.Properties
                if (-not $Providers -or $Providers.Count -eq 0) {
                    $Errors.Add("'models.providers' must contain at least one provider")
                }
                else {
                    foreach ($Prop in $Providers) {
                        $ProviderName = $Prop.Name
                        $Provider = $Prop.Value
                        if (-not $Provider.baseUrl) {
                            $Errors.Add("Provider '$ProviderName' is missing 'baseUrl'")
                        }
                        if (-not $Provider.api) {
                            $Errors.Add("Provider '$ProviderName' is missing 'api'")
                        }
                        if (-not $Provider.auth) {
                            $Errors.Add("Provider '$ProviderName' is missing 'auth'")
                        }
                        if (-not $Provider.models -or $Provider.models.Count -eq 0) {
                            $Errors.Add("Provider '$ProviderName' must have at least one model in 'models' array")
                        }
                        else {
                            for ($i = 0; $i -lt $Provider.models.Count; $i++) {
                                $Model = $Provider.models[$i]
                                if (-not $Model.id) {
                                    $Errors.Add("Provider '$ProviderName' model[$i] is missing 'id'")
                                }
                                if (-not $Model.name) {
                                    $Warnings.Add("Provider '$ProviderName' model[$i] is missing 'name'")
                                }
                                if (-not $Model.type) {
                                    $Warnings.Add("Provider '$ProviderName' model[$i] is missing 'type'")
                                }
                            }
                        }
                    }
                }
            }
        }

        "Agent" {
            if (-not $Config.agents) {
                $Errors.Add("Missing top-level 'agents' section")
            }
            elseif (-not $Config.agents.defaults) {
                $Warnings.Add("Missing 'agents.defaults' section")
            }
            elseif (-not $Config.agents.defaults.model -or -not $Config.agents.defaults.model.primary) {
                $Warnings.Add("Missing 'agents.defaults.model.primary' -- agent may not have a default model")
            }

            if (-not $Config.models) {
                $Errors.Add("Missing top-level 'models' section")
            }
            elseif (-not $Config.models.providers) {
                $Errors.Add("Missing 'models.providers' section")
            }
            else {
                $Providers = $Config.models.providers.PSObject.Properties
                if (-not $Providers -or $Providers.Count -eq 0) {
                    $Errors.Add("'models.providers' must contain at least one provider")
                }
                else {
                    foreach ($Prop in $Providers) {
                        $ProviderName = $Prop.Name
                        $Provider = $Prop.Value
                        if (-not $Provider.models -or $Provider.models.Count -eq 0) {
                            $Errors.Add("Provider '$ProviderName' must have at least one model in 'models' array")
                        }
                        else {
                            for ($i = 0; $i -lt $Provider.models.Count; $i++) {
                                $Model = $Provider.models[$i]
                                if (-not $Model.id) {
                                    $Errors.Add("Provider '$ProviderName' model[$i] is missing 'id'")
                                }
                                if (-not $Model.name) {
                                    $Warnings.Add("Provider '$ProviderName' model[$i] is missing 'name'")
                                }
                            }
                        }
                    }
                }
            }
        }

        "Policy" {
            if (-not $Config.Version) {
                $Errors.Add("Missing 'Version' field")
            }
            if (-not $Config.Statement) {
                $Errors.Add("Missing 'Statement' array")
            }
            elseif ($Config.Statement.Count -eq 0) {
                $Errors.Add("'Statement' array must contain at least one statement")
            }
            else {
                for ($i = 0; $i -lt $Config.Statement.Count; $i++) {
                    $Stmt = $Config.Statement[$i]
                    if (-not $Stmt.Effect) {
                        $Errors.Add("Statement[$i] is missing 'Effect'")
                    }
                    elseif ($Stmt.Effect -notin @("Allow", "Deny")) {
                        $Errors.Add("Statement[$i] 'Effect' must be 'Allow' or 'Deny', got: $($Stmt.Effect)")
                    }
                    if (-not $Stmt.Action) {
                        $Errors.Add("Statement[$i] is missing 'Action'")
                    }
                    if (-not $Stmt.Resource) {
                        $Warnings.Add("Statement[$i] is missing 'Resource' (may be intentional for wildcard)")
                    }
                }
            }
        }

        "Install" {
            if (-not $Config.features) {
                $Errors.Add("Missing top-level 'features' section")
            }
            else {
                $exceptionPatterns = @('^auto$', '^iam-generated', '^AWSSM ')
                $requiredFields = @('source', 'rotation', 'owner', 'scope')
                $featureProps = $Config.features.PSObject.Properties
                foreach ($featProp in $featureProps) {
                    $featName = $featProp.Name
                    $feature = $featProp.Value
                    if (-not $feature.secrets) { continue }
                    $secretProps = $feature.secrets.PSObject.Properties
                    foreach ($secProp in $secretProps) {
                        $secName = $secProp.Name
                        $secValue = $secProp.Value
                        if ($secValue -is [string]) {
                            $isException = $false
                            foreach ($pat in $exceptionPatterns) {
                                if ($secValue -match $pat) { $isException = $true; break }
                            }
                            if (-not $isException) {
                                $Warnings.Add("Feature '$featName' secret '$secName' is a string value without metadata fields: $secValue")
                            }
                        }
                        elseif ($secValue -is [psobject]) {
                            $missing = [System.Collections.Generic.List[string]]::new()
                            foreach ($field in $requiredFields) {
                                if (-not $secValue.$field) { $missing.Add($field) }
                            }
                            if ($missing.Count -gt 0) {
                                $missingStr = $missing -join ', '
                                $Errors.Add("Feature '$featName' secret '$secName' is missing required field(s): $missingStr")
                            }
                        }
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Valid    = ($Errors.Count -eq 0)
        Errors   = $Errors.ToArray()
        Warnings = $Warnings.ToArray()
    }
}
