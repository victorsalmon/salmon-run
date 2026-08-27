<#
.SYNOPSIS
    Compares old vs new categorization rules and identifies Zoho transactions needing reclassification.
.DESCRIPTION
    When categorization rules change (e.g. v1.3.0 -> v1.4.0), transactions already categorized
    in Zoho retain the old classification. This script diffs the rules, queries Zoho for affected
    bank transactions, and produces a reclassification plan (JSON) for review and execution.

    Phases:
      1 — Diff rules: Compare income_rules + vendor_keyword_rules between old and new JSON
      2 — Query Zoho: Fetch all bank transactions for the account
      3 — Match: Apply old and new rules to each transaction, detect classification changes
      4 — Output: Write reclassification plan to stdout or file
.PARAMETER OldRulesPath
    Path to old categorization-rules.json (previous version).
.PARAMETER NewRulesPath
    Path to new categorization-rules.json (current version).
.PARAMETER EntitySlug
    Entity identifier: "intersite-consulting" or "room-rentals".
.PARAMETER OrgId
    Zoho organization ID (overrides auto-resolution from credentials).
.PARAMETER BankAccountId
    Zoho bank account ID to query (if omitted, queries all bank accounts for the entity).
.PARAMETER OutputPath
    Write the reclassification plan to this file.
.PARAMETER DryRun
    Output the reclassification plan without executing.
.PARAMETER Execute
    Apply reclassifications via Zoho PUT /banktransactions/{id}.
.PARAMETER TokenCacheDir
    Directory for Zoho OAuth token cache (defaults to current working directory).
.EXAMPLE
    .\Invoke-ReclassificationDiff -OldRulesPath rules-v1.3.0.json -NewRulesPath rules-v1.4.0.json -DryRun
    Outputs the reclassification plan for review.
#>
param(
    [Parameter(Mandatory)]
    [string]$OldRulesPath,

    [Parameter(Mandatory)]
    [string]$NewRulesPath,

    [string]$EntitySlug = "intersite-consulting",

    [string]$OrgId,

    [string]$BankAccountId,

    [string]$OutputPath,

    [switch]$DryRun,

    [switch]$Execute,

    [string]$TokenCacheDir = (Get-Location).Path
)

$scriptDir = Split-Path $PSCommandPath -Parent
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..\..\..")

# Detect Node.js
$node = Get-Command "node" -ErrorAction SilentlyContinue
if (-not $node) { throw "Node.js is required but not found in PATH" }

# ── Phase 0: Load and validate rule files ──────────────────────────────────
Write-Host "=== Invoke-ReclassificationDiff ===" -ForegroundColor Cyan
Write-Host "Entity: $EntitySlug"
Write-Host "Old rules: $OldRulesPath"
Write-Host "New rules: $NewRulesPath`n"

if (-not (Test-Path $OldRulesPath)) { throw "Old rules file not found: $OldRulesPath" }
if (-not (Test-Path $NewRulesPath)) { throw "New rules file not found: $NewRulesPath" }

$oldRules = Get-Content $OldRulesPath -Raw | ConvertFrom-Json
$newRules = Get-Content $NewRulesPath -Raw | ConvertFrom-Json

# ── Phase 1: Diff rules ────────────────────────────────────────────────────
Write-Host "Phase 1: Diffing rules..." -ForegroundColor Yellow

$diffResult = @{ added = @(); removed = @(); changed = @() }

function Compare-RuleSet {
    param([string]$SetName, $OldSet, $NewSet, [string[]]$CompareKeys)

    $oldByPattern = @{}
    if ($OldSet) { foreach ($r in $OldSet) { $oldByPattern[$r.pattern] = $r } }

    $seen = @{}

    if ($NewSet) {
        foreach ($r in $NewSet) {
            $seen[$r.pattern] = $true
            $old = $oldByPattern[$r.pattern]
            if (-not $old) {
                $diffResult.added += @{
                    rule_set = $SetName
                    pattern  = $r.pattern
                    new      = $r
                }
            } else {
                $changed = $false
                foreach ($key in $CompareKeys) {
                    $oVal = if ($old.$key -is [int] -or $old.$key -is [double]) { "$($old.$key)" } else { $old.$key }
                    $nVal = if ($r.$key -is [int] -or $r.$key -is [double]) { "$($r.$key)" } else { $r.$key }
                    if ($oVal -ne $nVal) { $changed = $true; break }
                }
                if ($changed) {
                    $diffResult.changed += @{
                        rule_set  = $SetName
                        pattern   = $r.pattern
                        old       = $old
                        new       = $r
                    }
                }
            }
        }
    }

    foreach ($pattern in $oldByPattern.Keys) {
        if (-not $seen.ContainsKey($pattern)) {
            $diffResult.removed += @{
                rule_set = $SetName
                pattern  = $pattern
                old      = $oldByPattern[$pattern]
            }
        }
    }
}

$incomeKeys = @("account_id", "account_name", "income_type", "confidence", "priority")
$vendorKeys = @("account_id", "account_name")

Compare-RuleSet -SetName "income_rules" -OldSet $oldRules.income_rules -NewSet $newRules.income_rules -CompareKeys $incomeKeys
Compare-RuleSet -SetName "vendor_keyword_rules" -OldSet $oldRules.vendor_keyword_rules -NewSet $newRules.vendor_keyword_rules -CompareKeys $vendorKeys

Write-Host "  Added:   $($diffResult.added.Count) rules"
Write-Host "  Removed: $($diffResult.removed.Count) rules"
Write-Host "  Changed: $($diffResult.changed.Count) rules"

if ($diffResult.added.Count -eq 0 -and $diffResult.removed.Count -eq 0 -and $diffResult.changed.Count -eq 0) {
    Write-Host "  No rule changes detected. Nothing to reclassify." -ForegroundColor Green
    exit 0
}

# ── Phase 2: Query Zoho bank transactions ──────────────────────────────────
Write-Host "`nPhase 2: Querying Zoho bank transactions..." -ForegroundColor Yellow

# Resolve Zoho credentials and query transactions via Node.js
$zohoQueryScript = @'
import { ZohoAuth } from 'FILE:///ZOHO_AUTH_PATH';
const fs = require('fs');

const ORG_ID = 'ORG_ID_PLACEHOLDER';
const ACCT_ID = 'ACCT_ID_PLACEHOLDER';

async function main() {
    // Read credentials from environment (set by PowerShell)
    const s = JSON.parse(process.env.ZOHO_SECRETS);

    const auth = new ZohoAuth({
        clientId: s.ZOHO_BOOKS_ID,
        clientSecret: s.ZOHO_BOOKS_SECRET,
        refreshToken: s.ZOHO_BOOKS_REFRESH,
        stateDir: 'TOKEN_CACHE_DIR_PLACEHOLDER'
    });

    const token = await auth.getToken();
    const headers = { Authorization: 'Zoho-oauthtoken ' + token };

    // Fetch bank transactions (all statuses) for the target account
    const allTxns = [];
    const accountsToQuery = ACCT_ID ? [ACCT_ID] : [];

    for (const acctId of accountsToQuery) {
        let page = 1;
        while (true) {
            const url = 'https://www.zohoapis.com/books/v3/banktransactions'
                + '?organization_id=' + ORG_ID
                + '&account_id=' + acctId
                + '&page=' + page
                + '&per_page=200'
                + '&sort_column=date'
                + '&sort_order=D';

            const r = await fetch(url, { headers });
            const d = await r.json();
            if (!d.banktransactions || d.banktransactions.length === 0) break;

            // Attach reconcile_status for each transaction
            for (const txn of d.banktransactions) {
                allTxns.push({
                    transaction_id: txn.transaction_id || txn.bank_transaction_id,
                    description: txn.description || '',
                    amount: parseFloat(txn.amount) || 0,
                    date: txn.date || txn.transaction_date || '',
                    account_id: acctId,
                    status: txn.status || '',
                    reconcile_status: txn.reconcile_status || txn.is_reconciled || 'false',
                    is_reconciled: !!(txn.reconcile_status === 'reconciled' || txn.is_reconciled)
                });
            }

            if (!d.page_context?.has_more_page) break;
            page++;
        }
    }

    console.log(JSON.stringify(allTxns));
}

main().catch(e => { console.error('ZOHO_ERROR: ' + e.message); process.exit(1); });
'@

# Resolve OrgId
$resolvedOrgId = $OrgId
if (-not $resolvedOrgId) {
    Write-Host "  Resolving OrgId for entity '$EntitySlug'..." -ForegroundColor DarkYellow
    $creds = & node -e "
        import('file:///$($scriptDir -replace '\\', '/')/resolve-zoho-creds.mjs').then(m => {
            const c = m.resolveSync({ stateDir: '$($TokenCacheDir -replace '\\', '/')' });
            const oid = m.getOrgId(c, '$EntitySlug');
            console.log(JSON.stringify({ ZOHO_BOOKS_ID: c.ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET: c.ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH: c.ZOHO_BOOKS_REFRESH, ORG_ID: oid }));
        }).catch(e => { process.stderr.write('CRED_ERROR: ' + e.message); process.exit(1); });
    " 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errMsg = ($creds | Out-String).Trim()
        throw "Failed to resolve Zoho credentials: $errMsg"
    }
    $credsObj = $creds | ConvertFrom-Json
    $resolvedOrgId = $credsObj.ORG_ID
    $env:ZOHO_SECRETS = ($credsObj | Select-Object -Property ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH) | ConvertTo-Json -Compress
    Write-Host "  OrgId: $resolvedOrgId" -ForegroundColor DarkYellow
}

# Resolve BankAccountId if not provided
$resolvedAcctId = $BankAccountId
if (-not $resolvedAcctId) {
    Write-Host "  Resolving bank account IDs for entity '$EntitySlug'..." -ForegroundColor DarkYellow
    $entityConfig = Join-Path $repoRoot "Skills\Bookkeeping\cloud-books-entities.json"
    if (Test-Path $entityConfig) {
        $config = Get-Content $entityConfig -Raw | ConvertFrom-Json
        $entity = $config.entities.$EntitySlug
        if ($entity -and $config.bank_accounts) {
            $accts = @()
            foreach ($kv in $config.bank_accounts.PSObject.Properties) {
                if ($kv.Value.entity -eq $EntitySlug -and $kv.Value.account_id) {
                    $accts += $kv.Value.account_id
                }
            }
            if ($accts.Count -gt 0) {
                $resolvedAcctId = $accts -join ','
                Write-Host "  Bank accounts: $resolvedAcctId" -ForegroundColor DarkYellow
            }
        }
    }
}

# Query transactions using Node.js
Write-Host "  Querying bank transactions from Zoho..." -ForegroundColor DarkYellow
$zohoAuthPath = $scriptDir -replace '\\', '/' -replace '^([A-Z]):', '/$1'
$zohoAuthPath = "$zohoAuthPath/zoho-auth.js"
$queryScript = $zohoQueryScript `
    -replace 'FILE:///ZOHO_AUTH_PATH', "file:///$zohoAuthPath" `
    -replace "'ORG_ID_PLACEHOLDER'", "'$resolvedOrgId'" `
    -replace "'ACCT_ID_PLACEHOLDER'", "'$($resolvedAcctId -replace "'","''")'" `
    -replace "'TOKEN_CACHE_DIR_PLACEHOLDER'", "'$($TokenCacheDir -replace '\\', '/')'"

$queryResult = $queryScript | & $node --input-type=module 2>&1
if ($LASTEXITCODE -ne 0) {
    $errLines = ($queryResult | Out-String).Trim()
    $errMatch = $errLines | Select-String -Pattern "ZOHO_ERROR:"
    if ($errMatch) {
        throw "Zoho API error: $($errMatch.Matches[0].Groups[0].Value)"
    }
    throw "Zoho query failed: $errLines"
}

$transactions = $queryResult | ConvertFrom-Json
Write-Host "  Retrieved $($transactions.Count) transactions" -ForegroundColor Green

if ($transactions.Count -eq 0) {
    Write-Host "  No transactions found. Nothing to reclassify." -ForegroundColor Yellow
    exit 0
}

# ── Phase 3: Match transactions against old vs new rules ───────────────────
Write-Host "`nPhase 3: Matching transactions against rules..." -ForegroundColor Yellow

function Test-RuleMatch {
    param([string]$Text, $Rules, [string]$RuleSet)

    if (-not $Rules) { return $null }

    $sortedRules = $Rules | Sort-Object { if ($_.priority -ge 0) { [int]$_.priority } else { 999 } }
    $textUpper = $Text.ToUpperInvariant()

    foreach ($rule in $sortedRules) {
        try {
            if ($textUpper -match $rule.pattern) {
                $amountMatch = $true
                $amt = if ($rule.amount_min -and $rule.amount_min -gt 0) { if ($_.amount_min -gt $rule.amount_min) { $amountMatch = $false } }
                if ($amountMatch) {
                    return @{
                        pattern      = $rule.pattern
                        account_id   = $rule.account_id
                        account_name = $rule.account_name
                        income_type  = $rule.income_type
                        confidence   = $rule.confidence
                        rule_set     = $RuleSet
                    }
                }
            }
        } catch { continue }
    }
    return $null
}

function Get-Classification {
    param([string]$Description, $Rules)

    # First try income_rules
    $match = Test-RuleMatch -Text $Description -Rules $Rules.income_rules -RuleSet "income_rules"
    if ($match) { return $match }

    # Then try vendor_keyword_rules
    $match = Test-RuleMatch -Text $Description -Rules $Rules.vendor_keyword_rules -RuleSet "vendor_keyword_rules"
    if ($match) { return $match }

    # No match
    return @{
        pattern      = $null
        account_id   = $null
        account_name = "No Match"
        income_type  = $null
        confidence   = "none"
        rule_set     = "none"
    }
}

$reclassifications = @()
$reconciledBlocked = @()
$noChange = 0

foreach ($txn in $transactions) {
    $desc = "$($txn.description)"
    if (-not $desc) { $noChange++; continue }

    $oldMatch = Get-Classification -Description $desc -Rules $oldRules
    $newMatch = Get-Classification -Description $desc -Rules $newRules

    $oldId = if ($oldMatch.account_id) { $oldMatch.account_id.Trim() } else { "" }
    $newId = if ($newMatch.account_id) { $newMatch.account_id.Trim() } else { "" }

    if ($oldId -ne $newId) {
        $entry = @{
            transaction_id   = $txn.transaction_id
            date             = $txn.date
            amount           = [double]$txn.amount
            description      = $desc
            old_account_id   = $oldId
            old_account_name = $oldMatch.account_name
            old_match        = $oldMatch.pattern
            new_account_id   = $newId
            new_account_name = $newMatch.account_name
            new_match        = $newMatch.pattern
            is_reconciled    = $txn.is_reconciled
        }

        if ($txn.is_reconciled) {
            $reconciledBlocked += $entry
        } else {
            $reclassifications += $entry
        }
    } else {
        $noChange++
    }
}

Write-Host "  Reclassifications needed: $($reclassifications.Count)" -ForegroundColor Cyan
if ($reconciledBlocked.Count -gt 0) {
    Write-Host "  Reconciled (manual): $($reconciledBlocked.Count)" -ForegroundColor Magenta
}
Write-Host "  No change: $noChange"

# ── Phase 4: Build and output reclassification plan ────────────────────────
Write-Host "`nPhase 4: Generating reclassification plan..." -ForegroundColor Yellow

$plan = @{
    generated        = (Get-Date -Format "o")
    new_version      = if ($newRules._meta.version) { $newRules._meta.version } else { $null }
    old_version      = if ($oldRules._meta.version) { $oldRules._meta.version } else { $null }
    entity           = $EntitySlug
    org_id           = $resolvedOrgId
    rule_diff        = $diffResult
    reclassifications = $reclassifications
    manual_remediation_needed = $reconciledBlocked
    summary = @{
        total_transactions  = $transactions.Count
        reclassifications   = $reclassifications.Count
        manual_remediation  = $reconciledBlocked.Count
        unchanged           = $noChange
    }
}

$planJson = $plan | ConvertTo-Json -Depth 10

if ($OutputPath) {
    $planJson | Out-File -FilePath $OutputPath -Encoding utf8
    Write-Host "  Plan written to: $OutputPath" -ForegroundColor Green
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total transactions: $($transactions.Count)"
Write-Host "  Reclassifications:  $($reclassifications.Count)"
Write-Host "  Manual remediation: $($reconciledBlocked.Count)"
Write-Host "  Unchanged:          $noChange"
Write-Host "`nRule changes:"
Write-Host "  Added:   $($diffResult.added.Count)"
Write-Host "  Removed: $($diffResult.removed.Count)"
Write-Host "  Changed: $($diffResult.changed.Count)"

if ($DryRun -or -not $Execute) {
    Write-Host "`n[DRY RUN] No reclassifications applied. Use -Execute to apply." -ForegroundColor Yellow
    Write-Host $planJson
    exit 0
}

# ── Phase 5: Execute reclassifications ──────────────────────────────────────
if ($Execute) {
    Write-Host "`nPhase 5: Executing reclassifications..." -ForegroundColor Yellow

    if ($reclassifications.Count -eq 0) {
        Write-Host "  No reclassifications to apply." -ForegroundColor Green
        exit 0
    }

    $executeScript = @'
import { ZohoAuth } from 'FILE:///ZOHO_AUTH_PATH';
const fs = require('fs');

const ORG_ID = 'ORG_ID_PLACEHOLDER';
const updates = JSON.parse(process.env.RECLASS_UPDATES);

async function main() {
    const s = JSON.parse(process.env.ZOHO_SECRETS);
    const auth = new ZohoAuth({
        clientId: s.ZOHO_BOOKS_ID,
        clientSecret: s.ZOHO_BOOKS_SECRET,
        refreshToken: s.ZOHO_BOOKS_REFRESH,
        stateDir: 'TOKEN_CACHE_DIR_PLACEHOLDER'
    });

    const token = await auth.getToken();
    const headers = { Authorization: 'Zoho-oauthtoken ' + token };

    let success = 0, failed = 0;

    for (const upd of updates) {
        const url = 'https://www.zohoapis.com/books/v3/banktransactions/' + upd.transaction_id
            + '?organization_id=' + ORG_ID;

        const body = {
            account_id: upd.new_account_id,
            description: upd.description || ''
        };

        try {
            const r = await fetch(url, {
                method: 'PUT',
                headers: headers,
                body: JSON.stringify(body)
            });
            const d = await r.json();
            if (d.code === 0) {
                success++;
                process.stdout.write('.');
            } else {
                failed++;
                process.stderr.write('\n[FAIL] ' + upd.transaction_id + ' (' + upd.description?.substring(0, 40) + '): ' + (d.message || JSON.stringify(d)));
            }
        } catch (e) {
            failed++;
            process.stderr.write('\n[FAIL] ' + upd.transaction_id + ': ' + e.message);
        }

        // Rate limiting: 300ms between calls
        await new Promise(r => setTimeout(r, 300));
    }

    console.log(`\nReclassified: ${success} succeeded, ${failed} failed`);
    if (failed > 0) process.exit(1);
}

main().catch(e => { console.error('EXEC_ERROR: ' + e.message); process.exit(1); });
'@

    $execScript = $executeScript `
        -replace 'FILE:///ZOHO_AUTH_PATH', "file:///$zohoAuthPath" `
        -replace "'ORG_ID_PLACEHOLDER'", "'$resolvedOrgId'" `
        -replace "'TOKEN_CACHE_DIR_PLACEHOLDER'", "'$($TokenCacheDir -replace '\\', '/')'"

    $updatesJson = $reclassifications | ConvertTo-Json -Compress
    $env:RECLASS_UPDATES = $updatesJson

    Write-Host "  Applying $($reclassifications.Count) reclassifications..." -ForegroundColor DarkYellow
    $execResult = $execScript | & $node --input-type=module 2>&1
    $execExit = $LASTEXITCODE

    if ($execExit -ne 0) {
        Write-Host "  $execResult" -ForegroundColor Red
        Write-Host "  Some reclassifications failed." -ForegroundColor Red
    } else {
        Write-Host "  $execResult" -ForegroundColor Green
    }
}
