<#
.SYNOPSIS
    Links receipts to bank CSVs.
#>

$baseDir = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals"

$map = @{
    # RBC (date: M/D/YYYY)
    "1/5/2026|15.67" = "2026-01-05 - 15.67 - Amazon.ca - AMZN Mktp CAV12T35GT3.pdf"
    "1/6/2026|66.18" = "2026-01-06 - 66.18 - Amazon.ca - AMZN Mktp CA2T7LS81G3.pdf"
    "1/7/2026|15.10" = "2026-01-07 - 15.10 - Amazon.ca - AMZN Mktp CA0V70B5PQ3.pdf"
    "1/13/2026|18.99" = "2026-01-13 - 18.99 - Amazon.ca - AmazoncaHG0XH8503.pdf"
    "2/9/2026|19.92" = "2026-02-09 - 19.92 - Amazon.ca - AmazoncaNC91R8V03.pdf"
    "2/18/2026|6.71" = "2026-02-18 - 6.71 - Amazon.ca - AmazoncaB95LS6ZH2.pdf"
    "4/2/2026|21.27" = "2026-04-02 - 21.27 - Amazon.ca - AMZN Mktp CAB76XF7F52.pdf"
    "4/5/2026|18.79" = "2026-04-05 - 18.79 - Amazon.ca - AmazoncaB77CV5H72.pdf"
    "5/12/2026|16.79" = "2026-05-12 - 16.79 - Amazon.ca - AMZN Mktp CAEB21U6GM3.pdf"
    "5/13/2026|11.19" = "2026-05-13 - 11.19 - Amazon.ca - AMZN Mktp CABF5YR3581.pdf"
    "5/13/2026|26.87" = "2026-05-13 - 26.87 - Amazon.ca - AMZN Mktp CABV3EO0QU0.pdf"
    "5/13/2026|8.04" = "2026-05-13 - 8.04 - Amazon.ca - AmazoncaBF1435M82.pdf"
    # TD (date: YYYY-MM-DD)
    "2026-03-19|11.30" = "2026-03-19 - 11.30 - Amazon.ca - AMZN Mktp CA.pdf"
    "2026-03-23|10.07" = "2026-03-23 - 10.07 - Amazon.ca - AMZN Mktp CA.pdf"
    "2026-05-12|22.07" = "2026-05-12 - 22.07 - Amazon.ca - Amazonca.pdf"
    "2026-05-20|10.06" = "2026-05-20 - 10.06 - Amazon.ca - AMZN Mktp CA.pdf"
    # Scotia (date: YYYY-MM-DD)
    "2026-02-07|7.83" = "2026-02-07 - 7.83 - Amazon.ca - Amzn Mktp Ca.pdf"
    "2026-02-07|18.13" = "2026-02-07 - 18.13 - Amazon.ca - Amzn Mktp Ca.pdf"
    "2026-02-16|15.21" = "2026-02-16 - 15.21 - Amazon.ca - AmazonCa.pdf"
    "2026-05-19|7.86" = "2026-05-19 - 7.86 - Amazon.ca - AmazonCa.pdf"
    "2026-05-19|22.51" = "2026-05-19 - 22.51 - Amazon.ca - AmazonCa.pdf"
    "2026-05-21|19.04" = "2026-05-21 - 19.04 - Amazon.ca - AmazonCa.pdf"
}

function Fix-File {
    param($Path, $DateCol, $AmtCol, $RecCol, $DescRegex, $DateRegex)

    $raw = Get-Content $Path -Raw
    $lines = $raw -split "`r?`n"
    $header = $lines[0]
    $result = @($header)
    $changed = 0

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '') { $result += $line; continue }

        # Check if this is an Amazon line by raw text match
        if ($line -notmatch $DescRegex) { $result += $line; continue }

        # Parse CSV respecting quotes
        $fields = @()
        $current = ''
        $inQuotes = $false
        for ($j = 0; $j -lt $line.Length; $j++) {
            $c = $line[$j]
            if ($c -eq '"') { $inQuotes = -not $inQuotes }
            elseif ($c -eq ',' -and -not $inQuotes) {
                $fields += $current.Trim('"')
                $current = ''
                continue
            }
            $current += $c
        }
        $fields += $current.Trim('"')  # last field

        # Ensure we have enough fields
        $maxCol = [Math]::Max($DateCol, [Math]::Max($AmtCol, $RecCol))
        if ($fields.Count -le $maxCol) { $result += $line; continue }

        $date = $fields[$DateCol]
        $amtRaw = $fields[$AmtCol] -replace '[^0-9.]',''
        if ($amtRaw -eq '') { $result += $line; continue }
        $amt = [math]::Round([double]$amtRaw, 2).ToString('0.00')
        $key = "$date|$amt"

        if ($map.ContainsKey($key)) {
            $fields[$RecCol] = $map[$key]
            $changed++
            # Rebuild line with proper quoting
            $newFields = @()
            for ($f = 0; $f -lt $fields.Count; $f++) {
                $val = $fields[$f]
                if ($val -match '[,"\n\r]' -or $val -eq '') {
                    $newFields += '"' + $val + '"'
                } else {
                    $newFields += $val
                }
            }
            $line = $newFields -join ','
        }
        $result += $line
    }

    $result -join "`r`n" | Set-Content $Path -NoNewline
    Write-Output "  $changed updated"
}

Write-Output "RBC-FRA-6679:"
Fix-File -Path "$baseDir\2026 Bank Statements\RBC-FRA-6679\2026.01.01-2026.06.10 - RBC-FRA-6679.csv" `
    -DateCol 2 -AmtCol 6 -RecCol 8 -DescRegex '(?i)(amzn|amazon)' -DateRegex ''

Write-Output "TD-MLM-6467010:"
Fix-File -Path "$baseDir\2026 Bank Statements\TD-MLM-6467010\2026.01.01-2026.06.10 - TD-MLM 6467010.csv" `
    -DateCol 0 -AmtCol 2 -RecCol 5 -DescRegex '(?i)(amzn|amazon)' -DateRegex ''

Write-Output "SCOTIA-TMH:"
Fix-File -Path "$baseDir\2026 Bank Statements\SCOTIA-TMH 406000697486\2026.01.01-2026.06.10 - SCOTIA-TMH 406000697486.csv" `
    -DateCol 1 -AmtCol 5 -RecCol 7 -DescRegex '(?i)(amzn|amazon)' -DateRegex ''
