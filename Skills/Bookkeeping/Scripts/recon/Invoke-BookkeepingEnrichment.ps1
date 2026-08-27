<#
.SYNOPSIS
    Enrich receipt manifests for both entities — normalizes vendors, validates dates/amounts, builds descriptions.
.DESCRIPTION
    Reads Complete/manifest.csv from each entity's receipt directory, applies enrichment rules
    (vendor normalization, date validation, amount checks, description building), and writes
    an enriched manifest as Complete/manifest-enriched.csv.
.PARAMETER Entity
    Which entity to process: "all", "room-rentals", or "intersite-consulting"
.PARAMETER ReceiptsBase
    Base directory containing entity-named receipt folders.
    Default: ~/intersite-docs/Taxes and Bookkeeping
.PARAMETER DryRun
    Preview changes without writing files.
.EXAMPLE
    .\Invoke-BookkeepingEnrichment.ps1 -Entity all
    Enrich all entities.
.EXAMPLE
    .\Invoke-BookkeepingEnrichment.ps1 -Entity room-rentals -DryRun
    Preview room-rentals enrichment.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("all", "room-rentals", "intersite-consulting")]
    [string]$Entity = "all",
    [string]$ReceiptsBase = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot ".." "shared" "Get-EntityConfig.ps1")

$Entities = @(
    @{
        Slug = "room-rentals"
        Label = "room-rentals"
        ReceiptDir = "2026 Receipts"
        ManifestName = "manifest.csv"
        EnrichedManifestName = "manifest-enriched.csv"
        ZohoOrgId = "925004567"
        DisplayName = "Victor Salmon — Room Rentals"
        VendorCorrections = @{
            "intersite consulting inc." = @{ Vendor = "Victor Salmon"; Reason = "personal rental income" }
            "intersite consulting"      = @{ Vendor = "Victor Salmon"; Reason = "personal rental income" }
        }
    }
    @{
        Slug = "intersite-consulting"
        Label = "intersite-consulting"
        ReceiptDir = "2026 Filing\Receipts"
        ManifestName = "_manifest.csv"
        EnrichedManifestName = "_manifest-enriched.csv"
        ZohoOrgId = "925048093"
        DisplayName = "Intersite Consulting Inc."
        VendorCorrections = @{ }
    }
)

function Get-AccountIdsFromConfig {
    param([string]$EntitySlug)
    $entityCfg = (Get-EntityConfig -Entity $EntitySlug).Entity
    $result = @{}
    foreach ($kv in $entityCfg.accounts.GetEnumerator()) {
        $result[$kv.Key] = $kv.Value.account_id
    }
    return $result
}

$DefaultVendorNormalization = @{
    "amazon.ca"              = "Amazon.ca"
    "amazon"                 = "Amazon.ca"
    "petro-canada"           = "Petro-Canada"
    "petro"                  = "Petro-Canada"
    "esso 7-eleven"          = "Esso"
    "esso"                   = "Esso"
    "shell"                  = "Shell"
    "chevron"                = "Chevron"
    "the home depot"         = "Home Depot"
    "home depot"             = "Home Depot"
    "super save"             = "Super Save Gas"
    "super save gas"         = "Super Save Gas"
    "kal tire"               = "Kal Tire"
    "canco"                  = "Canco"
    "co-op"                  = "Vernon Co-op"
    "internet lightspeed"    = "Lightspeed Internet"
    "internet lights"        = "Lightspeed Internet"
    "lightspeed"             = "Lightspeed Internet"
    "dollarama"              = "Dollarama"
    "aliexpress"             = "AliExpress"
    "freedom mobile"         = "Freedom Mobile"
    "roomies.com"            = "Roomies.ca"
    "zoho"                   = "Zoho Canada"
    "interserver"            = "InterServer"
    "kilo code"              = "Kilo Code"
    "anomaly"                = "Anomaly"
    "fongo"                  = "Fongo"
    "best buy"               = "Best Buy Canada"
    "walmart"                = "Walmart Canada"
    "lordco"                 = "Lordco Auto Parts"
    "icbc"                   = "ICBC"
    "bcaa"                   = "BCAA"
    "appsumo"                = "AppSumo"
    "coinamatic"             = "Coinamatic"
    "windsor greene"         = "Windsor Greene Strata"
    "advantagestrata"        = "AdvantageStrata"
    "reinvestwealth"         = "ReInvestWealth"
}

function Invoke-VendorNormalization {
    param([string]$RawVendor, [string]$RawFilename, [hashtable]$EntityCorrections)
    $key = $RawVendor.Trim().ToLowerInvariant()
    # 1. Exact match on entity corrections
    if ($EntityCorrections.ContainsKey($key)) {
        return $EntityCorrections[$key].Vendor
    }
    # 2. Exact match on default normalization
    if ($DefaultVendorNormalization.ContainsKey($key)) {
        return $DefaultVendorNormalization[$key]
    }
    # 3. Partial match: check if any keyword is contained in the vendor string
    $searchSpace = "$key $($RawFilename.ToLowerInvariant())"
    foreach ($kw in $DefaultVendorNormalization.Keys) {
        if ($searchSpace -match [regex]::Escape($kw)) {
            return $DefaultVendorNormalization[$kw]
        }
    }
    # 4. Partial match on entity corrections in filename too
    foreach ($kw in $EntityCorrections.Keys) {
        if ($searchSpace -match [regex]::Escape($kw)) {
            return $EntityCorrections[$kw].Vendor
        }
    }
    return $RawVendor
}

function Resolve-ReceiptDate {
    param([string]$ExtractedDate, [string]$Filename)
    if ($ExtractedDate -match '(\d{4}-\d{2}-\d{2})') {
        $d = Get-Date $Matches[1] -ErrorAction SilentlyContinue
        if ($d) { return $d.ToString("yyyy-MM-dd") }
    }
    if ($Filename -match '(\d{4}-\d{2}-\d{2})') {
        $d = Get-Date $Matches[1] -ErrorAction SilentlyContinue
        if ($d) { return $d.ToString("yyyy-MM-dd") }
    }
    return $ExtractedDate
}

function Test-ValidAmount {
    param([double]$Amount, [string]$Notes)
    if ($Amount -eq 0) {
        $isInformational = $Notes -match 'merged|informational|page' -or [string]::IsNullOrWhiteSpace($Notes)
        return @{ Valid = $false; Reason = if ($isInformational) { "Informational" } else { "Zero amount" }; Skip = $true }
    }
    if ($Amount -lt 0) {
        return @{ Valid = $true; Type = "refund"; Skip = $false }
    }
    if ($Amount -gt 500) {
        return @{ Valid = $true; Flag = "manual-review"; Reason = "Amount > \$500"; Skip = $false }
    }
    return @{ Valid = $true; Skip = $false }
}

function Get-SidecarData {
    <#
    .SYNOPSIS
        Check for a matching invoice sidecar CSV next to the receipt and extract invoice_number + description_short.
    #>
    param([string]$ReceiptFilename, [string]$ReceiptsDir)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ReceiptFilename)
    $csvPath = Join-Path $ReceiptsDir "$base.csv"
    if (-not (Test-Path $csvPath)) { return @{} }
    try {
        $lines = Get-Content $csvPath -Encoding UTF8 | Where-Object { $_ -and $_[0] -ne '#' }
        if (-not $lines) { return @{} }
        $data = $lines | ConvertFrom-Csv
        if (-not $data) { return @{} }
        return @{
            invoice_number    = if ($data[0].invoice_number) { $data[0].invoice_number } else { '' }
            description_short = if ($data[0].description_short) { $data[0].description_short } else { '' }
        }
    } catch { return @{} }
}

function Build-Description {
    param([string]$Vendor, [double]$Amount, [string]$Date, [string]$Notes, [hashtable]$SidecarData)
    $datePart = if ($Date -match '\d{4}-\d{2}-\d{2}') { $Date } else { '' }
    $amountPart = if ($Amount -ne 0) { "${Amount:F2}" } else { '' }

    $parts = @()
    if ($Amount -lt 0) { $parts = @("Refund") }

    if ($Notes) { $parts += $Notes }

    if ($SidecarData -and $SidecarData.description_short) {
        $parts += $SidecarData.description_short
    }

    $parts += $Vendor

    if ($amountPart) { $parts += "$$amountPart" }
    if ($datePart) { $parts += $datePart }

    if ($SidecarData -and $SidecarData.invoice_number) {
        $parts += "Inv#$($SidecarData.invoice_number)"
    }

    if ($parts.Count -eq 0) { return "$Vendor" }
    return ($parts -join ' — ')
}

function Get-VendorAccountId {
    param([string]$Vendor, [hashtable]$AccountIds)
    $lower = $Vendor.ToLowerInvariant()
    # Authoritative vendor keyword → account name mappings
    $keywordToAccount = @(
        @{ Keywords = @("petro","shell","chevron","super save","co-op","canco","esso","gas","fuel","mt. lehman","city park","seven oaks","westminster"); Account = "Automobile" }
        @{ Keywords = @("home depot","dulux","repair","maintenance","paint","rona","lowes","canadian tire","silicone","lightbulb","lock"); Account = "Repairs" }
        @{ Keywords = @("amazon","office","stationery","staples","best buy","pendaflex","folder","envelope","paper"); Account = "OfficeSupplies" }
        @{ Keywords = @("internet","lightspeed","fongo","zoho","interserver","kilo code","anomaly","opencode","hosting","phone","bitwarden","squarespace","namecheap","microsoft","google","software"); Account = "ITInternet" }
        @{ Keywords = @("meta","facebook","ads","advertising","roomies","marketplace"); Account = "Advertising" }
        @{ Keywords = @("kal tire","lordco","icbc","tire","brake","oil change","ignition"); Account = "Automobile" }
        @{ Keywords = @("property tax","vernon","abbotsford","tax"); Account = "Other" }
        @{ Keywords = @("netflix","laundry","coinamatic","bcaa","insurance","hydro","b.c. hydro","impark","parking","dollarama","aliexpress","reinvest","reinvestwealth","temu","donation"); Account = "Other" }
        @{ Keywords = @("rent","strata","advantage","windsor greene","management"); Account = "Rent" }
        @{ Keywords = @("janitorial","cleaning"); Account = "Janitorial" }
        @{ Keywords = @("consultant","accounting","legal","bookkeeping"); Account = "Consultant" }
        @{ Keywords = @("monthly account fee","bank fee","chq return","service charge"); Account = "BankFees" }
        @{ Keywords = @("mortgage","loan","interest","credit card"); Account = "CreditCard" }
        @{ Keywords = @("freedom mobile","telus","rogers","bell"); Account = "Telephone" }
        @{ Keywords = @("postage","shipping","stamp"); Account = "Postage" }
        @{ Keywords = @("travel","hotel","motel"); Account = "Travel" }
        @{ Keywords = @("food","meal","grocery","save-on","costco","restaurant"); Account = "Meals" }
    )
    foreach ($m in $keywordToAccount) {
        foreach ($kw in $m.Keywords) {
            if ($lower -match [regex]::Escape($kw)) {
                $accountName = $m.Account
                if ($AccountIds.ContainsKey($accountName)) {
                    return $AccountIds[$accountName]
                }
                Write-Warning "  Account key '$accountName' not found in entity config"
                return $AccountIds["Other"]
            }
        }
    }
    return $AccountIds["Other"]  # Default
}

$selectedEntities = if ($Entity -eq "all") { $Entities } else { $Entities | Where-Object { $_.Label -eq $Entity } }

foreach ($ent in $selectedEntities) {
    Write-Host "`n=== $($ent.DisplayName) ===" -ForegroundColor Cyan
    $receiptDir = Join-Path $ReceiptsBase $ent.Slug $ent.ReceiptDir
    $manifestPath = Join-Path $receiptDir $ent.ManifestName

    if (-not (Test-Path $manifestPath)) {
        Write-Warning "No manifest found at $manifestPath"
        continue
    }

    Write-Host "Reading manifest: $manifestPath" -ForegroundColor Gray
    $raw = Get-Content $manifestPath -Raw
    $bom = [char]0xFEFF
    if ($raw[0] -eq $bom) { $raw = $raw.Substring(1) }
    $receipts = $raw | ConvertFrom-Csv

    Write-Host "  Found $($receipts.Count) receipts" -ForegroundColor Gray

    $results = [System.Collections.Generic.List[object]]::new()
    $stats = @{ Total = 0; Enriched = 0; Skipped = 0; Flagged = 0 }
    $accountIds = Get-AccountIdsFromConfig -EntitySlug $ent.Slug

    foreach ($r in $receipts) {
        $stats.Total++
        $amountRaw = $r.amount -replace '[^0-9.-]', ''
        $amount = [double]::TryParse($amountRaw, [ref]$null) ? [double]$amountRaw : 0

        $vendor = Invoke-VendorNormalization -RawVendor $r.vendor -RawFilename $r.filename -EntityCorrections $ent.VendorCorrections
        $date = Resolve-ReceiptDate -ExtractedDate $r.date -Filename $r.filename
        $amountCheck = Test-ValidAmount -Amount $amount -Notes $r.notes
        $sidecarData = Get-SidecarData -ReceiptFilename $r.filename -ReceiptsDir $receiptDir
        $description = Build-Description -Vendor $vendor -Amount $amount -Date $date -Notes $r.notes -SidecarData $sidecarData
        $accountId = Get-VendorAccountId -Vendor $vendor -AccountIds $accountIds
        $errorStatus = if ($r.error_status) { $r.error_status } else { "" }

        $enrichStatus = if ($amountCheck.Skip -or $errorStatus) { "skipped" } else { "enriched" }
        $noteExtras = @()
        if ($errorStatus) { $noteExtras += "error_status=$errorStatus" }
        if ($r.suggested_account_id) { $noteExtras += "prior_suggested_account_id=$($r.suggested_account_id)" }
        if ($amountCheck.ContainsKey("Flag")) { $stats.Flagged++; $noteExtras += "flag=$($amountCheck.Reason)" }
        if ($amountCheck.Skip) { $stats.Skipped++; $noteExtras += "skip_reason=$($amountCheck.Reason)" } else { $stats.Enriched++ }
        $finalNotes = if ($noteExtras.Count) { "$description | $($noteExtras -join '; ')" } else { $description }

        $enriched = [ordered]@{
            filename         = $r.filename
            date             = $date
            amount           = if ($amountCheck.Skip -and $amountCheck.Reason -eq "Informational") { "" } else { "$amount" }
            vendor           = $vendor
            account          = $r.account
            sha256           = $r.sha256
            zoho_expense_id  = $r.zoho_expense_id
            zoho_document_id = $r.zoho_document_id
            source           = $r.source
            status           = $enrichStatus
            notes            = $finalNotes
            suggested_account_id = $accountId
        }

        $results.Add([pscustomobject]$enriched)

        if ($DryRun) {
            $status = if ($amountCheck.Skip) { "SKIP" } elseif ($amountCheck.ContainsKey("Flag")) { "FLAG" } else { "OK" }
            Write-Host "  [$status] $($r.filename) → vendor=$vendor date=$date amount=$amount" -ForegroundColor $(if ($amountCheck.Skip) { "Gray" } elseif ($amountCheck.ContainsKey("Flag")) { "Yellow" } else { "Green" })
        }
    }

    Write-Host "`n  Results: $($stats.Enriched) enriched, $($stats.Skipped) skipped, $($stats.Flagged) flagged, $($stats.Total) total" -ForegroundColor $(if ($stats.Skipped -eq 0 -and $stats.Flagged -eq 0) { "Green" } else { "Yellow" })

    if (-not $DryRun) {
        $outputPath = Join-Path $receiptDir $ent.EnrichedManifestName
        if ($PSCmdlet.ShouldProcess($outputPath, "Write enriched manifest")) {
            $results | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
            Write-Host "  Wrote enriched manifest: $outputPath" -ForegroundColor Green
        }
    }
}

Write-Host "`nDone." -ForegroundColor Cyan

