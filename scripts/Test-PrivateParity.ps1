#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$PublicRepo = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][string]$PrivateRepo,
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'public-to-private.manifest.json')
)

$ErrorActionPreference = 'Stop'
$publicRoot = [IO.Path]::GetFullPath($PublicRepo).TrimEnd('\','/')
$privateRoot = [IO.Path]::GetFullPath($PrivateRepo).TrimEnd('\','/')
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 20
$differences = [Collections.Generic.List[string]]::new()
foreach ($entry in @($manifest.entries)) {
    $source = Join-Path $publicRoot $entry.source
    $target = Join-Path $privateRoot $entry.target
    $sourceFiles = if (Test-Path -LiteralPath $source -PathType Leaf) { @(Get-Item -LiteralPath $source) } else { @(Get-ChildItem -LiteralPath $source -File -Recurse) }
    foreach ($file in $sourceFiles) {
        $relative = if ($sourceFiles.Count -eq 1 -and (Test-Path -LiteralPath $source -PathType Leaf)) { '' } else { $file.FullName.Substring($source.Length).TrimStart('\','/') }
        $consumer = if ($relative) { Join-Path $target $relative } else { $target }
        if (-not (Test-Path -LiteralPath $consumer -PathType Leaf)) { $differences.Add("missing: $consumer"); continue }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $consumer -Algorithm SHA256).Hash) {
            $differences.Add("drift: $consumer")
        }
    }
}
if ($differences.Count) {
    throw "Private consumer parity failed: $($differences -join '; ')"
}
Write-Output 'SALMON_PRIVATE_PARITY_PASS'
