#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# =============================================================================
# Nightly-ReceiptPipeline end-to-end smoke tests
# =============================================================================

Describe "Nightly-ReceiptPipeline" -Tag "ReconcileAccount", "PowerShell", "Orchestration" {
    BeforeAll {
        $script:pipelinePath = Join-Path $PSScriptRoot "..\..\..\Plugins\reconcile-account\tools\Nightly-ReceiptPipeline.ps1"
        $script:tempBin = Join-Path ([System.IO.Path]::GetTempPath()) "receipt-pipeline-bin-$([Guid]::NewGuid().ToString())"
        $script:receiptsBase = Join-Path ([System.IO.Path]::GetTempPath()) "receipt-pipeline-data-$([Guid]::NewGuid().ToString())"
        $null = New-Item -ItemType Directory -Path $script:tempBin -Force

        $pythonStub = @'
param()
$downloadDir = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--download-dir') { $downloadDir = $args[$i + 1] }
}
$count = if ($env:RECEIPTS_STUB_DOWNLOADED -eq '0') { 0 } else { 1 }
if ($downloadDir -and $count -gt 0) {
    $null = New-Item -ItemType Directory -Path $downloadDir -Force
    $null = New-Item -ItemType File -Path (Join-Path $downloadDir 'receipt.pdf') -Force
}
@{ found = 1; downloaded = $count } | ConvertTo-Json -Compress
'@
        $pythonStub | Set-Content (Join-Path $script:tempBin 'python.ps1') -Encoding utf8

        $nodeStub = @'
param()
$entity = $args[-1]
@{ sidecars = 1; manifests = @("$entity/ingest/manifest.csv") } | ConvertTo-Json -Compress
'@
        $nodeStub | Set-Content (Join-Path $script:tempBin 'node.ps1') -Encoding utf8

        $env:PATH = "$($script:tempBin);$($env:PATH)"
    }

    AfterAll {
        if (Test-Path $script:tempBin) { Remove-Item $script:tempBin -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $script:receiptsBase) { Remove-Item $script:receiptsBase -Recurse -Force -ErrorAction SilentlyContinue }
        $env:RECEIPTS_STUB_DOWNLOADED = $null
    }

    It "runs all mailboxes and returns a JSON summary" {
        $env:RECEIPTS_STUB_DOWNLOADED = '1'
        $json = & $script:pipelinePath -Mailbox 'all' -ReceiptsBase $script:receiptsBase
        $result = $json | ConvertFrom-Json
        $result.summary.mailboxes | Should -Be 2
        $result.summary.found | Should -Be 2
        $result.summary.downloaded | Should -Be 2
        $result.summary.sidecars | Should -Be 2
        $result.mailboxes[0].entity | Should -Be 'intersite-consulting'
        $result.mailboxes[1].entity | Should -Be 'room-rentals'
    }

    It "supports -Mailbox intersite only" {
        $env:RECEIPTS_STUB_DOWNLOADED = '1'
        $json = & $script:pipelinePath -Mailbox 'intersite' -ReceiptsBase $script:receiptsBase
        $result = $json | ConvertFrom-Json
        $result.summary.mailboxes | Should -Be 1
        $result.mailboxes[0].entity | Should -Be 'intersite-consulting'
    }

    It "skips sidecar generation when no attachments were downloaded" {
        $env:RECEIPTS_STUB_DOWNLOADED = '0'
        $json = & $script:pipelinePath -Mailbox 'room-rentals' -ReceiptsBase $script:receiptsBase
        $result = $json | ConvertFrom-Json
        $result.summary.mailboxes | Should -Be 1
        $result.summary.downloaded | Should -Be 0
        $result.summary.sidecars | Should -Be 0
        $result.mailboxes[0].sidecars | Should -Be 0
        $result.mailboxes[0].manifests | Should -Be @()
    }
}
