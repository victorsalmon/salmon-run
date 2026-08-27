function Get-RentStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Period,
        [string]$RoomId
    )

    $dataRoot = if ($env:RENT_DATA_DIR) { $env:RENT_DATA_DIR } else { "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals" }

    $RegisterPath = Join-Path $dataRoot "rent-register.csv"
    $ConfigPath   = Join-Path $dataRoot "Contracts\rooms-config.json"

    if (-not (Test-Path $RegisterPath)) { return [pscustomobject]@{ Success = $false; Error = "Register not found: $RegisterPath" } }
    if (-not (Test-Path $ConfigPath))   { return [pscustomobject]@{ Success = $false; Error = "Config not found: $ConfigPath" } }

    $roomsConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $register = Import-Csv $RegisterPath

    $roomMap = @{}
    $roomsConfig.rooms | ForEach-Object {
        $roomMap[$_.id] = @{
            name         = $_.name
            property     = $_.property
            propertyName = $roomsConfig.properties.$($_.property).name
            rent         = [double]$_.rent
            occupants    = $_.occupants -join ", "
            start        = $_.contractStart
            end          = $_.contractEnd
            deposit      = [double]$_.damageDeposit
            notes        = $_.notes
        }
    }

    $regAgg = @{}
    $register | ForEach-Object {
        $key = $_.room_id + "|" + $_.paid_for_month
        if (-not $regAgg.ContainsKey($key)) { $regAgg[$key] = @{ total = 0; payments = @() } }
        $regAgg[$key].total += [double]$_.amount
        $regAgg[$key].payments += @{
            date   = $_.payment_date
            amount = [double]$_.amount
            notes  = $_.notes
        }
    }

    function Get-PaymentMethod {
        param([string]$Notes)
        if (-not $Notes) { return "unknown" }
        $n = $Notes.ToLowerInvariant()
        if ($n -match 'work deduction') { return "work-deduction" }
        if ($n -match 'dd|direct deposit') { return "direct-deposit" }
        if ($n -match 'etransfer|e\.transfer|e-transfer|interac') { return "e-transfer" }
        if ($n -match 'cash') { return "cash" }
        if ($n -match 'cheque|check') { return "cheque" }
        return "unknown"
    }

    $targetPeriods = if ($Period) { @($Period) } else {
        $months = @()
        $m = Get-Date "2026-01-01"
        $end = (Get-Date).AddMonths(-1)
        while ($m -le $end) { $months += $m.ToString("yyyy-MM"); $m = $m.AddMonths(1) }
        if ($months.Count -eq 0) { $months = @((Get-Date).ToString("yyyy-MM")) }
        $months
    }

    $allProperties = @{}
    foreach ($propKey in $roomsConfig.properties.PSObject.Properties.Name) {
        $prop = $roomsConfig.properties.$propKey
        $allProperties[$propKey] = @{ name = $prop.name; expected = 0; received = 0; rooms = @{} }
    }

    $summary = @{ totalExpected = 0; totalReceived = 0; paid = 0; partial = 0; unpaid = 0; notStarted = 0; ended = 0; totalRooms = 0 }

    foreach ($targetPeriod in $targetPeriods) {
        foreach ($rid in $roomMap.Keys | Sort-Object) {
            $info = $roomMap[$rid]
            $st = Get-Date $info.start; $en = Get-Date $info.end
            $periodDate = Get-Date "$($targetPeriod)-01"
            $expected = $info.rent

            $contractNotStarted = ($periodDate.Year -lt $st.Year -or ($periodDate.Year -eq $st.Year -and $periodDate.Month -lt $st.Month))
            $contractEnded = ($periodDate.Year -gt $en.Year -or ($periodDate.Year -eq $en.Year -and $periodDate.Month -gt $en.Month))

            if ($RoomId -and $RoomId -ne $rid) { continue }

            $regKey = $rid + "|" + $targetPeriod
            $entry = $regAgg[$regKey]
            $received = if ($entry) { $entry.total } else { 0 }
            $payments = if ($entry) { $entry.payments } else { @() }

            $status = if ($contractNotStarted) { "not_started" } elseif ($contractEnded) { "ended" } elseif ($received -ge $expected) { "paid" } elseif ($received -gt 0) { "partial" } else { "unpaid" }

            $roomResult = @{
                name       = $info.name
                property   = $info.property
                propertyName = $info.propertyName
                occupants  = $info.occupants
                expected   = $expected
                received   = $received
                status     = $status
                payments   = @($payments | ForEach-Object { @{
                    date   = $_.date
                    amount = $_.amount
                    method = Get-PaymentMethod -Notes $_.notes
                    notes  = $_.notes
                }})
                deposit    = $info.deposit
                contractStart = $info.start
                contractEnd   = $info.end
            }

            if (-not $allProperties[$info.property].rooms.ContainsKey($rid)) {
                $allProperties[$info.property].rooms[$rid] = @{}
            }
            $allProperties[$info.property].rooms[$rid] = $roomResult
            $allProperties[$info.property].expected += $expected
            $allProperties[$info.property].received += $received
            $summary.totalExpected += $expected
            $summary.totalReceived += $received
        }
    }

    $allRooms = $allProperties.Values | ForEach-Object { $_.rooms.Values }
    $summary.paid = @($allRooms | Where-Object { $_.status -eq "paid" }).Count
    $summary.partial = @($allRooms | Where-Object { $_.status -eq "partial" }).Count
    $summary.unpaid = @($allRooms | Where-Object { $_.status -eq "unpaid" }).Count
    $summary.notStarted = @($allRooms | Where-Object { $_.status -eq "not_started" }).Count
    $summary.ended = @($allRooms | Where-Object { $_.status -eq "ended" }).Count
    $summary.totalRooms = $roomMap.Count

    return [pscustomobject]@{
        Success    = $true
        Period     = if ($Period) { $Period } else { $targetPeriods -join "," }
        GeneratedAt = (Get-Date).ToString("o")
        Source     = $RegisterPath
        Summary    = $summary
        Properties = $allProperties
    }
}
