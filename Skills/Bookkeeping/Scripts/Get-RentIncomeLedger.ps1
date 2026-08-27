<#
.SYNOPSIS
    Generates rent income ledger.
#>

param(
    [string]$ConfigPath   = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\Contracts\rooms-config.json",
    [string]$RegisterPath = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\rent-register.csv",
    [string]$View         = "",
    [string]$Room         = "",
    [switch]$Export
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $RegisterPath)) { Write-Host "Register not found: $RegisterPath" -ForegroundColor Red; exit 1 }

$roomsConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$properties = @{}
$roomsConfig.properties.PSObject.Properties | ForEach-Object { $properties[$_.Name] = $_.Value.name }

$roomMap = @{}
$roomsConfig.rooms | ForEach-Object {
    $roomMap[$_.id] = @{
        name         = $_.name
        property     = $_.property
        propertyName = $properties[$_.property]
        rent         = [double]$_.rent
        occupants    = $_.occupants -join ", "
        start        = $_.contractStart
        end          = $_.contractEnd
    }
}

$bankMap = @{ "TMH" = "SCOTIA-TMH"; "MLM" = "TD-MLM"; "FRA" = "RBC-FRA-5172549" }

$register = Import-Csv $RegisterPath

$regAgg = @{}
$register | ForEach-Object {
    $key = $_.room_id + "|" + $_.paid_for_month
    if (-not $regAgg.ContainsKey($key)) { $regAgg[$key] = @{ total = 0; payments = @() } }
    $regAgg[$key].total += [double]$_.amount
    $regAgg[$key].payments += $_
}

$months = @()
$m = Get-Date "2026-01-01"
$end = Get-Date "2026-06-01"
while ($m -le $end) { $months += $m; $m = $m.AddMonths(1) }

$roomOrder = @("tmh-amethyst","tmh-chrysocolla","tmh-diamond","tmh-emerald",
               "mlm-fluorite","mlm-garnet","fra-jasper","fra-kyanite")

function Get-AccountForRoom {
    param($roomId)
    $prop = $roomMap[$roomId].property
    return $bankMap[$prop]
}

function EnsureTrailingPipe($s) {
    if ($s -match "[|]$") { return $s } else { return $s + " |" }
}

$out = New-Object System.Collections.ArrayList

$out.Add("# Room Rentals - Income Transactions 2026") > $null
$out.Add("") > $null

# Build a flat list of all transaction rows for non-matrix views
$allRows = @()
$register | ForEach-Object {
    $rm = $_.room_id; $mo = $_.paid_for_month
    $info = $roomMap[$rm]
    $acct = Get-AccountForRoom $rm
    $allRows += [PSCustomObject]@{
        Account   = $acct
        Date      = $_.payment_date
        Amount    = [double]$_.amount
        RoomId    = $rm
        RoomName  = $info.name
        Tenant    = $_.notes
        Month     = $mo
    }
}
$allRows = $allRows | Sort-Object Account, Date

# ─── View: Account ────────────────────────────────────────────────
function Show-AccountView {
    $out.Add("## By Account") > $null
    $out.Add("") > $null
    $allRows | Group-Object Account | ForEach-Object {
        $out.Add("### " + $_.Name) > $null
        $out.Add("") > $null
        $out.Add("| Date | Amount | Room | Month |") > $null
        $out.Add("|" + "-"*6 + "|" + "-"*8 + "|" + "-"*6 + "|" + "-"*7 + "|") > $null
        $sub = 0
        $_.Group | ForEach-Object {
            $out.Add("|" + $_.Date + "|$" + $_.Amount.ToString("F2") + "|" + $_.RoomName + "|" + $_.Month + "|") > $null
            $sub += $_.Amount
        }
        $out.Add("| **Subtotal** | **$" + $sub.ToString("F2") + "** | | |") > $null
        $out.Add("") > $null
    }
}

# ─── View: Monthly ────────────────────────────────────────────────
function Show-MonthlyView {
    $out.Add("## By Month") > $null
    $out.Add("") > $null
    $allRows | Group-Object Month | Sort-Object Name | ForEach-Object {
        $out.Add("### " + $_.Name) > $null
        $out.Add("") > $null
        $out.Add("| Account | Amount | Room | Tenant | Date |") > $null
        $out.Add("|" + "-"*9 + "|" + "-"*8 + "|" + "-"*6 + "|" + "-"*8 + "|" + "-"*6 + "|") > $null
        $_.Group | Sort-Object Account | ForEach-Object {
            $out.Add("|" + $_.Account + "|$" + $_.Amount.ToString("F2") + "|" + $_.RoomName + "|" + $_.Tenant + "|" + $_.Date + "|") > $null
        }
        $out.Add("") > $null
    }
}

# ─── View: Single Room ────────────────────────────────────────────
function Show-RoomView {
    param($roomId)
    $info = $roomMap[$roomId]
    if (-not $info) { Write-Host "Unknown room: $roomId" -ForegroundColor Red; return }
    $acct = Get-AccountForRoom $roomId
    $out.Add("## " + $info.propertyName + " > " + $info.name) > $null
    $out.Add("") > $null
    $out.Add("Rent: $ $($info.rent)/mo  |  $($info.occupants)  |  $($info.start) to $($info.end)  |  $acct") > $null
    $out.Add("") > $null
    $out.Add("| Month | Expected | Received | Status | Payments |") > $null
    $out.Add("|" + "-"*7 + "|" + "-"*10 + "|" + "-"*10 + "|" + "-"*8 + "|" + "-"*20 + "|") > $null

    foreach ($month in $months) {
        $yrMo = $month.ToString("yyyy-MM")
        $expected = $info.rent
        $st = Get-Date $info.start; $en = Get-Date $info.end
        $stM = Get-Date -Year $st.Year -Month $st.Month -Day 1 -Hour 0 -Minute 0 -Second 0
        $enM = Get-Date -Year $en.Year -Month $en.Month -Day 1 -Hour 0 -Minute 0 -Second 0
        $my = $month.Year; $mm = $month.Month
        $sy = $st.Year; $sm = $st.Month; $ey = $en.Year; $em = $en.Month

        if ($my -lt $sy -or ($my -eq $sy -and $mm -lt $sm)) {
            $out.Add("|$yrMo|$ $expected| - |NOT YET|lease not started|") > $null
            continue
        }
        if ($my -gt $ey -or ($my -eq $ey -and $mm -gt $em)) {
            $out.Add("|$yrMo|$ $expected| - |ENDED|contract ended $($info.end)|") > $null
            continue
        }

        $regKey = $roomId + "|" + $yrMo
        $entry = $regAgg[$regKey]
        if ($entry) {
            $received = $entry.total
            $paidFrom = ($entry.payments | ForEach-Object { $_.payment_date + " $" + $_.amount }) -join " + "
            $out.Add("|$yrMo|$ $expected|$ $received|PAID|$paidFrom|") > $null
        } else {
            $out.Add("|$yrMo|$ $expected| - |MISSING| - |") > $null
        }
    }
}

# ─── Summary ───────────────────────────────────────────────────────
function Show-Summary {
    $grandExp = 0; $grandRec = 0; $paidCt = 0; $totalCt = 0
    $out.Add("## Summary") > $null
    $out.Add("") > $null
    $out.Add("| Room | Property | Rent | Jan | Feb | Mar | Apr | May | Jun |") > $null
    $out.Add("|" + "-"*6 + "|" + "-"*10 + "|" + "-"*6 + "|" + "-"*5 + "|" + "-"*5 + "|" + "-"*5 + "|" + "-"*5 + "|" + "-"*5 + "|" + "-"*5 + "|") > $null

    foreach ($roomId in $roomOrder) {
        $info = $roomMap[$roomId]
        $row = "|" + $info.name + "|" + $info.propertyName + "|$" + $info.rent
        foreach ($month in $months) {
            $yrMo = $month.ToString("yyyy-MM")
            $st = Get-Date $info.start; $en = Get-Date $info.end
            $stM = Get-Date -Year $st.Year -Month $st.Month -Day 1 -Hour 0 -Minute 0 -Second 0
            $enM = Get-Date -Year $en.Year -Month $en.Month -Day 1 -Hour 0 -Minute 0 -Second 0
            $my = $month.Year; $mm = $month.Month
            $sy = $st.Year; $sm = $st.Month; $ey = $en.Year; $em = $en.Month

            if ($my -lt $sy -or ($my -eq $sy -and $mm -lt $sm)) { $row += "|--"; continue }
            if ($my -gt $ey -or ($my -eq $ey -and $mm -gt $em)) { $row += "|xx"; continue }

            $totalCt++
            $expected = $info.rent; $grandExp += $expected
            $regKey = $roomId + "|" + $yrMo
            $entry = $regAgg[$regKey]
            if ($entry) { $grandRec += $entry.total; $paidCt++; $row += "|:heavy_check_mark:" }
            else { $row += "|:x:" }
        }
        $row += "|"
        $out.Add($row) > $null
    }
    $out.Add("") > $null
    $out.Add("**Rent received: $ $grandRec  |  Obligated months: $paidCt / $totalCt**") > $null
    if ($grandExp -gt 0) {
        $pct = [math]::Round($paidCt / $totalCt * 100, 1)
        $out.Add("**Collection rate: $pct%**") > $null
    }
    $out.Add("") > $null
}

# ─── Console Views ─────────────────────────────────────────────────
function Show-ConsoleStatus {
    Write-Host ""
    Write-Host ("=" * 100) -ForegroundColor Cyan
    Write-Host "                    ROOM RENTALS - RENT INCOME LEDGER 2026" -ForegroundColor Cyan
    Write-Host "                    Source: rent-register.csv" -ForegroundColor Cyan
    Write-Host ("=" * 100) -ForegroundColor Cyan
    $grandExpected = 0; $grandReceived = 0; $fullyPaidCount = 0; $totalMonths = 0

    foreach ($roomId in $roomOrder) {
        $info = $roomMap[$roomId]
        $bname = $bankMap[$info.property]
        Write-Host ""
        Write-Host ("--- " + $info.propertyName + " > " + $info.name + "  [$" + $info.rent + "/mo] ---") -ForegroundColor Yellow
        Write-Host ("    " + $info.occupants + "  |  " + $info.start + "  to  " + $info.end + "  |  " + $bname) -ForegroundColor Gray
        Write-Host ""
        Write-Host ("Month".PadRight(12) + "Expected".PadRight(10) + "Received".PadRight(12) + "Status".PadRight(22) + "Payments") -ForegroundColor White
        Write-Host ("-" * 70) -ForegroundColor DarkGray

        foreach ($month in $months) {
            $yrMo = $month.ToString("yyyy-MM")
            $expected = [double]$info.rent
            $st = Get-Date $info.start; $en = Get-Date $info.end
            $my = $month.Year; $mm = $month.Month
            $sy = $st.Year; $sm = $st.Month; $ey = $en.Year; $em = $en.Month

            if ($my -lt $sy -or ($my -eq $sy -and $mm -lt $sm)) {
                Write-Host ($yrMo.PadRight(12) + ("$" + $expected).PadRight(10) + "$0".PadRight(12) + "NOT YET".PadRight(22) + "(lease not started)") -ForegroundColor DarkGray
                continue
            }
            if ($my -gt $ey -or ($my -eq $ey -and $mm -gt $em)) {
                Write-Host ($yrMo.PadRight(12) + ("$" + $expected).PadRight(10) + "$0".PadRight(12) + "ENDED".PadRight(22) + "(contract ended " + $info.end + ")") -ForegroundColor DarkGray
                continue
            }

            $regKey = $roomId + "|" + $yrMo
            $entry = $regAgg[$regKey]
            if ($entry) {
                $received = $entry.total
                $paidFrom = ($entry.payments | ForEach-Object { $_.payment_date.ToString() + " $" + $_.amount }) -join " + "
                $fullyPaidCount++
                Write-Host ($yrMo.PadRight(12) + ("$" + $expected).PadRight(10) + ("$" + $received).PadRight(12) + "PAID".PadRight(22) + $paidFrom) -ForegroundColor Green
                $notes = $entry.payments[0].notes
                if ($notes) { Write-Host ("      " + $notes) -ForegroundColor DarkGray }
            } else {
                Write-Host ($yrMo.PadRight(12) + ("$" + $expected).PadRight(10) + "$0".PadRight(12) + "MISSING".PadRight(22) + "-") -ForegroundColor Red
            }
            $grandExpected += $expected
            if ($entry) { $grandReceived += $entry.total }
            $totalMonths++
        }
    }

    Write-Host ""
    Write-Host ("=" * 100) -ForegroundColor Cyan
    Write-Host ""
    $pct = 0; if ($grandExpected -gt 0) { $pct = [math]::Round($grandReceived / $grandExpected * 100, 1) }
    Write-Host "OVERALL (Jan-Jun 2026):" -ForegroundColor White
    Write-Host ("  Total received: $" + $grandReceived) -ForegroundColor Gray
    Write-Host ("  Months paid:    " + $fullyPaidCount + " / " + $totalMonths) -ForegroundColor Gray
    Write-Host ""
}

# ─── Main Dispatch ─────────────────────────────────────────────────
if ($Export) {
    if ($View -eq "account" -or $View -eq "Account") { Show-AccountView }
    elseif ($View -eq "monthly" -or $View -eq "Monthly") { Show-MonthlyView }
    elseif ($Room -ne "") { Show-RoomView $Room }
    else { Show-Summary }

    $mdPath = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026-rent-income-ledger.md"
    $out -join "`n" | Out-File -FilePath $mdPath -Encoding utf8
    Write-Host "Exported to $mdPath" -ForegroundColor Green
}
else {
    Show-ConsoleStatus
}
