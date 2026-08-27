function Invoke-FleetDockerExec {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $allowedServices = @(
        "oc-base", "is-fleet", "mcp_opencode",
        "mcp_browserless",
        "is-bookkeeping", "ops-funnel-proxy"
    )

    $matched = $false
    foreach ($svc in $allowedServices) {
        if ($ContainerName -match [regex]::Escape($svc)) {
            $matched = $true
            break
        }
    }

    if (-not $matched) {
        Write-FleetLog "docker exec denied: container '$ContainerName' not in whitelist" -Level WARN
        $global:LASTEXITCODE = 1
        return $null
    }

    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    try {
        $cmdArgs = $Command -split '\s+'
        $result = docker exec --cap-drop=ALL --security-opt=no-new-privileges $ContainerName @cmdArgs 2>$null
        $global:LASTEXITCODE = $LASTEXITCODE
        return $result
    }
    finally {
        [Console]::OutputEncoding = $prevEncoding
    }
}
