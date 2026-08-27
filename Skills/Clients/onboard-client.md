# Onboard Client

Full client onboarding workflow: create folder structure, provision email, bootstrap GitHub repo, register email monitoring.

## Pipeline Position

Onboarding is the first step in the client lifecycle. Run after the client has filled out the onboarding checklist and all provider credentials are available.

```
Client Signs → Checklist → Onboarding → Active
```

## Prerequisites

- [ ] onboarding checklist filled out by client
- [ ] cPanel API token or password available (set `$env:CPANEL_API_TOKEN`)
- [ ] `gh` CLI installed and authenticated (`gh auth status`)
- [ ] AWS credentials available for Secrets Manager (if using `-StoreInAwsSm`)
- [ ] `providers-config.json` configured with active providers

## Quick Start

```powershell
# Interactive mode (prompts for missing info)
./Skills/Clients/Initialize-ClientEnvironment.ps1 -ClientSlug "acme-corp" -Interactive

# Non-interactive with email and repo
./Skills/Clients/Initialize-ClientEnvironment.ps1 -ClientSlug "acme-corp" -ClientName "Acme Corp" -SkipEmail:$false -SkipRepo:$false

# Resume from checkpoint after failure
./Skills/Clients/Initialize-ClientEnvironment.ps1 -ClientSlug "acme-corp" -ResumeFrom "provision-email"

# Minimal (folder only, no external calls)
./Skills/Clients/Initialize-ClientEnvironment.ps1 -ClientSlug "acme-corp" -SkipEmail -SkipRepo
```

## Manual Steps

When automation fails, run these steps manually:

### Email (cPanel)
1. Log in to cPanel at `https://dotcanada.com:2083`
2. Go to **Email** → **Email Accounts**
3. Create mailbox: enter local part, domain, and password
4. Set quota (default 1024 MB)

### GitHub Repo
1. Go to `https://github.com/organizations/{org}/repositories/new`
2. Name: `{client-slug}`, visibility: Private
3. Do NOT initialize with README — the local scaffold has initial content
4. Run locally: `git remote add origin git@github.com:{org}/{slug}.git && git push -u origin main`

## Phase Reference

| Phase | Script | Purpose | Expected Output |
|-------|--------|---------|----------------|
| Validate Checklist | (manual) | Ensure client info is complete | Filled checklist |
| Create Folder | `New-ClientFolder.ps1` | Scaffold directory structure | `~/Clients/{slug}/` with all subdirs |
| Provision Email | `New-ClientEmail.ps1` | Create mailbox, store credentials | Mailbox created, credentials stored |
| Create Repo | `New-ClientGitHubRepo.ps1` | GitHub repo creation + push | Private repo at `github.com/{org}/{slug}` |
| Register Monitoring | `Register-ClientEmailMonitor.ps1` | Add to IMAP poller schedule | Tempo schedule file created |

### Common Failures

| Phase | Failure | Fix |
|-------|---------|-----|
| Create Folder | Template not found | Ensure `Infrastructure/clients/templates/bookkeeping/folder-layout.json` exists |
| Provision Email | Auth error | Check `$env:CPANEL_API_TOKEN` or cPanel password |
| Create Repo | `gh` not authenticated | Run `gh auth login` |
| Create Repo | Repo name taken | Use a different slug |
| Register Monitoring | No Tempo service | Create fallback via cron directly |

## Provider Switching

To add a new email provider:

1. Implement `IEmailAdapter` interface (see `Infrastructure/providers/email/IEmailAdapter.md`)
2. Add adapter file to `Infrastructure/providers/email/`
3. Register in `Infrastructure/clients/providers-config.json` under `email.providers`
4. Write tests following `CpanelEmailAdapter.Tests.mjs` pattern

## Exit Criteria

After onboarding, verify:

- [ ] `~/Clients/{slug}/` exists with correct structure
- [ ] Email mailbox `{mailbox}@{domain}` exists and is reachable
- [ ] `Tasks/Schedule/client-email-{slug}.json` exists (if monitoring registered)
- [ ] GitHub repo `{org}/{slug}` exists (private)
<!-- doc-lint: exempt -->
- [ ] Entry in `Infrastructure/clients/email-monitor-registry.json`
- [ ] Credentials stored in AWS SM (if `-StoreInAwsSm` used)

## See Also

- [ADR-0044: Product-Agnostic Integration Pattern](../../docs/Reference/Decisions/0044-product-agnostic-integration-pattern.md)
- [Provider Configuration](../../Infrastructure/clients/providers-config.json)
- [Email Provider Interface](../../Infrastructure/providers/email/IEmailAdapter.md)
- Related skills: `clients/new-client-folder`
