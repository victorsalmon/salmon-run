function New-IncomeClassificationSummary {
    <#
    .SYNOPSIS
        Produces a markdown summary of income classification results grouped by auto-categorisation status.
    .DESCRIPTION
        Reads an annual bank CSV, classifies every credit transaction using Get-IncomeClassification,
        and outputs a summary report with:
          - Auto-categorised items (HIGH confidence)
          - Items needing user review (MEDIUM/LOW confidence)
          - Total income amount per account
    .PARAMETER CsvPath
        Path to the annual bank CSV file.
    .PARAMETER EntitySlug
        Entity identifier (e.g. "intersite-consulting").
    .PARAMETER AmountColumn
        Column name for the transaction amount. Default "CAD$".
    .PARAMETER Description1Column
        Column name for Description 1. Default "Description 1".
    .PARAMETER Description2Column
        Column name for Description 2. Default "Description 2".
    .EXAMPLE
        New-IncomeClassificationSummary -CsvPath "~\intersite-docs\...\2026 Fiscal Year - Intersite Transactions.csv"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$EntitySlug = "intersite-consulting",

        [string]$AmountColumn = "CAD$",

        [string]$Description1Column = "Description 1",

        [string]$Description2Column = "Description 2"
    )

    $scriptDir = Split-Path $PSCommandPath -Parent
    . (Join-Path $scriptDir "Get-IncomeClassification.ps1")

    $rows = Import-Csv $CsvPath
    $results = @()

    foreach ($row in $rows) {
        $rawAmt = $row.$AmountColumn
        if (-not $rawAmt) { continue }
        try { $amount = [double]($rawAmt -replace ',', '') } catch { continue }
        if ($amount -le 0) { continue }

        $desc1 = $row.$Description1Column
        $desc2 = $row.$Description2Column

        $classification = Get-IncomeClassification -Vendor $desc1 -Description $desc2 -Amount $amount -EntitySlug $EntitySlug

        $results += [PSCustomObject]@{
            Date             = $row.'Transaction Date'
            Vendor           = $desc1
            Description      = $desc2
            Amount           = $amount
            IncomeType       = $classification.income_type
            AccountName      = $classification.account_name
            Confidence       = $classification.confidence
            AutoCategorised  = $classification.auto_categorised
            RuleSource       = $classification.rule_source
        }
    }

    $autoItems = $results | Where-Object { $_.AutoCategorised }
    $reviewItems = $results | Where-Object { -not $_.AutoCategorised }

    $summary = @"
# Income Classification Summary

**Entity**: $EntitySlug
**File**: $CsvPath
**Total credits**: $($results.Count)
**Auto-categorised**: $($autoItems.Count)
**Needs review**: $($reviewItems.Count)

---

## Auto-Categorised Items (HIGH confidence)

These were classified automatically and can be batch-confirmed:

| Date | Vendor | Amount | Account | Income Type |
|------|--------|-------:|---------|:-----------|
"@

    foreach ($item in $autoItems) {
        $summary += "`n| $($item.Date) | $($item.Vendor) | `$$($item.Amount.ToString('N2')) | $($item.AccountName) | $($item.IncomeType) |"
    }

    $summary += @"

### Totals by Account (Auto)

| Account | Amount |
|---------|------:|
"@

    $autoTotals = $autoItems | Group-Object AccountName | ForEach-Object {
        [PSCustomObject]@{ Account = $_.Name; Total = ($_.Group | Measure-Object Amount -Sum).Sum }
    } | Sort-Object Total -Descending

    foreach ($t in $autoTotals) {
        $summary += "`n| $($t.Account) | `$$($t.Total.ToString('N2')) |"
    }

    $summary += @"

---

## Items Needing Review (MEDIUM / LOW confidence)

These require user confirmation before posting:

| Date | Vendor | Description | Amount | Account | Confidence | Income Type |
|------|--------|-------------|-------:|---------|:----------|:-----------|
"@

    foreach ($item in $reviewItems) {
        $summary += "`n| $($item.Date) | $($item.Vendor) | $($item.Description) | `$$($item.Amount.ToString('N2')) | $($item.AccountName) | $($item.Confidence) | $($item.IncomeType) |"
    }

    $summary += @"

### Totals by Account (Review Items)

| Account | Amount |
|---------|------:|
"@

    $reviewTotals = $reviewItems | Group-Object AccountName | ForEach-Object {
        [PSCustomObject]@{ Account = $_.Name; Total = ($_.Group | Measure-Object Amount -Sum).Sum }
    } | Sort-Object Total -Descending

    foreach ($t in $reviewTotals) {
        $summary += "`n| $($t.Account) | `$$($t.Total.ToString('N2')) |"
    }

    return $summary
}
