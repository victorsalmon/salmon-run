<#
.SYNOPSIS
    Returns the list of active agent instance IDs from Docker Swarm services.
.DESCRIPTION
    Queries Docker for running oc-* services and extracts their instance
    IDs from service labels or names.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    Array of integer agent instance IDs.
#>
function Get-ActiveAgentIds {
        [OutputType([int])]
        param()
        $ServiceList = docker stack services $StackName --format "{{.Name}}" 2>$null
        $Ids = @()
        foreach ($Svc in $ServiceList) {
            if ($Svc -match "-(\d+)$") {
                $Ids += $Matches[1]
            }
        }
        return ,($Ids | Sort-Object -Unique)
    }
