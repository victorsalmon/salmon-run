# 1Cleanup-AWS.ps1

AWS IAM cleanup tool for ORCHESTRATOR fleets.

## Purpose

Lists all `OC-*` IAM users, optionally disables/deletes their access keys, and deletes the users. Uses the same SSO credentials as other provisioning scripts.

## Parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `SsoProfile` | string | AWS SSO profile name (default: `$env:AWS_SSO_PROFILE`) |
| `WhatIf` | switch | Show what would be deleted without making changes |
| `Force` | switch | Skip confirmation prompts |

## What it does

1. Lists all IAM users matching `OC-*`
2. For each user, lists access keys and inline policies
3. Displays a summary (creation date, key count, policy count, ARN)
4. In `-WhatIf` mode: shows what would be deleted and exits
5. In normal mode: prompts for confirmation (unless `-Force`)
6. Deletes access keys → deletes inline policies → deletes user
7. Reports deleted count and failed count

## Usage

```powershell
# Dry run — see what would be deleted
pwsh ./Scripts/1Cleanup-AWS.ps1 -WhatIf

# Interactive cleanup (prompts for confirmation)
pwsh ./Scripts/1Cleanup-AWS.ps1

# Skip confirmation
pwsh ./Scripts/1Cleanup-AWS.ps1 -Force

# Use specific SSO profile
pwsh ./Scripts/1Cleanup-AWS.ps1 -SsoProfile my-profile
```

## Safety features

- Requires explicit `yes` confirmation unless `-Force` is used
- `-WhatIf` mode makes no changes
- Lists all keys and policies before deletion
- Reports success/failure per key, policy, and user

## Notes

- This script is for manual decommissioning only — `1Provision.ps1` handles automatic orphan cleanup during deploy
- Exits with code `0` if no `OC-*` users are found
- Uses `Invoke-NativeCommand` for all AWS CLI calls to capture success/failure
