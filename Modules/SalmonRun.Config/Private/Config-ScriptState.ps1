$homeDir = Get-HomeDir
$script:OwnerConfigPath = if ($homeDir) { Join-Path $homeDir ".ORCHESTRATOR" "owner-config.json" } else { $null }

$script:InstallJsonCache = $null
$script:InstallJsonCacheTime = $null
