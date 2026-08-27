<#
.SYNOPSIS
Creates Zoho Books expenses for room-rentals org with receipt attachment.

.DESCRIPTION
Creates expenses in Zoho Books for the room-rentals organization (925004567)
and attaches receipt files via multipart/form-data upload. Supports dry-run
mode and pre-obtained tokens to avoid OAuth rate limiting.

.PARAMETER Token
Pre-obtained Zoho OAuth access token. If omitted, one is fetched using
RefreshToken/ClientId/ClientSecret (consumes an OAuth rate-limit slot).

.PARAMETER RefreshToken
Zoho Books refresh token. If omitted, resolved from env vars or AWS Secrets Manager.

.PARAMETER ClientId
Zoho Books client ID. If omitted, resolved from env vars or AWS Secrets Manager.

.PARAMETER ClientSecret
Zoho Books client secret. If omitted, resolved from env vars or AWS Secrets Manager.

.PARAMETER OrgId
Zoho Books organization ID. Defaults to room-rentals (925004567).

.PARAMETER DryRun
Simulate the creation without making API calls.

.PARAMETER Help
Show this help message.

.EXAMPLE
# Create expenses (auto-fetches token)
.\Create-RoomRentalsExpenses.ps1

.EXAMPLE
# Pre-obtain token to avoid rate limit
$t = (Invoke-RestMethod ...).access_token
.\Create-RoomRentalsExpenses.ps1 -Token $t

.EXAMPLE
# Dry run
.\Create-RoomRentalsExpenses.ps1 -DryRun
#>
[CmdletBinding()]
param(
  [Parameter(HelpMessage = 'Pre-obtained OAuth access token')]
  [string]$Token,
  [Parameter(HelpMessage = 'Zoho Books refresh token')]
  [string]$RefreshToken,
  [Parameter(HelpMessage = 'Zoho Books client ID')]
  [string]$ClientId,
  [Parameter(HelpMessage = 'Zoho Books client secret')]
  [string]$ClientSecret,
  [Parameter(HelpMessage = 'Zoho Books organization ID')]
  [int]$OrgId = 925004567,
  [Parameter(HelpMessage = 'Simulate without making API calls')]
  [switch]$DryRun,
  [Parameter(HelpMessage = 'Show this help')]
  [switch]$Help
)

if ($Help) { Get-Help $MyInvocation.MyCommand.Path; return }

# Resolve Zoho credentials from env vars or AWS SM
$secretMissing = $false
if (-not $RefreshToken) { $RefreshToken = $env:ZOHO_ROOMRENTALS_REFRESH_TOKEN }
if (-not $ClientId) { $ClientId = $env:ZOHO_ROOMRENTALS_CLIENT_ID }
if (-not $ClientSecret) { $ClientSecret = $env:ZOHO_ROOMRENTALS_CLIENT_SECRET }

if (-not $RefreshToken -or -not $ClientId -or -not $ClientSecret) {
  try {
    $smJson = aws secretsmanager get-secret-value --secret-id Interclaw/FRAD/Provisioning --profile salmon-orch --region ca-central-1 --query SecretString --output text 2>$null
    if ($smJson) {
      $smSecret = $smJson | ConvertFrom-Json
      if (-not $RefreshToken) { $RefreshToken = $smSecret.ZOHO_BOOKS_REFRESH }
      if (-not $ClientId) { $ClientId = $smSecret.ZOHO_BOOKS_ID }
      if (-not $ClientSecret) { $ClientSecret = $smSecret.ZOHO_BOOKS_SECRET }
    }
  } catch {
    Write-Warning "AWS SM credential fetch failed: $_"
  }
}

if (-not $RefreshToken -or -not $ClientId -or -not $ClientSecret) {
  Write-Error "Zoho credentials not provided. Pass -RefreshToken, -ClientId, -ClientSecret params, set env vars, or ensure AWS SM access."
  return
}

if (-not $Token) {
  Write-Host "Getting fresh OAuth token..."
  $body = @{ refresh_token = $RefreshToken; client_id = $ClientId; client_secret = $ClientSecret; grant_type = 'refresh_token' }
  $result = Invoke-RestMethod -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $body
  $script:Token = $result.access_token
  Write-Host "Token obtained (first 30 chars: $($script:Token.Substring(0,30))...)`n"
} else {
  $script:Token = $Token
}

function Invoke-Zoho {
  param([string]$Method, [string]$Path, $Body)
  $uri = "https://www.zohoapis.com/books/v3/$Path`?organization_id=$OrgId"
  $headers = @{ Authorization = "Zoho-oauthtoken $script:Token"; 'Content-Type' = 'application/json' }
  try {
    if ($Body) {
      $bodyJson = $Body | ConvertTo-Json -Depth 3 -Compress
      return Invoke-RestMethod -Uri $uri -Method $Method -Body $bodyJson -Headers $headers
    } else {
      return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
    }
  } catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    try {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      Write-Host "Response: $($reader.ReadToEnd())" -ForegroundColor Red
    } catch {}
    return $null
  }
}

function Invoke-ZohoAttachReceipt {
  param([string]$ExpenseId, [string]$FilePath)
  $token = $script:Token
  $uri = "https://www.zohoapis.com/books/v3/expenses/$ExpenseId/receipt?organization_id=$OrgId"
  $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
  $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString("N")
  $fileName = [System.IO.Path]::GetFileName($FilePath)
  $headerBytes = [System.Text.Encoding]::UTF8.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"receipt`"; filename=`"$fileName`"`r`nContent-Type: application/octet-stream`r`n`r`n")
  $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
  $bodyStream = New-Object System.IO.MemoryStream
  $bodyStream.Write($headerBytes, 0, $headerBytes.Length)
  $bodyStream.Write($fileBytes, 0, $fileBytes.Length)
  $bodyStream.Write($footerBytes, 0, $footerBytes.Length)
  $bodyBytes = $bodyStream.ToArray()
  $bodyStream.Dispose()
  try {
    $result = Invoke-RestMethod -Uri $uri -Method POST -Body $bodyBytes -ContentType "multipart/form-data; boundary=$boundary" -Headers @{Authorization = "Zoho-oauthtoken $token"}
    return $result
  } catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    try {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      Write-Host "  Response: $($reader.ReadToEnd())" -ForegroundColor Red
    } catch {}
    return $null
  }
}

$ReceiptsRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\2026 Receipts"

$accountMap = @{
  'RBC-6679' = @{ account_id = '151803000000000427'; paid_through = '151803000000101251' }
  'TD'       = @{ account_id = '151803000000000424'; paid_through = '151803000000101006' }
}

$expensesToCreate = @(
  @{ date = '2026-03-03'; amount = 1.10; vendor = 'Home Depot'; description = 'The Home Depot'; account_id = '151803000000000457'; paid_through = '151803000000101251'; category = 'Repairs and Maintenance'; receipt = "2026-03-03 - 1.10 - The Home Depot.jpg" }
  @{ date = '2026-03-05'; amount = 12.59; vendor = 'Home Depot'; description = 'The Home Depot Silicone Purchase'; account_id = '151803000000000457'; paid_through = '151803000000101006'; category = 'Repairs and Maintenance'; receipt = "2026-03-05_-_12.59_-_The_Home_Depot_Silicone_Purchase.jpg" }
  @{ date = '2026-03-05'; amount = 156.58; vendor = 'Kal Tire'; description = 'Kal Tire'; account_id = '151803000000000424'; paid_through = '151803000000101006'; category = 'Automobile Expense'; receipt = "2026-03-05 - 156.58 - INVOICE.PDF" }
  @{ date = '2026-03-26'; amount = 204.75; vendor = 'Reinvest Wealth'; description = 'ReInvestWealth'; account_id = '151803000000178022'; paid_through = '151803000000101006'; category = 'Professional Fees'; receipt = "2026-03-26 - 204.75 - ReInvestWealth.pdf" }
  @{ date = '2026-04-15'; amount = 7.16; vendor = 'Anomaly'; description = 'Anomaly AI Service Apr 15'; account_id = '151803000000000427'; paid_through = '151803000000101251'; category = 'Software and IT Expenses'; receipt = "2026-04-15 - 7.16 - Anomaly AI Service Apr 15.pdf" }
  @{ date = '2026-04-30'; amount = 315.00; vendor = 'Reinvest Wealth'; description = 'Reinvest Wealth'; account_id = '151803000000178022'; paid_through = '151803000000101006'; category = 'Professional Fees'; receipt = "2026-04-30 - 315.00 - Receipt.pdf" }
)

Write-Host "=== Room Rentals Expense Creation ==="
Write-Host "Mode: $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })"
$logPath = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals\zoho-expense-creation-log.csv"

Write-Host "Existing log entries:" -ForegroundColor Yellow
if (Test-Path $logPath) { Get-Content $logPath }

$results = @()
foreach ($exp in $expensesToCreate) {
  Write-Host "`n--- $($exp.date) `$$($exp.amount) $($exp.vendor) ---" -ForegroundColor Cyan

  $receiptDir = if ($exp.paid_through -eq '151803000000101251') { 'RBC-6679' } else { 'TD' }
  $receiptPath = Join-Path (Join-Path $ReceiptsRoot $receiptDir) $exp.receipt

  if (Test-Path $receiptPath) {
    Write-Host "  Receipt found: $receiptPath"
  } else {
    Write-Host "  WARNING: Receipt not found at $receiptPath" -ForegroundColor Yellow
  }

  if ($DryRun) {
    Write-Host "  [DRY-RUN] Would create expense"
    continue
  }

  $expenseBody = @{
    account_id = $exp.account_id
    amount = $exp.amount
    date = $exp.date
    paid_through_account_id = $exp.paid_through
    description = $exp.description
  }

  Write-Host "  Creating expense..."
  $result = Invoke-Zoho -Method POST -Path "expenses" -Body $expenseBody
  if ($result -and $result.code -eq 0) {
    $expenseId = $result.expense.expense_id
    Write-Host "  Created expense: $expenseId" -ForegroundColor Green
    Start-Sleep -Milliseconds 800

    if (Test-Path $receiptPath) {
      Write-Host "  Attaching receipt..."
      $attachResult = Invoke-ZohoAttachReceipt -ExpenseId $expenseId -FilePath $receiptPath
      if ($attachResult -and $attachResult.code -eq 0) {
        Write-Host "  Receipt attached!" -ForegroundColor Green
      } else {
        Write-Host "  Receipt attach FAILED" -ForegroundColor Red
      }
    }

    $results += [PSCustomObject]@{
      expense_id = $expenseId
      date = $exp.date
      amount = $exp.amount
      vendor = $exp.vendor
      category = $exp.category
      account_id = $exp.account_id
      receipt_file = $receiptPath
      status = "success"
      message = "Created + receipt attached"
    }
  } else {
    $errorMsg = if ($result) { "$($result.code): $($result.message)" } else { "No response" }
    Write-Host "  FAILED: $errorMsg" -ForegroundColor Red
    $results += [PSCustomObject]@{
      expense_id = "error"
      date = $exp.date
      amount = $exp.amount
      vendor = $exp.vendor
      category = $exp.category
      account_id = $exp.account_id
      receipt_file = $receiptPath
      status = "failed"
      message = $errorMsg
    }
  }

  Start-Sleep -Milliseconds 1200
}

$results | Export-Csv -Path $logPath -NoTypeInformation -Encoding utf8

Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
$successCount = ($results | Where-Object { $_.status -eq 'success' }).Count
$failCount = ($results | Where-Object { $_.status -eq 'failed' }).Count
Write-Host "Created: $successCount, Failed: $failCount"
Write-Host "Log saved: $logPath"
