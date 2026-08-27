# Vision.ReceiptOcr — capability gate for receipt OCR.
# Required keys: <vision api key>.
# Capabilities: vision:ocr.

function Save-VisionOutput {
    [CmdletBinding()]
    param(
        [string]$ImageBase64,
        [string]$Subdir,
        [string]$Filename,
        $Sidecar,
        [string]$Mode
    )
    $visionBase = "/data/vision-output"
    $targetDir = Join-Path $visionBase $Subdir
    if (-not (Test-Path $targetDir)) {
        $null = New-Item -ItemType Directory -Path $targetDir -Force
    }
    $imagePath = Join-Path $targetDir $Filename
    try {
        [System.IO.File]::WriteAllBytes($imagePath, [System.Convert]::FromBase64String($ImageBase64))
    }
    catch {
        return $null
    }
    $jsonPath = $imagePath + ".json"
    $Sidecar | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
    return $imagePath
}

function Invoke-ReceiptOcr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImageBase64,
        [string]$Filename,
        [string]$Mode = 'receipt'
    )

    Test-BookkeepingCapability -RequiredCapability 'vision:ocr'

    if ($Mode -notin @('receipt', 'inventory', 'product-inventory')) {
        throw "Mode must be 'receipt' or 'inventory'"
    }

    $subdir = if ($Mode -eq 'receipt') { 'receipts' } else { 'products' }

    $analysis = Invoke-ImageAnalysis -ImageBase64 $ImageBase64 -Mode $Mode -Filename $Filename
    Write-AuditEntry -Entry @{
        ts = (Get-Date -Format 'o')
        action = "vision:ocr"
        domain = "Bookkeeper"
        req = @{ mode = $Mode; filename = $Filename }
        res = @{ success = ($null -ne $analysis) }
    } -Domain "Bookkeeper"
    if (-not $analysis) {
        return $null
    }

    if ($Mode -eq 'receipt') {
        $sidecar = [pscustomobject]@{
            vendor          = $analysis.vendor
            date            = $analysis.date
            items           = @($analysis.items)
            subtotal        = $analysis.subtotal
            tax_pst         = $analysis.tax_pst
            tax_gst         = $analysis.tax_gst
            total_after_tax = $analysis.total_after_tax
            currency        = $analysis.currency
            category        = $analysis.category
            summary         = $analysis.summary
            image_filename  = $analysis.image_filename
        }

        $saveResult = Save-VisionOutput -ImageBase64 $ImageBase64 -Subdir $subdir -Filename $analysis.image_filename -Sidecar $sidecar -Mode 'receipt'
        if (-not $saveResult) { return $null }

        Write-BookkeepingAuditEntry -Capability 'vision:ocr' -Action "Invoke-ReceiptOcr" -Context @{ Mode = 'receipt' } -Result 'allow'
        return [pscustomobject]@{
            Vendor   = $analysis.vendor
            Date     = $analysis.date
            Amount   = $analysis.total_after_tax
            TaxAmount = ($analysis.tax_gst + $analysis.tax_pst)
            LineItems = @($analysis.items)
            ImageFilename = $analysis.image_filename
        }
    }

    if ($Mode -eq 'inventory') {
        Write-BookkeepingAuditEntry -Capability 'vision:ocr' -Action "Invoke-ReceiptOcr" -Context @{ Mode = 'inventory' } -Result 'allow'
        return [pscustomobject]@{
            ProductName = $analysis.product_name
            Category    = $analysis.category
            Potency     = $analysis.potency
            Confidence  = $analysis.confidence
            RawLabels   = @($analysis.raw_labels)
        }
    }

    return $null
}
