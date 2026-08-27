<#
.SYNOPSIS
    Writes a deploy manifest JSON file recording what was deployed.
.DESCRIPTION
    Records per-container source hash, git commit, image, and timestamp
    to Tasks/Logs/deploy-manifest.json for later staleness comparison
    by deploy-lite.ps1 and similar tools. Uses atomic write via .tmp file.
.PARAMETER StackName
    Name of the Docker Swarm stack.
.PARAMETER TargetDir
    Repository root directory for resolving Tasks/Logs/ path.
.PARAMETER AgentConfigs
    Array of agent configuration hashtables (for metadata enrichment).
.PARAMETER ImageVersion
    Image version tag applied to all service images.
.PARAMETER ExtraContainerMetadata
    Hashtable of per-container metadata overrides or additions.
    Keys are service names; values are hashtables merged into the entry.
.PARAMETER WhatIf
    Show what would be written without writing to disk.
#>
function Write-DeployManifest {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [string]$StackName,
        [string]$TargetDir,
        [hashtable[]]$AgentConfigs,
        [string]$ImageVersion = "local",
        [hashtable]$ExtraContainerMetadata
    )

    $CoreServices = @(
        'is-fleet', 'mcp_opencode',
        'mcp_browserless', 'is-bookkeeping',
        'ops-funnel-proxy', 'oc-base'
    )

    $ImageNameMap = @{
        'is-fleet'        = 'fleet'
        'mcp_opencode'    = 'opencode'
        'mcp_browserless' = 'mcp_browserless'
        'is-bookkeeping'   = 'Bookkeeper'
        'ops-funnel-proxy' = 'funnel-proxy'
    }

    $GitCommit = (git rev-parse HEAD).Trim()
    $GitBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    $GitRemote = (git remote | Select-Object -First 1).Trim()

    $ServiceNames = $CoreServices + @($ExtraContainerMetadata.Keys) | Select-Object -Unique
    $Containers = @{}

    foreach ($ServiceName in $ServiceNames) {
        $BaseName = if ($ImageNameMap.ContainsKey($ServiceName)) { $ImageNameMap[$ServiceName] } else { $ServiceName }
        $ImageTag = "$BaseName`:$ImageVersion"
        $LabelKey = "org.interclaw.${ServiceName}.source-hash"

        $SourceHash = $null
        $InspectResult = docker image inspect $ImageTag --format "{{index .Config.Labels \"$LabelKey\"}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $InspectResult) {
            $SourceHash = $InspectResult.Trim()
        }

        $Entry = @{
            image       = $ImageTag
            source_hash = $SourceHash
            git_commit  = $GitCommit
        }

        if ($ExtraContainerMetadata -and $ExtraContainerMetadata.ContainsKey($ServiceName)) {
            $Override = $ExtraContainerMetadata[$ServiceName]
            if ($Override -is [hashtable]) {
                foreach ($Key in $Override.Keys) {
                    $Entry[$Key] = $Override[$Key]
                }
            }
        }

        $Containers[$ServiceName] = $Entry
    }

    $Manifest = @{
        version       = 1
        deployed_at   = (Get-Date -Format 'o')
        git_commit    = $GitCommit
        git_branch    = $GitBranch
        git_remote    = $GitRemote
        image_version = $ImageVersion
        containers    = $Containers
    }

    $OutputDir = Join-Path $TargetDir "Tasks/Logs"
    $OutputPath = Join-Path $OutputDir "deploy-manifest.json"

    if ($PSCmdlet.ShouldProcess($OutputPath, "Write deploy manifest")) {
        $null = New-Item -ItemType Directory -Path $OutputDir -Force
        $Manifest | ConvertTo-Json -Depth 10 | Write-AtomicFile -Path $OutputPath -Encoding utf8
        Write-SetupLog "Deploy manifest written to $OutputPath ($($Containers.Count) containers)"
    }
}
