# Module concern map — documents separation of concerns within SalmonRun.Config
#
# Schema validation (diagnostic):
#   Test-SalmonRunConfigSchema       — validates Provider/Agent/Policy config objects
#
# Config I/O (read/write):
#   Read-InstallJson                — cached JSON file reader
#   Find-InstallJsonPath            — searches env var, repo root, home dir, CWD walk
#   Update-InstallJsonKey           — writes a specific dotted key path
#   Update-InstallJsonTestStatus    — writes container health status to testStatus
#   Export-InstallJsonToEnv         — exports ~8 common values to process env vars
#
# Config resolution (env → file → prompt chain):
#   Get-ConfigValue                 — 4-source precedence chain
#   Get-SilentToggle                — feature toggle resolution
#   Resolve-FleetConfig             — merges install.json + env + defaults
#   Resolve-StringPlaceholders      — replaces {PlaceholderName} tokens
#   Get-DefaultDomainSuffix         — domain suffix from env, install.json, or fallback
#   Get-DefaultProjectCode          — project code from env, install.json, or fallback
#
# Owner placeholders (identity):
#   Get-OwnerPlaceholders           — reads ~/.ORCHESTRATOR/owner-config.json
#   Set-OwnerPlaceholders           — interactive wizard to configure owner values
