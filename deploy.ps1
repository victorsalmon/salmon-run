<#
.SYNOPSIS
    Build and deploy salmon-run as a local container or Docker Swarm service.

.DESCRIPTION
    - Local: `docker compose up --build`
    - Swarm: `docker stack deploy -c docker-compose.swarm.yml salmon-run`

    The script is safe to run without credentials and uses the public Dockerfile.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'swarm')]
    [string]$Mode = 'local'
)

$ErrorActionPreference = 'Stop'

$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

if ($Mode -eq 'local') {
    & docker compose -f (Join-Path $repoRoot 'docker-compose.yml') up --build --remove-orphans
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
} else {
    $swarmFile = Join-Path $repoRoot 'docker-compose.swarm.yml'
    $imageTag = 'salmon-run:latest'

    & docker build -t $imageTag $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }

    & docker stack deploy -c $swarmFile salmon-run
    if ($LASTEXITCODE -ne 0) { throw "docker stack deploy failed" }
}
