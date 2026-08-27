function Get-NextCronOccurrence {
    param([string]$Expression, [DateTime]$After)

    $fields = $Expression.Trim() -split '\s+'
    if ($fields.Count -ne 5) { return $null }

    function Parse-CronField {
        param([string]$Field, [int]$Min, [int]$Max)
        if ($Field -eq '*') { return @(-1) }
        $values = @()
        foreach ($part in $Field -split ',') {
            if ($part -match '^\*/(\d+)$') {
                $step = [int]$matches[1]
                for ($v = $Min; $v -le $Max; $v += $step) { $values += $v }
            } elseif ($part -match '^(\d+)-(\d+)$') {
                for ($v = [int]$matches[1]; $v -le [int]$matches[2]; $v++) { $values += $v }
            } elseif ($part -match '^\d+$') {
                $values += [int]$part
            }
        }
        return ($values | Sort-Object -Unique)
    }

    $minVals = Parse-CronField $fields[0] 0 59
    $hourVals = Parse-CronField $fields[1] 0 23
    $domVals = Parse-CronField $fields[2] 1 31
    $monVals = Parse-CronField $fields[3] 1 12
    $dowVals = Parse-CronField $fields[4] 0 7
    $domAll = $domVals -contains -1
    $dowAll = $dowVals -contains -1
    $dowVals = $dowVals | Where-Object { $_ -ne -1 } | ForEach-Object { $_ % 7 }

    $months = if ($monVals -contains -1) { 1..12 } else { $monVals }
    $hours = if ($hourVals -contains -1) { 0..23 } else { $hourVals }
    $minutes = if ($minVals -contains -1) { 0..59 } else { $minVals }

    $start = $After.AddMinutes(1)
    for ($year = $start.Year; $year -le $start.Year + 5; $year++) {
        foreach ($month in $months) {
            $daysInMonth = [DateTime]::DaysInMonth($year, $month)
            $candidateDays = if ($domAll -and $dowAll) { 1..$daysInMonth }
            elseif ($domAll) {
                @(1..$daysInMonth | Where-Object {
                    [int][DateTime]::new($year, $month, $_).DayOfWeek -in $dowVals
                })
            } elseif ($dowAll) { $domVals | Where-Object { $_ -ge 1 -and $_ -le $daysInMonth } }
            else {
                @($domVals | Where-Object { $_ -ge 1 -and $_ -le $daysInMonth } | Where-Object {
                    [int][DateTime]::new($year, $month, $_).DayOfWeek -in $dowVals
                })
            }
            foreach ($day in ($candidateDays | Sort-Object -Unique)) {
                if ($day -lt 1 -or $day -gt $daysInMonth) { continue }
                foreach ($hour in $hours) {
                    if ($hour -lt 0 -or $hour -gt 23) { continue }
                    foreach ($minute in $minutes) {
                        if ($minute -lt 0 -or $minute -gt 59) { continue }
                        $dt = [DateTime]::new($year, $month, $day, $hour, $minute, 0, [DateTimeKind]::Utc)
                        if ($dt -gt $After) { return $dt }
                    }
                }
            }
        }
    }
    return $null
}
