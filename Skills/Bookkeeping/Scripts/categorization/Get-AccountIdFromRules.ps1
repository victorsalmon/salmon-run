<#
.SYNOPSIS
    Unified categorization — reads from categorization-rules.json (canonical source).
.DESCRIPTION
    Applies description_overrides → vendor_keyword_rules → catch-all to determine
    the account_id for a transaction. Resolves entity-specific account IDs via cloud-books-entities.json.
    Replaces the hardcoded Get-VendorAccountId in Invoke-BookkeepingEnrichment.ps1.
.PARAMETER Vendor
    Normalized vendor/payee name.
.PARAMETER Description
    Transaction description or notes (used for description_overrides).
.PARAMETER EntitySlug
    Entity identifier: "intersite-consulting" or "room-rentals".
.PARAMETER RulesPath
    Path to categorization-rules.json. Auto-resolved if omitted.
.PARAMETER EntitiesPath
    Path to cloud-books-entities.json. Auto-resolved if omitted.
.PARAMETER PassThru
    Return full result object (account_name, account_id, rule_source, matched_pattern).
.EXAMPLE
    Get-AccountIdFromRules -Vendor "Petro-Canada"
    Returns "93310000000000424"
.EXAMPLE
    Get-AccountIdFromRules -Vendor "Amazon.ca" -Description "WAVE SV9T" -PassThru
    Returns full result with account_name="Consulting Revenue", rule_source="description_override"
#>
function Get-AccountIdFromRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Vendor,

        [string]$Description,

        [string]$EntitySlug = "intersite-consulting",

        [string]$RulesPath,

        [string]$EntitiesPath,

        [switch]$PassThru
    )

    # --- resolve paths ---
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent }
    # Walk up from Skills/Bookkeeping/Scripts/ to repo root
    $probe = $scriptDir
    $projectRoot = $null
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-Path (Join-Path $probe ".git")) {
            $projectRoot = $probe
            break
        }
        $probe = Split-Path $probe -Parent
        if (-not $probe) { break }
    }
    if (-not $projectRoot) { $projectRoot = (Get-Item $PWD).FullName }

    if (-not $RulesPath) {
        $RulesPath = Join-Path $projectRoot "Skills\Bookkeeping\tx-categorization\categorization-rules.json"
    }
    if (-not $EntitiesPath) {
        $EntitiesPath = Join-Path $projectRoot "Skills\Bookkeeping\cloud-books-entities.json"
    }

    # --- load rules ---
    if (-not (Test-Path $RulesPath)) { throw "Rules file not found: $RulesPath" }
    $rules = Get-Content $RulesPath -Raw | ConvertFrom-Json

    # --- load entities ---
    $entities = $null
    if (Test-Path $EntitiesPath) {
        $entities = Get-Content $EntitiesPath -Raw | ConvertFrom-Json
    }

    $result = [PSCustomObject]@{
        account_name    = $null
        account_id      = $null
        rule_source     = "unmatched"
        matched_pattern = $null
    }

    # Build the search text from vendor + description
    $searchText = $Vendor
    if ($Description) { $searchText += " $Description" }
    $searchUpper = $searchText.ToUpperInvariant()
    $vendorUpper = $Vendor.ToUpperInvariant()

    # 1. Description overrides (exact substring match against vendor + description)
    foreach ($override in $rules.description_overrides) {
        if ($searchUpper -match [regex]::Escape($override.match.ToUpperInvariant())) {
            $result.account_name = $override.account_name
            $result.account_id   = $override.account_id
            $result.rule_source  = "description_override"
            $result.matched_pattern = $override.match
            break
        }
    }

    # 2. Vendor keyword rules (regex, uppercase)
    if (-not $result.account_id) {
        foreach ($rule in $rules.vendor_keyword_rules) {
            if ($vendorUpper -match $rule.pattern) {
                $result.account_name = $rule.account_name
                $result.account_id   = $rule.account_id
                $result.rule_source  = "vendor_keyword_rule"
                $result.matched_pattern = $rule.pattern
                break
            }
        }
    }

    # 3. Entity-specific vendor_account_map (direct vendor → account_id)
    if (-not $result.account_id -and $entities) {
        $vam = $entities.entities.$EntitySlug.vendor_account_map
        if ($vam) {
            $lowerVendor = $Vendor.ToLowerInvariant()
            foreach ($kv in $vam.psobject.Properties) {
                if ($lowerVendor -match [regex]::Escape($kv.Name.ToLowerInvariant())) {
                    $result.account_id   = $kv.Value
                    $result.rule_source  = "vendor_account_map"
                    $result.matched_pattern = $kv.Name
                    # Look up the account name from acct_names
                    $result.account_name = $rules.acct_names.$($kv.Value)
                    if (-not $result.account_name) { $result.account_name = $kv.Name }
                    break
                }
            }
        }
    }

    # 4. Entity-specific vendor_mappings (payee pattern → short account name)
    if (-not $result.account_id -and $entities) {
        $vm = $entities.entities.$EntitySlug.vendor_mappings
        if ($vm) {
            foreach ($kv in $vm.psobject.Properties) {
                if ($vendorUpper -match [regex]::Escape($kv.Name.ToUpperInvariant())) {
                    $shortName = $kv.Value
                    # Map short name → account_id via entities.categories
                    $cats = $entities.entities.$EntitySlug.categories
                    if ($cats -and $cats.$shortName) {
                        $result.account_id = $cats.$shortName
                        $result.rule_source = "vendor_mapping"
                        $result.matched_pattern = $kv.Name
                        # Look up account name from acct_names or short name
                        $result.account_name = $rules.acct_names.$($cats.$shortName)
                        if (-not $result.account_name) { $result.account_name = $shortName }
                    }
                    break
                }
            }
        }
    }

    # 5. Catch-all
    if (-not $result.account_id) {
        $result.account_name = "Other Expenses"
        $result.rule_source  = "catch-all"
        $result.account_id   = "93310000000000460"
        # Check if entity has a different Other Expenses account
        if ($EntitySlug -ne "intersite-consulting" -and $entities) {
            $resolvedId = Resolve-EntityAccountId -AccountName "Other Expenses" -EntitySlug $EntitySlug -Entities $entities
            if ($resolvedId) { $result.account_id = $resolvedId }
        }
    }

    # 6. Resolve entity-specific account ID for non-Intersite entities
    #    The JSON has Intersite IDs hardcoded; for other entities, look up by account name.
    if ($EntitySlug -ne "intersite-consulting" -and $entities -and $result.account_name) {
        $resolvedId = Resolve-EntityAccountId `
            -AccountName $result.account_name `
            -EntitySlug $EntitySlug `
            -Entities $entities
        if ($resolvedId) {
            $result.account_id = $resolvedId
        }
    }

    if ($PassThru) { return $result }
    return $result.account_id
}


function Resolve-EntityAccountId {
    param(
        [string]$AccountName,
        [string]$EntitySlug,
        [pscustomobject]$Entities
    )

    $nameToShort = @{
        "Automobile Expense"        = "Automobile"
        "Software & IT Expenses"    = "ITInternet"
        "Office & General Expenses" = "OfficeSupplies"
        "Repairs and Maintenance"   = "Repairs"
        "Professional Fees"         = "Consultant"
        "Advertising And Marketing" = "Advertising"
        "Bank Fees and Charges"     = "BankFees"
        "Credit Card Charges"       = "CreditCard"
        "Insurance"                 = "Insurance"
        "Other Expenses"           = "Other"
        "Lease Expense"            = "Lease"
        "Shareholder Loan"         = "ShareholderLoan"
        "Dividends Paid"           = "DividendsPaid"
        "Consulting Revenue"       = "ConsultingRevenue"
        "Exclude"                  = "Exclude"
        "Income Tax Expense"       = "IncomeTaxExpense"
        "Credit Card Payments"     = "CreditCardPayments"
    }

    $shortName = $nameToShort[$AccountName]
    if (-not $shortName) { return $null }

    # Try categories first (expense accounts)
    $cats = $Entities.entities.$EntitySlug.categories
    if ($cats -and $cats.$shortName) {
        return $cats.$shortName
    }

    # Fall back to accounts (all accounts including income/balance)
    $accts = $Entities.entities.$EntitySlug.accounts
    if ($accts -and $accts.$shortName) {
        return $accts.$shortName.account_id
    }

    return $null
}
