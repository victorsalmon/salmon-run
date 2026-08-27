function Invoke-ImageAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImageBase64,
        [string]$Mode = 'receipt',
        [string]$Filename
    )

    $tempDir = "/tmp/vision-analysis"
    $null = New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction SilentlyContinue

    $tempImage = Join-Path $tempDir "input.png"
    try {
        [System.IO.File]::WriteAllBytes($tempImage, [System.Convert]::FromBase64String($ImageBase64))
    } catch {
        Write-Warning "Invoke-ImageAnalysis: failed to decode base64 image - $_"
        return $null
    }

    $outputDir = "/tmp/vision-output"
    $null = New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction SilentlyContinue

    $pythonScript = Join-Path $PSScriptRoot '..' '..' '..' '..' 'vision' 'extract-receipt-ocr.py'
    $outputSidecar = Join-Path $outputDir "$([System.IO.Path]::GetFileNameWithoutExtension($tempImage)).json"

    $env:OPENROUTER_API_KEY = $script:OpenRouterApiKey
    try {
        $ocrOutput = python3 $pythonScript $tempImage --output-dir $outputDir --api-key-env OPENROUTER_API_KEY 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Warning "Invoke-ImageAnalysis: python3 execution failed - $_"
        return $null
    }

    if ($exitCode -ne 0) {
        Write-Warning "Invoke-ImageAnalysis: OCR script exited with code ${exitCode}: $ocrOutput"
        return $null
    }

    if (-not (Test-Path $outputSidecar)) {
        Write-Warning "Invoke-ImageAnalysis: no output produced by OCR script ($outputSidecar)"
        return $null
    }

    $ocrResult = Get-Content -Path $outputSidecar -Raw | ConvertFrom-Json

    $imageFilename = if ($Filename) { $Filename } else { "receipt-$(Get-Date -Format 'yyyyMMdd-HHmmss').png" }

    return [pscustomobject]@{
        vendor          = $ocrResult.vendor
        date            = $ocrResult.date
        items           = if ($ocrResult.items) { @($ocrResult.items) } else { @() }
        subtotal        = $ocrResult.subtotal
        tax_pst         = 0
        tax_gst         = if ($ocrResult.tax) { [double]$ocrResult.tax } else { 0 }
        total_after_tax = if ($ocrResult.total) { [double]$ocrResult.total } elseif ($ocrResult.amount) { [double]$ocrResult.amount } else { 0 }
        currency        = if ($ocrResult.currency) { $ocrResult.currency } else { "CAD" }
        category        = "Uncategorized"
        summary         = $ocrResult.summary
        image_filename  = $imageFilename
    }
}
