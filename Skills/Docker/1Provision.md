# 1Provision.ps1

Merged provisioner for ORCHESTRATOR identity secrets and AWS infrastructure.

## Purpose

Validates sovereignty tier, hydrates secrets from AWS Secrets Manager, creates Bedrock inference profiles, provisions per-agent IAM users, and verifies credential isolation. Replaces the legacy `1Secrets.ps1`, `1KeyTest.ps1`, and `1AWS.ps1` scripts.

## Parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `Phase` | string | Phase to run: `All`, `KeyTest`, `Secrets`, `AWS`, or `None` (default `All`) |

## Phases

### KeyTest

Runs `Test-Sovereignty` to validate the configured tier and provider catalog alignment.

### Secrets

Runs `Invoke-SecretHydration` to pull identity keys from AWS Secrets Manager into process RAM.

### AWS

1. **Identity verification** — validates `ORCHESTRATOR_SECRET_PREFIX`, `INSTALL_PROJECT`, and `INSTALL_ROLE` are set
2. **AWS key hydration** — pulls AWS credentials on demand via `Import-SecretsFromAws`
3. **Bedrock setup** — creates inference profiles (skipped for CODE role)
4. **Orphan cleanup** — removes IAM users from decommissioned containers (ORCH-only trigger)
5. **IAM provisioning** — creates per-agent IAM users with sovereignty-appropriate policies
6. **Credential isolation tests** — verifies agent and sentry credentials cannot access each other's resources
7. **Cache cleanup** — clears in-memory secret cache

## Usage

```powershell
# Full provisioning (called by 0setup.ps1 per agent)
pwsh ./Scripts/1Provision.ps1 -Phase All

# Secret hydration only
pwsh ./Scripts/1Provision.ps1 -Phase Secrets

# AWS infrastructure only
pwsh ./Scripts/1Provision.ps1 -Phase AWS

# Dot-source for testing (skips dispatch)
pwsh ./Scripts/1Provision.ps1 -Phase None
```

## Notes

- `Phase None` is used when dot-sourcing for Pester tests to skip all dispatch logic
- Explicitly resets `$global:LASTEXITCODE = 0` at the end to prevent stale non-zero exit codes from bare `aws` commands
- Sentry IAM user creation is gated on `INSTALL_ROLE` being `ORCH`
