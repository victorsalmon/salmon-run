param([string]$Organization = "intersite-consulting",[string]$OutputFile = "")
$ErrorActionPreference = "Stop"
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$Organization"
$tasPath = "$booksRoot\TAS-2026.csv"
if (-not (Test-Path $tasPath)) { Write-Error "TAS not found"; exit 1 }
$lines = Get-Content $tasPath
$dl = $lines; $ds = 0; for ($i = 0; $i -lt $dl.Count; $i++) { if ($dl[$i] -notmatch '^#') { $ds = $i; break } }
$txns = @()
foreach ($line in $dl[($ds+1)..($dl.Count-1)]) { if ([string]::IsNullOrWhiteSpace($line)) { continue }; $c = $line -split ','; $txns += [PSCustomObject]@{ date=$c[0].Trim('"'); acct=$c[1].Trim('"'); amount=[double]$c[2].Trim('"') } }
$rbcS = '2025-03-13'; $mcS = '2025-03-11'
$accts = @(
    @{l="RBC Intersite (Chequing 6632)"; s="RBC-INTERSITE"; cc=$false; st=$rbcS; pe=@('2025-04-11','2025-05-13','2025-06-13','2025-07-11','2025-08-13','2025-09-12','2025-10-10','2025-11-13','2025-12-12','2026-01-13','2026-02-13','2026-03-13','2026-04-13','2026-05-13'); pc=@(5734.22,4807.32,3648.11,8482.44,5941.26,5374.15,5156.95,4416.33,4863.74,6072.59,4756.72,4535.77,4202.62,4146.16)}
    @{l="MC 6258 (MasterCard 6241)"; s="MC-6258"; cc=$true; st=$mcS; pe=@('2025-04-09','2025-05-09','2025-06-09','2025-07-09','2025-08-11','2025-09-09','2025-10-09','2025-11-10','2025-12-09','2026-01-09','2026-02-09','2026-03-09','2026-04-09','2026-05-11'); pc=@(1282.78,64.56,798.05,79.17,1165.17,144.93,360.73,158.75,85.41,373.45,1814.09,26.66,21.30,194.36)}
)
function Get-Net($tl, $f, $t, $inc) { $s = if ($inc) { $tl | Where-Object { $_.date -ge $f -and $_.date -le $t } } else { $tl | Where-Object { $_.date -gt $f -and $_.date -le $t } }; $sum = ($s | Measure-Object amount -Sum).Sum; if (-not $sum) { 0 } else { $sum } }
# Build gap date cache per account
$gapC = @{}
foreach ($a in $accts) {
    $at = $txns | Where-Object { $_.acct -eq $a.l }
    $ad = $at | Select-Object -ExpandProperty date -Unique | Sort-Object
    $g = @{}
    for ($i = 0; $i -lt $ad.Count - 1; $i++) {
        $gapLen = [math]::Abs(((Get-Date $ad[$i+1])-(Get-Date $ad[$i])).TotalDays)
        if ($gapLen -ge 5) {
            $mid = (Get-Date $ad[$i]).AddDays([math]::Floor($gapLen/2)).ToString('yyyy-MM-dd')
            $mo = Get-Date $mid; $b = $mo.AddDays(-1).ToString('yyyy-MM-dd'); $af = $mo.AddDays(1).ToString('yyyy-MM-dd')
            if (@($at | Where-Object { $_.date -ge $b -and $_.date -le $af }).Count -eq 0) { $g[$mid] = $true }
        }
    }
    $gapC[$a.s] = $g
}
$out = [System.Collections.ArrayList]@()
[void]$out.Add("## $Organization - Reconciliation Schedule")
[void]$out.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$out.Add("")
[void]$out.Add("All End Dates are <=31 days apart. Period ends with drift get an")
[void]$out.Add("Adjusted Period on a gap date that reconciles cleanly in Zoho.")
[void]$out.Add("")
foreach ($a in $accts) {
    $at = $txns | Where-Object { $_.acct -eq $a.l }
    $gapd = $gapC[$a.s]; $allGaps = $gapd.Keys | Sort-Object
    [void]$out.Add("### $($a.l)"); [void]$out.Add("")
    [void]$out.Add("| End Date | Balance | Type | Gap |"); [void]$out.Add("|---|---|---|---|")
    $anEnd = $null; $anCls = $null; $prevD = $null
    for ($pi = 0; $pi -lt $a.pe.Count; $pi++) {
        $pe = $a.pe[$pi]; $pc = $a.pc[$pi]
        if ($pi -eq 0) { $nf = Get-Net $at $a.st $pe $true; $op = if ($a.cc) { [math]::Round($pc+$nf,2) } else { [math]::Round($pc-$nf,2) } }
        else { $nf = Get-Net $at $a.pe[$pi-1] $pe $false }
        if (-not $nf) { $nf = 0 }
        if ($pi -eq 0) { $tc = if ($a.cc) { [math]::Round($op-$nf,2) } else { [math]::Round($op+$nf,2) } }
        else { $tc = if ($a.cc) { [math]::Round($a.pc[$pi-1]-$nf,2) } else { [math]::Round($a.pc[$pi-1]+$nf,2) } }
        $diff = [math]::Round($tc-$pc,2); $adiff = [math]::Abs($diff)
        if ($prevD) { $gapDays = [math]::Round(((Get-Date $pe)-(Get-Date $prevD)).TotalDays,0) } else { $gapDays = 0 }
        # Insert gap filler if gap > 31 days
        if ($gapDays -gt 31) {
            $dl2 = (Get-Date $prevD).AddDays(31).ToString('yyyy-MM-dd')
            $cand2 = $allGaps | Where-Object { $_ -gt $prevD -and $_ -le $dl2 }
            foreach ($cd2 in $cand2) {
                $n2 = Get-Net $at $anEnd $cd2 $false
                $b2 = if ($a.cc) { [math]::Round($anCls-$n2,2) } else { [math]::Round($anCls+$n2,2) }
                $g2 = "+$([math]::Round(((Get-Date $cd2)-(Get-Date $prevD)).TotalDays,0))d"
                [void]$out.Add("| $cd2 | $b2 | Gap filler | $g2 |"); $prevD = $cd2; break
            }
            $gapDays = [math]::Round(((Get-Date $pe)-(Get-Date $prevD)).TotalDays,0)
        }
        $gap = if ($prevD) { "+${gapDays}d" } else { "-" }
        if ($adiff -le 0.02) {
            [void]$out.Add("| $pe | $pc | Period end | $gap |"); $anEnd = $pe; $anCls = $pc; $prevD = $pe
        } else {
            [void]$out.Add("| $pe | $pc | Period end (drift: $adiff) | $gap |"); $prevD = $pe
            $deadline = (Get-Date $prevD).AddDays(31).ToString('yyyy-MM-dd')
            $cand = $allGaps | Where-Object { $_ -ge $pe -and $_ -le $deadline } | Sort-Object
            $found = $null; $fb = 0
            foreach ($cd in $cand) {
                $n = Get-Net $at $anEnd $cd $false
                $b = if ($a.cc) { [math]::Round($anCls-$n,2) } else { [math]::Round($anCls+$n,2) }
                if ($b -ge 0) { $found = $cd; $fb = $b; break }
            }
            if ($found) {
                $gadj = "+$([math]::Round(((Get-Date $found)-(Get-Date $prevD)).TotalDays,0))d"
                [void]$out.Add("| $found | $fb | Adjusted Period | $gadj |"); $prevD = $found
            }
        }
    }
    [void]$out.Add("")
}
$result = $out -join "`n"
if ($OutputFile) { $result | Out-File -FilePath $OutputFile -Encoding utf8 }
else { Write-Host $result }
