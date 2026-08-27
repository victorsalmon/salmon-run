<#
.SYNOPSIS
    Demo — exercises Get-AccountIdFromRules against sample vendors for both entities.
.DESCRIPTION
    Runs the unified categorization function against a comprehensive set of sample
    payees (fuel, office, software, rent, repairs, banking, Amazon, etc.) for both
    Intersite Consulting and Room Rentals. Reports match results, rule source, and
    account IDs.
#>

$scriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $scriptDir "Get-AccountIdFromRules.ps1")

$IntersiteId = "intersite-consulting"
$RoomRentalsId = "room-rentals"

$testCases = @(
    # Fuel & auto
    @{ Vendor = "Petro-Canada";            Description = "Fuel" }
    @{ Vendor = "Shell";                   Description = "Gas" }
    @{ Vendor = "Chevron";                 Description = "" }
    @{ Vendor = "Super Save Gas";          Description = "" }
    @{ Vendor = "CO-OP Vernon";            Description = "" }
    @{ Vendor = "Canco";                   Description = "" }
    @{ Vendor = "Esso";                    Description = "" }
    @{ Vendor = "CHV1234";                 Description = "" }
    @{ Vendor = "Kal Tire";                Description = "New tires" }
    @{ Vendor = "Lordco Auto Parts";       Description = "" }
    @{ Vendor = "ICBC";                    Description = "Insurance" }

    # Office & supplies
    @{ Vendor = "Amazon.ca";               Description = "" }
    @{ Vendor = "Staples";                 Description = "" }
    @{ Vendor = "Best Buy Canada";         Description = "" }
    @{ Vendor = "Dollarama";               Description = "" }
    @{ Vendor = "Walmart Canada";          Description = "" }

    # Software & IT
    @{ Vendor = "Zoho Canada";             Description = "" }
    @{ Vendor = "InterServer";             Description = "" }
    @{ Vendor = "Kilo Code";               Description = "" }
    @{ Vendor = "Anomaly";                 Description = "" }
    @{ Vendor = "Lightspeed Internet";     Description = "" }
    @{ Vendor = "Freedom Mobile";          Description = "" }
    @{ Vendor = "Squarespace";             Description = "" }
    @{ Vendor = "Namecheap";               Description = "" }
    @{ Vendor = "OpenRouter Inc";          Description = "" }
    @{ Vendor = "Stripe-z.ai";             Description = "" }

    # Repairs & maintenance
    @{ Vendor = "Home Depot";              Description = "" }
    @{ Vendor = "RONA";                    Description = "" }
    @{ Vendor = "Vernon Lock";             Description = "" }
    @{ Vendor = "Temu";                    Description = "" }
    @{ Vendor = "Visions Electronics";     Description = "" }

    # Rent & property
    @{ Vendor = "Windsor Greene Strata";   Description = "" }
    @{ Vendor = "AdvantageStrata";         Description = "" }

    # Banking
    @{ Vendor = "Monthly Account Fee";     Description = "" }
    @{ Vendor = "Purchase Interest";       Description = "CC interest charge" }
    @{ Vendor = "Automatic Payment";       Description = "CC payment from chequing" }
    @{ Vendor = "Payment - Thank You";     Description = "" }

    # Income / transfers
    @{ Vendor = "WAVE SV9T";               Description = "Wave payment processing" }
    @{ Vendor = "RBC Credit Card";         Description = "" }

    # CRA & Tax
    @{ Vendor = "PAD CCRA";                Description = "" }

    # Telephone
    @{ Vendor = "Telus";                   Description = "" }
    @{ Vendor = "Rogers";                  Description = "" }

    # Unknown/catch-all
    @{ Vendor = "Random Store";            Description = "" }
    @{ Vendor = "Unknown Vendor Ltd";      Description = "Misc service" }
)

Write-Host "=== Intersite Consulting ===" -ForegroundColor Cyan
Write-Host ("{0,-30} {1,-30} {2,-20} {3,-14} {4}" -f "Vendor", "Account Name", "Rule Source", "Account ID", "Description") -ForegroundColor Gray
Write-Host ("-" * 120) -ForegroundColor Gray

foreach ($tc in $testCases) {
    $result = Get-AccountIdFromRules -Vendor $tc.Vendor -Description $tc.Description -EntitySlug $IntersiteId -PassThru
    $matched = $result.rule_source -ne "unmatched"
    $color = if ($matched) { "Green" } else { "Yellow" }
    Write-Host ("{0,-30} {1,-30} {2,-20} {3,-14} {4}" -f $tc.Vendor, $result.account_name, $result.rule_source, $result.account_id, $tc.Description) -ForegroundColor $color
}

Write-Host "`n=== Room Rentals ===" -ForegroundColor Cyan
Write-Host ("{0,-30} {1,-30} {2,-20} {3,-14} {4}" -f "Vendor", "Account Name", "Rule Source", "Account ID", "Description") -ForegroundColor Gray
Write-Host ("-" * 120) -ForegroundColor Gray

# Test a subset for Room Rentals
$roomCases = $testCases | Select-Object -First 25

foreach ($tc in $roomCases) {
    $result = Get-AccountIdFromRules -Vendor $tc.Vendor -Description $tc.Description -EntitySlug $RoomRentalsId -PassThru
    $matched = $result.rule_source -ne "unmatched"
    $color = if ($matched) { "Green" } else { "Yellow" }
    Write-Host ("{0,-30} {1,-30} {2,-20} {3,-14} {4}" -f $tc.Vendor, $result.account_name, $result.rule_source, $result.account_id, $tc.Description) -ForegroundColor $color
}

Write-Host "`nDone." -ForegroundColor Cyan
