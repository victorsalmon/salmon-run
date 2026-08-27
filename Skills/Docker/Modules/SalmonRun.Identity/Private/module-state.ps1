$script:RoleProviderKeyMap = @{
    "WORK" = @("openrouter_api_key")
    "BASE" = @("openrouter_api_key")
}
$registry = Get-PortRegistry -ErrorAction SilentlyContinue
if ($registry -and $registry.host.gateway) {
    $gw = $registry.host.gateway
    $script:AgentRolePorts = @{}
    $gw.PSObject.Properties | ForEach-Object {
        $script:AgentRolePorts[$_.Name] = @{ Base = [int]$_.Value.base; Max = [int]$_.Value.max }
    }
} else {
    $script:AgentRolePorts = @{
        base = @{ Base = 20300; Max = 3 }
    }
}
$script:RoleFileMap = @{
    "WORK" = @("soul.md", "identity.md", "system-prompt.md", "agents.md", "memory.md", "tools.md")
    "BASE" = @("soul.md", "identity.md", "system-prompt.md", "agents.md", "heartbeat.md", "memory.md", "tools.md")
}
$script:SharedFiles = @("User.md", "environment.md", "boundaries.md", "protocols.md", "projects.md")
