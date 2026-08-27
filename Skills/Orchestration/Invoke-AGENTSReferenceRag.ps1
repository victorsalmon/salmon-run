<#
.SYNOPSIS
  Query the AGENTS reference doc via RAG (Bedrock Titan embeddings).

.DESCRIPTION
  Thin wrapper around Index-DocumentationSemantics.ps1 that agents call to
  retrieve sections from docs/Reference/AGENTS-reference.md (the reference
  content moved out of AGENTS.md to keep the always-on context window small).

  If the embedding cache doesn't exist yet, runs a full index first (one-time
  cost ~30s + Bedrock API calls). On subsequent calls, the cache is loaded
  directly — queries return in <1s with zero API calls.

  The index covers all of Skills/ and docs/ (not just AGENTS-reference.md),
  so this wrapper also finds procedures, skill docs, and architecture docs.

.PARAMETER Query
  Natural-language question. Returns top-3 matching chunks with their source
  file path, heading, and cosine similarity score.

.PARAMETER TopN
  Number of results to return. Default: 3.

.PARAMETER NoAutoIndex
  Skip the automatic first-run index. If the cache doesn't exist, returns an
  error message telling the agent to run the index manually.

.EXAMPLE
  & (Resolve-Path "Skills/Orchestration/Invoke-AGENTSReferenceRag.ps1") -Query "how do I rotate bundle secrets"
  Returns top-3 chunks matching the query.

.EXAMPLE
  & (Resolve-Path "Skills/Orchestration/Invoke-AGENTSReferenceRag.ps1") -Query "what scripts are available for deployment" -TopN 5
  Returns top-5 chunks.

.NOTES
  The embedding cache lives at Tasks/Logs/doc-embeddings.json (gitignored).
  It's refreshed daily by the scheduled Index-DocumentationSemantics.ps1 run.
  If you get stale results, run a full rebuild:
    & (Resolve-Path "Skills/Orchestration/Index-DocumentationSemantics.ps1") -Force
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Query,

    [int]$TopN = 3,

    [switch]$NoAutoIndex
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
$CachePath = Join-Path $RepoRoot "Tasks/Logs/doc-embeddings.json"
$Indexer = Join-Path $PSScriptRoot "Index-DocumentationSemantics.ps1"

# Auto-index on first run if cache doesn't exist
if (-not (Test-Path $CachePath)) {
    if ($NoAutoIndex) {
        Write-Host "[AGENTS-RAG] No embedding cache found at $CachePath" -ForegroundColor Yellow
        Write-Host "[AGENTS-RAG] Run the indexer first:" -ForegroundColor Yellow
        Write-Host "  & (Resolve-Path 'Skills/Orchestration/Index-DocumentationSemantics.ps1')" -ForegroundColor Cyan
        Write-Host "[AGENTS-RAG] Or re-run without -NoAutoIndex to auto-index now." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[AGENTS-RAG] First run — building embedding index (one-time, ~30s)..." -ForegroundColor Cyan
    & $Indexer
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[AGENTS-RAG] Index build failed. Check Tasks/Logs/embed-runs.jsonl for details." -ForegroundColor Red
        exit 1
    }
}

# Query the index via the existing script's -Query parameter
# The script returns top-3 by default; we pass through and format
$results = & $Indexer -Query $Query 2>&1

if ($results) {
    Write-Host "`n[AGENTS-RAG] Query: `"$Query`"`n" -ForegroundColor Green
    Write-Host $results
    Write-Host "`n[AGENTS-RAG] To read the full section, grep for the heading in docs/Reference/AGENTS-reference.md" -ForegroundColor DarkGray
    Write-Host "[AGENTS-RAG] Or read the source file directly if a different doc was returned." -ForegroundColor DarkGray
} else {
    Write-Host "[AGENTS-RAG] No results found for query: `"$Query`"" -ForegroundColor Yellow
    Write-Host "[AGENTS-RAG] The index may be stale. Run a rebuild:" -ForegroundColor Yellow
    Write-Host "  & (Resolve-Path 'Skills/Orchestration/Index-DocumentationSemantics.ps1') -Force" -ForegroundColor Cyan
}
