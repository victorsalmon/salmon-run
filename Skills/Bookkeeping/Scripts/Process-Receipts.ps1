<#
.DEPRECATED
This script has been decomposed into four idempotent sub-step scripts.
Use these instead:
  invoke-pdf-data-extraction.ps1     (Phase 2-i — PDF text/image extraction)
  invoke-image-data-extraction.ps1   (Phase 2-ii — Vision AI OCR)
  invoke-metadata-renaming.ps1       (Phase 2-iii — Metadata-based renaming)
  update-manifest.ps1                (Phase 2-iv — Manifest consolidation)
Or use the orchestrator:
  invoke-manifest-update.ps1 -Mode Local
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [string]$OutputRoot,
    [string]$RulesDir,
    [string]$Mode = "receipt",
    [switch]$ConvertPdf,
    [switch]$ForceReRun,
    [switch]$CompleteOnly,
    [int]$MaxImages = 999
)

<#
.SYNOPSIS
    Multi-stage receipt processing pipeline with dedup, retry, and error tracking.
.DESCRIPTION
    Stages:
      1. Pre-processing  — Convert PDF→JPGs → "$ts Preprocessing/"
                          Hash-dedup against prior Renamed runs
      2. Vision           — GPT-4o Mini analysis → "$ts Renamed/"
      3. Post-processing  — Business rules + known-issues retry logic
      4. Error fallback   — Failed images → "$ts Errors/" with partial sidecars

    Repeat-run safe: source files are hash-checked against prior manifests.
    Only new files, changed files, and files in Error folders are re-processed.
#>

$ErrorActionPreference = "Stop"
if (-not $PSCmdlet.ShouldProcess("$SourceDir", "Run receipt processing pipeline")) { return }
$OpenRouterKey = if ($env:OPENROUTER_ORCH_KEY) { $env:OPENROUTER_ORCH_KEY } else { $env:OPENROUTER_API_KEY }
$Timestamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
if (-not $OutputRoot) { $OutputRoot = $SourceDir }

$PrepDir  = Join-Path $OutputRoot "${Timestamp} Preprocessing"
$OutDir   = Join-Path $OutputRoot "${Timestamp} Renamed"
$ErrDir   = Join-Path $OutputRoot "${Timestamp} Errors"

if ($CompleteOnly) {
    $latestRun = @(Get-ChildItem $OutputRoot -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-\d{6} Renamed$' } | Sort-Object Name -Descending | Select-Object -First 1)
    if (-not $latestRun) { Write-Host "No Renamed folder found. Nothing to compile." -ForegroundColor Yellow; return }
    $OutDir = $latestRun.FullName
$sourceFiles = @(Get-ChildItem "$SourceDir\*.jpg","$SourceDir\*.jpeg","$SourceDir\*.png","$SourceDir\*.pdf" -File | Sort-Object Name)
$sourcePathIndex = @{}
foreach ($sf in $sourceFiles) { $sourcePathIndex[$sf.Name] = $sf.FullName }
    Invoke-CompileOnly -OutputRoot $OutputRoot -SourceDir $SourceDir -OutDir $OutDir -SourceFiles $sourceFiles -SourcePathIndex $sourcePathIndex -Results @() -CompleteOnly
    return
}

# ═════════════════════════════════════════════
# HELPERS
# ═════════════════════════════════════════════

function Get-FileHash256 {
    param([string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($Path)
        $hashBytes = $sha.ComputeHash($stream)
        $stream.Close()
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    } catch { return $null }
}

function Get-Manifest {
    param([string[]]$Folders)
    $all = @{}
    foreach ($f in $Folders) {
        $manifestPath = Join-Path $f "_manifest.json"
        if (Test-Path $manifestPath) {
            try {
                $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
                foreach ($entry in $m.files) {
                    $all[$entry.source_hash] = $entry
                }
            } catch { Write-Warning "Corrupt manifest: $manifestPath" }
        }
    }
    return $all
}

function Write-Manifest {
    param([string]$Folder, [array]$Entries, [string]$Timestamp)
    $manifest = [ordered]@{
        timestamp = $Timestamp
        files     = $Entries
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $Folder "_manifest.json") -Encoding UTF8
}

function Parse-BusinessRules {
    param([string]$RulesPath)
    if (-not (Test-Path $RulesPath)) { return @{} }
    $content = Get-Content -Path $RulesPath -Raw
    $rules = [ordered]@{
        vendorCorrections = @{}
        expectedAmounts   = @()
        caveats           = @()
        taxRules          = @()
        flags             = @()
        businessName      = ""
        knownIssues       = @()
    }

    $isKnownIssues = $RulesPath -like "*known-issues*"

    if ($content -match '(?m)^#\s*(.+)$') { $rules.businessName = $Matches[1].Trim() }

    $lines = $content -split "`n"
    $section = ""
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^##\s+(.+)$') { $section = $Matches[1].Trim(); continue }

        if ($isKnownIssues) {
            if ($t -match '^## Issue:\s+(.+)$') {
                $rules.knownIssues += @{ issue = $Matches[1]; lines = @() }
            } elseif ($t -match '^-\s+(.+)$' -and $rules.knownIssues.Count -gt 0) {
                $rules.knownIssues[-1].lines += $Matches[1]
            }
        }

        if ($t -match '^-\s*"(.+)"\s*→\s*"(.+)"(?:\s*\[(.+)\])?$') {
            $rules.vendorCorrections[$Matches[1]] = @{
                correct = $Matches[2]
                tags    = if ($Matches[3]) { $Matches[3] -split ',\s*' } else { @() }
            }
        }
        elseif ($section -match '(?i)expected' -and $t -match '^\$?([\d.]+)/month') {
            $rules.expectedAmounts += @{ amount = [double]$Matches[1]; period = "monthly" }
        }
        elseif ($section -match '(?i)caveats' -and $t -match '^- ')   { $rules.caveats += $t -replace '^-\s*','' }
        elseif ($section -match '(?i)tax' -and $t -match '^- ')        { $rules.taxRules += $t -replace '^-\s*','' }
        elseif ($section -match '(?i)flags' -and $t -match '^- ')      { $rules.flags += $t -replace '^-\s*','' }
    }
    return $rules
}

function Invoke-BusinessRules {
    param([object]$Receipt, [hashtable]$Rules)
    $changes = @(); $flags = @()

    foreach ($pattern in $Rules.vendorCorrections.Keys) {
        if ($Receipt.vendor -like "*$pattern*" -or $pattern -like "*$($Receipt.vendor)*") {
            $c = $Rules.vendorCorrections[$pattern]
            if ($c.correct -and $c.correct -ne $Receipt.vendor) {
                $changes += "Vendor corrected: '$($Receipt.vendor)' → '$($c.correct)'"
                $Receipt.vendor = $c.correct
            }
            if ($c.tags -contains "corporate") { $Receipt | Add-Member -NotePropertyName "business" -NotePropertyValue "corporate" -Force }
            if ($c.tags -contains "personal")  { $Receipt | Add-Member -NotePropertyName "business" -NotePropertyValue "personal" -Force }
            $tagStr = $c.tags -join ','
            if ($tagStr -match 'category:([\w\s]+)') {
                $newCat = $Matches[1].Trim()
                $changes += "Category overridden: '$($Receipt.category)' → '$newCat'"
                $Receipt.category = $newCat
            }
            break
        }
    }

    if ($Receipt.total_after_tax -and $Receipt.total_after_tax -gt 0 -and $Rules.expectedAmounts.Count -gt 0) {
        $matched = $false
        foreach ($exp in $Rules.expectedAmounts) {
            if ([math]::Abs([double]$Receipt.total_after_tax - $exp.amount) -lt 0.50) { $matched = $true; break }
        }
        if (-not $matched) { $flags += "Unexpected amount: $($Receipt.total_after_tax) (expected ~$($Rules.expectedAmounts[0].amount))" }
    }

    if ($Receipt.total_after_tax -and [double]$Receipt.total_after_tax -gt 500) { $flags += "Large amount: $($Receipt.total_after_tax)" }

    $Receipt | Add-Member -NotePropertyName "_changes" -NotePropertyValue $changes -Force
    $Receipt | Add-Member -NotePropertyName "_flags"   -NotePropertyValue $flags   -Force
    return $Receipt
}

function Invoke-GptAnalysis {
    param([string]$ImagePath, [string]$OpenRouterKey)
    $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $ext = [System.IO.Path]::GetExtension($ImagePath).TrimStart('.')

    $systemPrompt = @"
Extract receipt details from this image. Return ONLY valid JSON:
{"vendor":"merchant name","date":"YYYY-MM-DD","receipt_number":"INV-12345 or null if none visible","items":["item1"],"subtotal":45.00,"tax_pst":3.60,"tax_gst":2.25,"total_after_tax":50.85,"currency":"CAD","category":"short category","summary":"under 50 chars","image_filename":"{date} - {total_after_tax} - {summary}.$ext"}
total_after_tax must be a number, never Infinity. summary under 50 chars.
"@

    $body = @{ model="gpt-4o-mini"; messages=@(
        @{role="system"; content=$systemPrompt}
        @{role="user"; content=@(
            @{type="text"; text="Analyze this image."}
            @{type="image_url"; image_url=@{url="data:image/$ext;base64,$base64"}}
        )}
    ); max_tokens=2000; temperature=0.1 } | ConvertTo-Json -Depth 10 -Compress

    $response = Invoke-ApiCall -Uri "https://openrouter.ai/api/v1/chat/completions" -Method POST `
        -Headers @{ Authorization="Bearer $OpenRouterKey"; "X-Title"="receipt-pipeline" } `
        -Body $body -Domain "Bookkeeper" -Action "openrouter:chat-completion" -TimeoutSec 120

    $usage = if ($response.usage) { @{input=$response.usage.prompt_tokens; output=$response.usage.completion_tokens} } else { @{input=0; output=0} }

    $raw = $response.choices[0].message.content
    $clean = $raw -replace '(?s)^.*?(\{.*?\}).*?$', '$1' -replace ':\s*Infinity',': 0' -replace ':\s*-Infinity',': 0'
    return [PSCustomObject]@{ Raw = $raw; CleanJson = $clean; Usage = $usage }
}

function Merge-AnalysisResults {
    param([array]$AnalysisObjects)
    if ($AnalysisObjects.Count -le 1) { return $AnalysisObjects[0] }
    $mergeFields = @('vendor','date','total_after_tax','category','summary','receipt_number','currency','subtotal','tax_pst','tax_gst')
    $completeness = @{}
    foreach ($obj in $AnalysisObjects) {
        $score = 0
        foreach ($f in @('vendor','date','total_after_tax','category','summary','receipt_number','items')) {
            $val = $obj.$f
            if ($null -ne $val -and "$val" -ne '') {
                if ($f -eq 'total_after_tax' -and [double]$val -eq 0) { continue }
                $score++
            }
        }
        $pageNum = if ($obj.source_file -match '_p(\d+)\.') { [int]$Matches[1] } else { 1 }
        $completeness[$obj] = @{ score = $score; page = $pageNum }
    }
    $merged = [PSCustomObject]@{}
    foreach ($f in $mergeFields) {
        $candidates = @()
        foreach ($obj in $AnalysisObjects) {
            $val = $obj.$f
            if ($null -ne $val -and "$val" -ne '') {
                $candidates += [PSCustomObject]@{ value = $val; score = $completeness[$obj].score; page = $completeness[$obj].page }
            }
        }
        if ($candidates.Count -eq 0) { $merged | Add-Member -NotePropertyName $f -NotePropertyValue $null -Force; continue }
        $candidates = $candidates | Sort-Object @{Expression='score'; Descending=$true}, @{Expression='page'; Ascending=$true}
        $merged | Add-Member -NotePropertyName $f -NotePropertyValue $candidates[0].value -Force
    }
    $allItems = @()
    foreach ($obj in $AnalysisObjects) {
        if ($obj.items) { $allItems += $obj.items }
    }
    $merged | Add-Member -NotePropertyName 'items' -NotePropertyValue ($allItems | Select-Object -Unique) -Force
    $merged | Add-Member -NotePropertyName 'source_file' -NotePropertyValue $AnalysisObjects[0].source_file -Force
    $merged | Add-Member -NotePropertyName '_changes' -NotePropertyValue @() -Force
    $merged | Add-Member -NotePropertyName '_flags' -NotePropertyValue @() -Force
    $cleanedTotal = if ($null -ne $merged.total_after_tax -and "$($merged.total_after_tax)" -ne '' -and [double]$merged.total_after_tax -ne 0) { $merged.total_after_tax } else { 0 }
    $datePart = if ($merged.date) { $merged.date } else { Get-Date -Format 'yyyy-MM-dd' }
    $summaryPart = if ($merged.summary) { ($merged.summary -replace '[^\w\s-]','').Trim().Substring(0, [Math]::Min(50, ($merged.summary -replace '[^\w\s-]','').Trim().Length)) } else { $merged.vendor }
    $merged | Add-Member -NotePropertyName 'image_filename' -NotePropertyValue "$datePart - $cleanedTotal - $summaryPart.pdf" -Force
    return $merged
}

function Write-CompleteCsv {
    param([string]$CsvPath, [array]$Entries)
    $csvLines = @()
    $csvLines += '"filename","original_filename","date","amount","vendor","notes","hash","present_in_source","error_status"'
    foreach ($e in $Entries) {
        $esc = { param($v) if ($null -eq $v) { '' } else { ('"' + ("$v" -replace '"','""') + '"') } }
        $csvLines += "$(&$esc $e.filename),$(&$esc $e.original_filename),$(&$esc $e.date),$(&$esc $e.amount),$(&$esc $e.vendor),$(&$esc $e.notes),$(&$esc $e.hash),$(&$esc $e.present_in_source),$(&$esc $e.error_status)"
    }
    $utf8Bom = [System.Text.Encoding]::UTF8.GetPreamble()
    $content = [System.Text.Encoding]::UTF8.GetString($utf8Bom) + ($csvLines -join "`r`n")
    [System.IO.File]::WriteAllText($CsvPath, $content, [System.Text.Encoding]::UTF8)
}

function Invoke-CompileOnly {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OutputRoot,
        [string]$SourceDir,
        [string]$OutDir,
        [array]$SourceFiles,
        [hashtable]$SourcePathIndex,
        [array]$Results,
        [switch]$CompleteOnly
    )

    Write-Host "=== STAGE 5: Compile Complete folder ===" -ForegroundColor Cyan

    $CompleteDir = Join-Path $OutputRoot "Complete"
    New-Item -ItemType Directory -Path $CompleteDir -Force | Out-Null
    $CsvPath = Join-Path $CompleteDir "manifest.csv"

    $csvIndex = @{}
    if (Test-Path $CsvPath) {
        Import-Csv $CsvPath | ForEach-Object { $csvIndex[$_.original_filename] = $_ }
    }

    foreach ($sf in $SourceFiles) {
        if (-not $csvIndex.ContainsKey($sf.Name)) {
            $csvIndex[$sf.Name] = [PSCustomObject]@{
                filename = ''
                original_filename = $sf.Name
                date = ''
                amount = ''
                vendor = ''
                notes = ''
                hash = ''
                present_in_source = "TRUE"
                error_status = "not yet processed"
            }
        }
    }

    $deprecatedKeys = @()
    foreach ($key in $csvIndex.Keys) {
        $row = $csvIndex[$key]
        if ($row.present_in_source -eq "TRUE" -and -not (Test-Path (Join-Path $SourceDir $key))) {
            $row.present_in_source = "FALSE"
            if ($row.notes) { $row.notes += "; deprecated: source file removed" }
            else { $row.notes = "deprecated: source file removed" }
        }
    }

    $sourceGroups = @{}
    if ($Results.Count -eq 0 -and $CompleteOnly) {
        $manifestPath = Join-Path $OutDir "_manifest.json"
        if (Test-Path $manifestPath) {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            foreach ($mf in $manifest.files) {
                $srcName = $mf.source
                $baseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($srcName)
                $originalSource = if ($srcName -match '^(.+?)(?:_p\d+)?\.(jpg|jpeg|png)$') { "$($Matches[1]).pdf" } else { $srcName }
                $sidecarPath = Join-Path $OutDir "$($mf.output).json"
                $analysisObj = if (Test-Path $sidecarPath) { Get-Content $sidecarPath -Raw | ConvertFrom-Json } else { $null }
                $resultObj = [PSCustomObject]@{
                    SourceFile = $srcName
                    OutputFile = $mf.output
                    Vendor = $mf.vendor
                    Date = ''
                    Total = $mf.total
                    Status = $mf.status
                    Currency = ''
                    Category = ''
                    Summary = $mf.summary
                    Changes = ''
                    Flags = ''
                    SourceHash = $mf.source_hash
                    Analysis = $analysisObj
                }
                if (-not $sourceGroups.ContainsKey($originalSource)) { $sourceGroups[$originalSource] = @() }
                $sourceGroups[$originalSource] += $resultObj
            }
        }
    } else {
        foreach ($result in $Results) {
            $srcName = $result.SourceFile
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($srcName)
            $srcBase = $baseName -replace '_\d+$','' -replace '_p\d+$',''
            $originalSource = $srcName
            if ($srcName -match '^(.+?)(?:_p\d+)?\.') { $originalSource = "$($Matches[1]).pdf" }
            if (-not $sourceGroups.ContainsKey($originalSource)) { $sourceGroups[$originalSource] = @() }
            $sourceGroups[$originalSource] += $result
        }
    }

    $placedFiles = @()
    $placedNames = @()
    foreach ($srcGroupKey in $sourceGroups.Keys) {
        $groupResults = $sourceGroups[$srcGroupKey]
        $okResults = $groupResults | Where-Object { $_.Status -eq "ok" }
        if ($okResults.Count -eq 0) {
            $errMsgs = ($groupResults | ForEach-Object { $_.Status }) -join '; '
            if ($csvIndex.ContainsKey($srcGroupKey)) { $csvIndex[$srcGroupKey].error_status = $errMsgs }
            continue
        }
        $srcPath = if ($SourcePathIndex) { $SourcePathIndex[$srcGroupKey] } else { $null }
        if (-not $srcPath -and $SourcePathIndex) { $srcPath = $SourcePathIndex.Values | Select-Object -First 1 }
        $isPdf = $srcGroupKey -match '\.pdf$'
        $isMultiPage = ($okResults.Count -gt 1 -and $isPdf)
        $completeFilename = ''
        $hashValue = ''
        if ($isMultiPage) {
            $allAnalyses = @()
            foreach ($gr in $okResults) {
                $sidecarPath = Join-Path $OutDir "$($gr.OutputFile).json"
                if (Test-Path $sidecarPath) {
                    $analysisObj = Get-Content $sidecarPath -Raw | ConvertFrom-Json
                    $allAnalyses += $analysisObj
                }
            }
            $mergedAnalysis = Merge-AnalysisResults -AnalysisObjects $allAnalyses
            $pdfSourcePath = if ($srcPath) { $srcPath } else { Join-Path $SourceDir $srcGroupKey }
            $jpegName = $mergedAnalysis.image_filename
            $completeFilename = [System.IO.Path]::GetFileNameWithoutExtension($jpegName) + '.pdf'
            $completeFilename = Resolve-FilenameCollision -ProposedFilename $completeFilename -ExistingFilenames $placedNames -Analysis $mergedAnalysis
            Copy-Item -LiteralPath $pdfSourcePath -Destination (Join-Path $CompleteDir $completeFilename) -Force
            $hashValue = Get-FileHash256 -Path (Join-Path $CompleteDir $completeFilename)
            if ($mergedAnalysis._changes -and $mergedAnalysis._changes.Count -gt 0) {
                $changeStr = $mergedAnalysis._changes -join '; '
                if ($csvIndex.ContainsKey($srcGroupKey)) { $csvIndex[$srcGroupKey].notes = $changeStr }
            }
        } else {
            $gr = $okResults | Select-Object -First 1
            $srcPathForCopy = (Join-Path $OutDir $gr.OutputFile)
            $completeFilename = $gr.OutputFile
            $completeFilename = Resolve-FilenameCollision -ProposedFilename $completeFilename -ExistingFilenames $placedNames -Analysis ([PSCustomObject]@{ receipt_number = ''; _changes = @() })
            Copy-Item -LiteralPath $srcPathForCopy -Destination (Join-Path $CompleteDir $completeFilename) -Force
            $hashValue = Get-FileHash256 -Path (Join-Path $CompleteDir $completeFilename)
        }
        $placedFiles += $completeFilename
        $placedNames += $completeFilename
        $amountVal = if ($okResults[0].Total) { $okResults[0].Total } else { 0 }
        $vendorVal = if ($okResults[0].Vendor) { $okResults[0].Vendor } else { '' }
        $dateVal = if ($okResults[0].Date) { $okResults[0].Date } else { '' }
        if ($csvIndex.ContainsKey($srcGroupKey)) {
            $csvIndex[$srcGroupKey].filename = $completeFilename
            $csvIndex[$srcGroupKey].date = $dateVal
            $csvIndex[$srcGroupKey].amount = $amountVal
            $csvIndex[$srcGroupKey].vendor = $vendorVal
            $csvIndex[$srcGroupKey].hash = $hashValue
            $csvIndex[$srcGroupKey].error_status = ''
        }
    }

    $strictDedupSeen = @{}
    $strictDedupRemoved = 0
    $dedupedValues = new-object System.Collections.ArrayList
    foreach ($entry in $csvIndex.Values) {
        if ($entry.hash -and $entry.date -and $entry.amount) {
            $ddKey = "$($entry.hash)|$($entry.date)|$($entry.amount)"
            if ($strictDedupSeen.ContainsKey($ddKey)) {
                $existing = $strictDedupSeen[$ddKey]
                Write-Host "  STRICT DEDUP: $($entry.filename) matches $existing (same hash+date+amount)" -ForegroundColor Yellow
                $strictDedupRemoved++
                continue
            }
            $strictDedupSeen[$ddKey] = $entry.filename
        }
        [void]$dedupedValues.Add($entry)
    }
    if ($strictDedupRemoved -gt 0) {
        Write-Host "  Strict dedup removed $strictDedupRemoved duplicate(s) (hash+date+amount)" -ForegroundColor Yellow
    }

    Write-CompleteCsv -CsvPath $CsvPath -Entries ($dedupedValues)

    $missingFiles = @()
    foreach ($entry in $csvIndex.Values) {
        if ($entry.present_in_source -eq "TRUE" -and $entry.error_status -eq '') {
            if (-not (Test-Path (Join-Path $CompleteDir $entry.filename))) {
                $missingFiles += $entry.original_filename
                Write-Warning "Missing file in Complete/: $($entry.filename) (source: $($entry.original_filename))"
            }
        }
    }
    if ($missingFiles.Count -gt 0) { Write-Host "WARNING: $($missingFiles.Count) file(s) missing from Complete folder" -ForegroundColor Yellow }
    else { Write-Host "  Coverage check passed: all entries present" -ForegroundColor Green }

    if (-not $CompleteOnly) {
        try {
            if ($PSCmdlet.ShouldProcess("Intermediate folders", "Clean up temporary directories")) {
                Remove-Item -Path (Split-Path -Parent $OutDir) -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  Cleaned up intermediate folders" -ForegroundColor Cyan
            }
        } catch { Write-Warning "Cleanup failed: $_" }
    }
}

function Resolve-FilenameCollision {
    param([string]$ProposedFilename, [string[]]$ExistingFilenames, [PSCustomObject]$Analysis)
    if ($ProposedFilename -notin $ExistingFilenames) { return $ProposedFilename }
    $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($ProposedFilename)
    $ext = [System.IO.Path]::GetExtension($ProposedFilename)
    if ($Analysis.receipt_number -and "$($Analysis.receipt_number)" -ne '') {
        $newName = "$nameNoExt - $($Analysis.receipt_number)$ext"
        if ($newName -notin $ExistingFilenames) { $Analysis._changes += "Collision resolved via receipt_number"; return $newName }
    }
    $expanded = "$nameNoExt - 0000$ext"
    if ($expanded -notin $ExistingFilenames) { $Analysis._changes += "Collision resolved via datetime expansion"; return $expanded }
    $suffix = 2
    while ($true) {
        $candidate = "$nameNoExt - $suffix$ext"
        if ($candidate -notin $ExistingFilenames) { $Analysis._changes += "Collision resolved via numeric suffix -$suffix"; return $candidate }
        $suffix++
    }
}

function Write-ErrorSidecar {
    param([string]$SourceName, [string]$Reason, [string]$ImagePath, [string]$ErrDir)
    $fn = [System.IO.Path]::GetFileNameWithoutExtension($SourceName) + " - MODEL_REFUSAL.jpg"
    $sidecar = [ordered]@{
        vendor = "ERROR: Model Refusal"
        total_after_tax = 0; currency = "CAD"; date = (Get-Date -Format "yyyy-MM-dd")
        category = "unknown"; summary = "Model refused to analyze"
        error = $Reason; retry = $true; original_source = $SourceName
    }
    Copy-Item -LiteralPath $ImagePath -Destination (Join-Path $ErrDir $fn) -Force
    $sidecar | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ErrDir "${fn}.json") -Encoding UTF8
    return $fn, $sidecar
}

# ═════════════════════════════════════════════
# STAGE 1 — Pre-processing with hash dedup
# ═════════════════════════════════════════════

Write-Host "=== STAGE 1: Pre-processing ===" -ForegroundColor Cyan

# Find existing rename/error folders for dedup
$existingRuns = @(Get-ChildItem $OutputRoot -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-\d{6} (Renamed|Errors)$' -and $_.Name -notlike '*Complete*' })
$existingManifest = Get-Manifest -Folders ($existingRuns.FullName)
Write-Host "  Found $($existingManifest.Count) previously processed files across $($existingRuns.Count) run(s)" -ForegroundColor Cyan

# Gather source files
$sourceFiles = @(Get-ChildItem "$SourceDir\*.jpg","$SourceDir\*.jpeg","$SourceDir\*.png","$SourceDir\*.pdf" -File | Sort-Object Name)

# Dedup: check hashes against prior manifests
$toProcess = @()
$skipped = 0
foreach ($f in $sourceFiles) {
    $hash = Get-FileHash256 -Path $f.FullName
    if (-not $ForceReRun -and $hash -and $existingManifest.ContainsKey($hash)) {
        $entry = $existingManifest[$hash]
        if ($entry.status -eq "ok") { $skipped++; continue }
    }
    $toProcess += @{ File = $f; Hash = $hash }
}
Write-Host "  $skipped file(s) skipped (already processed)" -ForegroundColor Cyan
Write-Host "  $($toProcess.Count) file(s) to process" -ForegroundColor Cyan

if ($toProcess.Count -eq 0) { Write-Host "Nothing to process." -ForegroundColor Green; return }

# Convert PDFs, copy images to Preprocessing folder
New-Item -ItemType Directory -Path $PrepDir -Force | Out-Null
$convertedImages = @()

foreach ($item in $toProcess) {
    $f = $item.File
    if ($f.Extension -match '\.(jpg|jpeg|png)') {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $PrepDir $f.Name) -Force
        $convertedImages += @{ Path = Join-Path $PrepDir $f.Name; Hash = $item.Hash; SourcePath = $f.FullName; SourceName = $f.Name }
    }
}

if ($ConvertPdf) {
    $pdfItems = $toProcess | Where-Object { $_.File.Extension -eq '.pdf' }
    Write-Host "  Converting $($pdfItems.Count) PDF(s)..."
    $skippedPdfs = [System.Collections.ArrayList]@()
    if ($pdfItems.Count -gt 0) {
        $pyScript = @'
import fitz, os, sys, hashlib, json
src, out, hashes_file = sys.argv[1], sys.argv[2], sys.argv[3]
results = []
for f in sorted(os.listdir(src)):
    if f.lower().endswith('.pdf'):
        path = os.path.join(src, f)
        try:
            doc = fitz.open(path)
            total_pages = doc.page_count
            if total_pages == 0:
                print(f"EMPTY_PDF: {f} - PDF has 0 pages")
                doc.close()
                continue
            converted = 0
            for i, page in enumerate(doc):
                pix = page.get_pixmap(dpi=200)
                base = os.path.splitext(f)[0]
                fn = f"{base}_p{i+1}.jpg"
                outpath = os.path.join(out, fn)
                pix.save(outpath)
                with open(outpath, 'rb') as fh:
                    h = hashlib.sha256(fh.read()).hexdigest()
                results.append({"source": f, "page": i+1, "file": fn, "hash": h})
                converted += 1
            doc.close()
            # Image-only PDFs may convert to blank/black pages — flag them
            if converted == total_pages and total_pages > 0:
                pass  # all pages converted nominally
        except fitz.FileDataError:
            print(f"CORRUPT_PDF: {f} - password-protected or corrupted file — moving on")
        except fitz.EmptyFileError:
            print(f"EMPTY_FILE: {f} - file is empty or not a valid PDF")
        except Exception as e:
            print(f"FAILED: {f} - {e}")
with open(hashes_file, 'w') as fh:
    json.dump(results, fh)
'@
        $pyPath = Join-Path $PrepDir "_convert.py"
        $hashesPath = Join-Path $PrepDir "_converted_hashes.json"
        Set-Content -Path $pyPath -Value $pyScript -Encoding UTF8
        try {
            $pyOutput = & python $pyPath $SourceDir $PrepDir $hashesPath 2>&1
            $corruptPdfs = [System.Collections.ArrayList]@()
            $emptyPdfs = [System.Collections.ArrayList]@()
            foreach ($line in $pyOutput) {
                Write-Host "  $line"
                if ($line -match '^FAILED:\s*(.+?)\s*-') {
                    [void]$skippedPdfs.Add($Matches[1].Trim())
                }
                if ($line -match '^CORRUPT_PDF:\s*(.+?)\s*-') {
                    [void]$corruptPdfs.Add($Matches[1].Trim())
                }
                if ($line -match '^EMPTY_PDF:\s*(.+?)\s*-') {
                    [void]$emptyPdfs.Add($Matches[1].Trim())
                }
                if ($line -match '^EMPTY_FILE:\s*(.+?)\s*-') {
                    [void]$emptyPdfs.Add($Matches[1].Trim())
                }
            }
            foreach ($cp in $corruptPdfs) {
                Write-Host "  CORRUPT PDF (skipped): $cp" -ForegroundColor Yellow
                if ($cp -notin $skippedPdfs) { [void]$skippedPdfs.Add($cp) }
            }
            foreach ($ep in $emptyPdfs) {
                Write-Host "  EMPTY PDF (skipped): $ep" -ForegroundColor Yellow
                if ($ep -notin $skippedPdfs) { [void]$skippedPdfs.Add($ep) }
            }
        } catch {
            Write-Host "  PDF conversion engine failed: $_" -ForegroundColor Red
            foreach ($pi in $pdfItems) { [void]$skippedPdfs.Add($pi.File.Name) }
        }
        Remove-Item $pyPath -Force -ErrorAction SilentlyContinue

        if (Test-Path $hashesPath) {
            $convertedHashes = Get-Content $hashesPath -Raw | ConvertFrom-Json
            foreach ($ch in $convertedHashes) {
                $srcItem = $toProcess | Where-Object { $_.File.Name -eq $ch.source } | Select-Object -First 1
                $convertedImages += @{ Path = Join-Path $PrepDir $ch.file; Hash = $ch.hash; SourcePdfHash = $srcItem.Hash; SourceName = $ch.source; SourcePath = $srcItem.File.FullName }
            }
            Remove-Item $hashesPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($skippedPdfs.Count -gt 0) {
        Write-Host "  Skipped $($skippedPdfs.Count) corrupt/unprocessable PDF(s):" -ForegroundColor Yellow
        foreach ($sp in $skippedPdfs) { Write-Host "    SKIP: $sp" -ForegroundColor Yellow }
    }
}

# Also re-process files from prior error runs
$errorItems = @()
foreach ($run in $existingRuns) {
    if ($run.Name -match ' Errors$') {
        $errFiles = Get-ChildItem "$($run.FullName)\*.jpg" -File
        foreach ($ef in $errFiles) {
            $hash = Get-FileHash256 -Path $ef.FullName
            # Check if this error file's original source is in our toProcess list
            $sidecarPath = $ef.FullName + ".json"
            if (Test-Path $sidecarPath) {
                $sc = Get-Content $sidecarPath -Raw | ConvertFrom-Json
                $originalSource = $sc.original_source
                # Only re-process if original source still exists
                if ($originalSource -and (Test-Path (Join-Path $SourceDir $originalSource))) {
                    Copy-Item -LiteralPath $ef.FullName -Destination (Join-Path $PrepDir $ef.Name) -Force
                    $convertedImages += @{ Path = Join-Path $PrepDir $ef.Name; Hash = $hash; FromError = $true }
                    Write-Host "  Re-processing error: $originalSource" -ForegroundColor Yellow
                }
            }
        }
    }
}

$allImages = @(Get-ChildItem "$PrepDir\*.jpg","$PrepDir\*.jpeg","$PrepDir\*.png" -File | Sort-Object Name)
Write-Host "  Total images ready: $($allImages.Count)" -ForegroundColor Green

if ($allImages.Count -eq 0) { Write-Host "No images to process." -ForegroundColor Green; return }

# ═════════════════════════════════════════════
# STAGE 2 — Load rules (business + known-issues)
# ═════════════════════════════════════════════

$allRules = @{}; $knownIssues = @()
if ($RulesDir -and (Test-Path $RulesDir)) {
    Get-ChildItem "$RulesDir\*.md" -File | ForEach-Object {
        $isKnownIssues = $_.Name -eq "known-issues.md" -or $_.Name -like "*known-issues*"
        $r = Parse-BusinessRules -RulesPath $_.FullName
        if ($isKnownIssues) {
            Write-Host "  Loaded known-issues: $($r.knownIssues.Count) issue(s)" -ForegroundColor Cyan
        } elseif ($r.businessName) {
            $allRules[$r.businessName] = $r
        }
    }
    Write-Host "=== STAGE 2: Rules ===" -ForegroundColor Cyan
    Write-Host "  Loaded $($allRules.Count) business rule set(s): $($allRules.Keys -join ', ')" -ForegroundColor Cyan
}

# ═════════════════════════════════════════════
# STAGE 3 — Vision + post-processing
# ═════════════════════════════════════════════

Write-Host "=== STAGE 3: Vision analysis ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path $ErrDir -Force | Out-Null

$results = @(); $index = 0; $totalTokens = @{input=0; output=0}
$selectedImages = $allImages | Select-Object -First $MaxImages

foreach ($img in $selectedImages) {
    $index++; $srcName = $img.Name
    Write-Host "[$index/$($selectedImages.Count)] $srcName" -NoNewline

    # Find matching hash info
    $imgInfo = $convertedImages | Where-Object { [System.IO.Path]::GetFileName($_.Path) -eq $srcName } | Select-Object -First 1
    $sourceHash = if ($imgInfo) { $imgInfo.Hash } else { Get-FileHash256 -Path $img.FullName }

    try {
        $analysis = Invoke-GptAnalysis -ImagePath $img.FullName -OpenRouterKey $OpenRouterKey
        $totalTokens.input  += $analysis.Usage.input
        $totalTokens.output += $analysis.Usage.output
        $parsed = $analysis.CleanJson | ConvertFrom-Json

        # Sanity check: did the model actually return data or refuse?
        $modelRefused = ($analysis.Raw -match "unable to analyze|I'm unable|cannot analyze|I can't analyze") -or (-not $parsed.vendor -and -not $parsed.total_after_tax)

        if ($modelRefused) {
            Write-Host " → MODEL REFUSAL" -ForegroundColor Red
            $fn, $sidecar = Write-ErrorSidecar -SourceName $srcName -Reason "Model refused: $($analysis.Raw.Substring(0, [Math]::Min(100, $analysis.Raw.Length)))" -ImagePath $img.FullName -ErrDir $ErrDir
            $results += [PSCustomObject]@{ SourceFile=$srcName; OutputFile=$fn; Vendor=$sidecar.vendor; Date=$sidecar.date; Total=$sidecar.total_after_tax; Currency=$sidecar.currency; Category=$sidecar.category; Summary=$sidecar.summary; Changes=""; Flags=""; Status="error: model refusal"; SourceHash=$sourceHash }
            continue
        }

        $ext = $img.Extension.TrimStart('.'); $safeExt = $ext -replace '[^a-zA-Z0-9]',''

        if ($null -eq $parsed.total_after_tax -or "$($parsed.total_after_tax)" -eq "") { $parsed.total_after_tax = 0 }
        if (-not $parsed.vendor)   { $parsed | Add-Member -NotePropertyName "vendor"   -NotePropertyValue "Unknown Vendor" -Force }
        if (-not $parsed.summary)  { $parsed | Add-Member -NotePropertyName "summary"  -NotePropertyValue $parsed.vendor -Force }
        if (-not $parsed.date)     { $parsed | Add-Member -NotePropertyName "date"     -NotePropertyValue (Get-Date -Format "yyyy-MM-dd") -Force }
        if (-not $parsed.currency) { $parsed | Add-Member -NotePropertyName "currency" -NotePropertyValue "CAD" -Force }
        if (-not $parsed.receipt_number) { $parsed | Add-Member -NotePropertyName "receipt_number" -NotePropertyValue "" -Force }

        $rawFn = if ($parsed.image_filename) { $parsed.image_filename } else { "output.$safeExt" }
        $fn = [System.IO.Path]::GetFileNameWithoutExtension($rawFn) + ".$safeExt"
        $parsed.image_filename = $fn
        $parsed | Add-Member -NotePropertyName "source_file" -NotePropertyValue $srcName -Force

        # Post-processing: business rules
        if ($allRules.Count -gt 0) {
            foreach ($rName in $allRules.Keys) {
                if ($parsed.vendor -like "*$rName*" -or $rName -like "*$($parsed.vendor)*") {
                    $parsed = Invoke-BusinessRules -Receipt $parsed -Rules $allRules[$rName]
                    break
                }
            }
        }

        # Write output
        $outPath = Join-Path $OutDir $fn
        Copy-Item -LiteralPath $img.FullName -Destination $outPath -Force
        $parsed | ConvertTo-Json -Depth 5 | Set-Content -Path "${outPath}.json" -Encoding UTF8

        $changeInfo = if ($parsed._changes) { " [$($parsed._changes -join '; ')]" } else { "" }
        $flagInfo   = if ($parsed._flags)   { " ⚠ $($parsed._flags -join '; ')" } else { "" }
        Write-Host " → $fn$changeInfo$flagInfo" -ForegroundColor Green

        $results += [PSCustomObject]@{
            SourceFile=$srcName; OutputFile=$fn; Vendor=$parsed.vendor; Date=$parsed.date
            Total=$parsed.total_after_tax; Currency=$parsed.currency; Category=$parsed.category
            Summary=$parsed.summary; Changes=($parsed._changes -join "; "); Flags=($parsed._flags -join "; ")
            Status="ok"; SourceHash=$sourceHash
        }
    }
    catch {
        Write-Host " → ERROR: $_" -ForegroundColor Red
        $fn, $sidecar = Write-ErrorSidecar -SourceName $srcName -Reason "$_" -ImagePath $img.FullName -ErrDir $ErrDir
        $results += [PSCustomObject]@{
            SourceFile=$srcName; OutputFile=$fn; Vendor=$sidecar.vendor; Date=$sidecar.date
            Total=$sidecar.total_after_tax; Currency=$sidecar.currency; Category=$sidecar.category
            Summary=$sidecar.summary; Changes=""; Flags=""; Status="error: $_"; SourceHash=$sourceHash
        }
    }
}

# ═════════════════════════════════════════════
# STAGE 4 — Write manifest + summary
# ═════════════════════════════════════════════

$manifestEntries = @()
foreach ($r in $results) {
    $manifestEntries += [ordered]@{
        source       = $r.SourceFile
        source_hash  = $r.SourceHash
        output       = $r.OutputFile
        vendor       = $r.Vendor
        total        = $r.Total
        status       = if ($r.Status -eq "ok") { "ok" } else { "error" }
        summary      = $r.Summary
    }
}
Write-Manifest -Folder $OutDir -Entries $manifestEntries -Timestamp $Timestamp

if ((Get-ChildItem $ErrDir -Filter *.jpg).Count -gt 0) {
    Write-Manifest -Folder $ErrDir -Entries ($manifestEntries | Where-Object { $_.status -eq "error" }) -Timestamp $Timestamp
}

$ok   = ($results | Where-Object Status -eq "ok").Count
$err  = ($results | Where-Object { $_.Status -ne "ok" }).Count
$totalInput  = [int]$totalTokens.input
$totalOutput = [int]$totalTokens.output
$estCost     = [math]::Round(($totalInput * 0.15 + $totalOutput * 0.60) / 1e6, 4)

Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  DONE: $ok ok, $err errors" -ForegroundColor Green
Write-Host "  Tokens: $totalInput in / $totalOutput out  Cost: ~`$$estCost" -ForegroundColor Cyan
Write-Host "  Preprocessing: $PrepDir" -ForegroundColor Cyan
Write-Host "  Output:        $OutDir" -ForegroundColor Cyan
if ($err -gt 0) { Write-Host "  Errors:        $ErrDir" -ForegroundColor Yellow }
Write-Host "============================================" -ForegroundColor Green

$flagged = $results | Where-Object { $_.Flags }
if ($flagged) {
    Write-Host "`n=== FLAGGED ===" -ForegroundColor Yellow
    $flagged | Select-Object OutputFile, Vendor, Total, Flags | Format-Table -AutoSize
}

# ═════════════════════════════════════════════
# STAGE 5 — Complete folder compilation
# ═════════════════════════════════════════════

Invoke-CompileOnly -OutputRoot $OutputRoot -SourceDir $SourceDir -OutDir $OutDir -SourceFiles $sourceFiles -SourcePathIndex $sourcePathIndex -Results $results -CompleteOnly:$CompleteOnly


