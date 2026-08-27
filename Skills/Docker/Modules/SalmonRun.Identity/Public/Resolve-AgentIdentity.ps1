<#
.SYNOPSIS
    Resolves agent identity (project, fleet agents) from install.json or interactive input.
.DESCRIPTION
    Reads fleet.agents from install.json directly, or prompts for agents in a
    table-style loop. Returns project code, role array, agent roles, and names.
.OUTPUTS
    PSCustomObject with ProjectCode, AgentNumber, RoleArray, AgentRoles, AgentNames.
#>
function Resolve-AgentIdentity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    @("INSTALL_ROLE", "INTERCLAW_INSTANCE_ID", "INTERCLAW_SECRET_PREFIX", "INTERCLAW_AGENT_NAME") | ForEach-Object {
        if (Get-Item -Path "Env:\$_" -ErrorAction SilentlyContinue) {
            Remove-Item -Path "Env:\$_" -ErrorAction SilentlyContinue
        }
    }

    $ProjectCode = Get-ConfigValue "INSTALL_PROJECT" "Project code (e.g. FRA)" "" -Aliases @("PROJECT_CODE")
    if ([string]::IsNullOrWhiteSpace($ProjectCode)) {
        $ProjectCode = Read-Host "Project code is required. Enter a 1-4 character project code"
        if ([string]::IsNullOrWhiteSpace($ProjectCode)) {
            Write-Information -MessageData "  [FAIL] Project code is required. Aborting." -Tags "ERROR"
            Write-SetupLog "ABORT: Project code not provided" -Level ERROR
            throw "Project code is required"
        }
    }
    Set-Item -Path "Env:\INSTALL_PROJECT" -Value $ProjectCode
    Write-SetupLog "Project code: $ProjectCode"

    # Read fleet.agents from install.json
    $InstallJson = Read-InstallJson
    $FleetAgents = [System.Collections.Generic.List[object]]::new()
    if ($InstallJson -and $InstallJson.fleet -and $InstallJson.fleet.agents -and $InstallJson.fleet.agents.Count -gt 0) {
        $FleetAgents.AddRange([object[]]$InstallJson.fleet.agents)
    }

    if ($FleetAgents.Count -eq 0) {
        Write-Information -MessageData "`n  Define your fleet agents. Leave role blank to finish." -Tags "INFO"
        $i = 1
        while ($i -le 9) {
            $role = Read-Host "  Agent $i role (ORCH/VERI/BASE) [ORCH]"
            if ([string]::IsNullOrWhiteSpace($role)) {
                if ($i -eq 1) { $role = "ORCH" } else { break }
            }
            $name = Read-Host "  Agent $i name [$role]"
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $role }
            $FleetAgents.Add([PSCustomObject]@{ role = $role.Trim().ToUpper(); name = $name.Trim() })
            $i++
        }
        Write-SetupLog "Interactive fleet: $($FleetAgents.Count) agents defined"
    }

    $AgentNumber = $FleetAgents.Count
    if ($AgentNumber -lt 1 -or $AgentNumber -gt 9) {
        Write-Information -MessageData "  [FAIL] Fleet must have 1-9 agents. Got: $AgentNumber" -Tags "ERROR"
        Write-SetupLog "ABORT: Invalid agent count=$AgentNumber" -Level ERROR
        throw "Fleet must have 1-9 agents"
    }
    Write-SetupLog "Agent count: $AgentNumber"

    $RoleArray = [System.Collections.Generic.List[string]]::new()
    $AgentNames = [System.Collections.Generic.List[string]]::new()
    $globalCounter = 1
    $AgentRoles = [System.Collections.Generic.List[object]]::new()
    $RoleIndexCounts = @{}
    # Warn if multiple ORCH agents are configured — shared state may collide
    $orchCount = ($FleetAgents | Where-Object { $_.role -eq "ORCH" }).Count
    if ($orchCount -gt 1) {
        Write-Information -MessageData "  [WARN] Multiple ORCH agents ($orchCount) configured. Ensure their InstanceIds are unique and shared-state access is coordinated." -Tags "WARN"
        Write-SetupLog "WARN: $orchCount ORCH agents configured — potential InstanceId collision" -Level WARN
    }
    for ($i = 0; $i -lt $AgentNumber; $i++) {
        $role = $FleetAgents[$i].role
        $name = $FleetAgents[$i].name
        $RoleArray.Add($role)
        $AgentNames.Add($name)

        $idx = if ($RoleIndexCounts.ContainsKey($role)) { $RoleIndexCounts[$role] + 1 } else { 0 }
        $RoleIndexCounts[$role] = $idx
        $instanceId = $globalCounter.ToString()
        $globalCounter++
        $AgentRoles.Add(@{
            Role       = $role
            Index      = $idx
            InstanceId = $instanceId
        })
    }

    $nextGlobalId = $globalCounter

    Write-Information -MessageData "`n  Fleet Configuration:" -Tags "INFO"
    Write-Information -MessageData "  Project:       $ProjectCode" -Tags "INFO"
    Write-Information -MessageData "  Agents:        $AgentNumber ($($RoleArray -join ', '))" -Tags "INFO"
    Write-Information -MessageData "  CODE Workers:  (configured next)" -Tags "INFO"
    Write-SetupLog "Fleet: Project=$ProjectCode Agents=$AgentNumber Roles=$($RoleArray -join ',')"

    $FriendlyIds = ($AgentRoles | ForEach-Object { "$($_.Role)-$($_.InstanceId)" }) -join ', '
    Write-Information -MessageData "  Instance IDs: ORCH-anchored ($FriendlyIds)" -Tags "INFO"
    Write-SetupLog "Instance IDs: $FriendlyIds"

    return [pscustomobject]@{
        ProjectCode  = $ProjectCode
        AgentNumber  = $AgentNumber
        RoleArray    = $RoleArray.ToArray()
        AgentRoles   = $AgentRoles.ToArray()
        AgentNames   = $AgentNames.ToArray()
        NextGlobalId = $nextGlobalId
    }
}

