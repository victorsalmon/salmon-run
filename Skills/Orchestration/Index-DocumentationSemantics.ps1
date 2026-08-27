<#
.SYNOPSIS
    Hash-gated semantic index over the Skills/ and docs/ knowledge corpus,
    embedding via AWS Bedrock (Titan Embed v2 only) in-region ca-central-1 —
    the sovereign path (currentsbk.ca roadmap §21; no CRIS, no AQE).
.DESCRIPTION
    Builds (or refreshes) a vector index over the repository's knowledge
    documents so agents can do retrieval (RAG) over procedures, references,
    and the skills registry — instead of reading whole files blind.

    Embedding backend: AWS Bedrock InvokeModel, NOT the AQE MCP bridge.
    Earlier versions of this script pointed at mcp_aqe:21004/qe_embeddings_generate;
    that was wrong. AQE's embeddings are 384-dim all-MiniLM-L6-v2 with a broken
    store/search (HNSW index never rebuilt — see docs/Reference/AQE-Agent-Guide.md).
    The sovereign decision (currentsbk.ca/roadmap.md §19, §21) is Titan Embed
    v2 (1024-dim) in-region ca-central-1 with no CRIS. This script implements
    that path.

    Diff-gating: the schedule fires daily; this script decides whether to call
    the embedding API at all. Each cache record carries a sha256 of its source
    chunk. On a no-change day the script makes ZERO embedding calls and exits 0.
    On a change day it re-embeds only the new/changed chunks, preserving all
    unchanged records.

    Chunking: per ## section. Each .md is split on level-2 headings; each chunk
    is keyed as <relativePath>#<anchor>. A one-line edit to one section costs
    one re-embed, not a whole-file re-embed.

    Telemetry: appends STREAMING jsonl events as it goes (start, per-chunk
    embed/skip/fail, end) to Tasks/Logs/embed-runs.jsonl — so a crash or partial
    failure is diagnosable from the tail of the log, not just a final summary.
    Field names align with the existing audit jsonl convention (ts, action,
    detail, severity, stage_duration_ms).

.PARAMETER TargetDir
    One or more directories (relative to RepoRoot) to index. Default:
    @('Skills','docs') — the human-authored knowledge corpus. Tasks/ is NEVER
    a target (runtime output; excluded from RAG by construction).
.PARAMETER Query
    Optional search query. If provided, the script loads the cache and returns
    top-3 matching chunks by cosine similarity instead of indexing.
.PARAMETER CachePath
    Path to the embedding cache. Default: Tasks/Logs/doc-embeddings.json
    (Get-ReportsDir resolves to Tasks/Logs/ on host). The cache is gitignored
    alongside the rest of Tasks/Logs/.
.PARAMETER Profile
    AWS profile for Bedrock InvokeModel. Default: dev-daily-fixed. Requires
    bedrock:InvokeModel on amazon.titan-embed-text-v2:0 — see C:\Repos\AGENTS.md
    § Profile selection.
.PARAMETER Provider
    Embedding provider override. Default and only supported value: 'titan'.
.PARAMETER Region
    AWS region. Default: ca-central-1 (sovereign — never change without
    revisiting roadmap §19/§21).
.PARAMETER Force
    Re-embed every chunk regardless of hash (ignore the cache). Use only for
    a full rebuild, e.g. after changing provider/dimensions.
.EXAMPLE
    .\Skills\\Orchestration\Index-DocumentationSemantics.ps1
    Index/refresh Skills/ and docs/. On a no-change day: zero API calls.
.EXAMPLE
    .\Skills\\Orchestration\Index-DocumentationSemantics.ps1 -Query "how do I do a safe commit"
    Search the existing cache for the query; returns top-3 chunks.
.EXAMPLE
    .\Skills\\Orchestration\Index-DocumentationSemantics.ps1 -Force
    Full rebuild — re-embed every chunk, ignoring cached hashes.
.NOTES
    Idempotent. Safe to run concurrently with read-only consumers; NOT safe to
    run two indexers at once (the cache write is last-writer-wins). The
    scheduler runs it once daily off-peak, so contention is not expected.
#>
param(
    [string[]]$TargetDir = @('Skills','docs'),
    [string]$Query,
    [string]$CachePath,
    [string]$Profile = "dev-daily-fixed",
    [ValidateSet('titan')][string]$Provider = "titan",
    [string]$Region = "ca-central-1",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
# RepoRoot = two levels up from Skills/Orchestration/<this script>
$RepoRoot    = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
$BridgeUrl   = $null  # legacy AQE field, intentionally null — we use Bedrock now
$TelemetryPath = Join-Path $RepoRoot "Tasks/Logs/embed-runs.jsonl"
if (-not $CachePath) {
    $CachePath = Join-Path $RepoRoot "Tasks/Logs/doc-embeddings.json"
}

Import-Module AWS.Tools.BedrockRuntime -ErrorAction Stop

# Provider config — model ID and body/response shape per currentsbk.ca's
# reference implementation (backend/src/lib/embedding.ts). Titan produces
# 1024-dim vectors, matching the §21 sovereign decision.
$ProviderConfig = @{
    titan = @{
        ModelId  = "amazon.titan-embed-text-v2:0"
        MakeBody = { param($text) @{ inputText = $text; dimensions = 1024; normalize = $true } }
        ParseVec = { param($parsed)
            if (Get-Member -InputObject $parsed -Name embedding) { return $parsed.embedding }
            return $null
        }
    }
}

# Shared Bedrock SDK client for the run. Reusing one client avoids the
# per-call aws CLI startup overhead that was dominating wall time.
$BedrockCreds = Get-AWSCredential -ProfileName $Profile
$BedrockClient = New-Object Amazon.BedrockRuntime.AmazonBedrockRuntimeClient -ArgumentList $BedrockCreds, ([Amazon.RegionEndpoint]::GetBySystemName($Region))

# ---------- Streaming telemetry (append-as-it-goes) ----------
$RunId = [Guid]::NewGuid().ToString('N').Substring(0,8)
function Write-EmbedEvent {
    param([string]$Action, [string]$Detail, [ValidateSet('info','warn','error')][string]$Severity = 'info', [int]$DurationMs = 0, [string]$Stage = '')
    $evt = [PSCustomObject]@{
        ts                = (Get-Date -Format "o")
        runId             = $RunId
        action            = $Action
        detail            = $Detail
        severity          = $Severity
        stage             = $Stage
        stage_duration_ms = $DurationMs
    }
    # Append one line per event — survive crashes; tail is diagnosable.
    try {
        $dir = Split-Path $TelemetryPath -Parent
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        ($evt | ConvertTo-Json -Compress) | Add-Content -Path $TelemetryPath -Encoding UTF8
    } catch {
        # Never let telemetry failure abort the actual work.
        Write-Warning "[embed] telemetry write failed: $_"
    }
    # Mirror to host for interactive runs.
    $color = switch ($Severity) { 'info' { 'Gray' }; 'warn' { 'Yellow' }; 'error' { 'Red' } }
    $durTag = if ($DurationMs -gt 0) { " (${DurationMs}ms)" } else { "" }
    Write-Host "  [$Severity] $Action$durTag — $Detail" -ForegroundColor $color
}

function Get-CosineSimilarity {
    param([array]$VecA, [array]$VecB)
    if (-not $VecA -or -not $VecB) { return 0.0 }
    $Dot = 0.0; $MagA = 0.0; $MagB = 0.0
    $Count = [Math]::Min($VecA.Count, $VecB.Count)
    for ($i = 0; $i -lt $Count; $i++) {
        $Dot  += $VecA[$i] * $VecB[$i]
        $MagA += $VecA[$i] * $VecA[$i]
        $MagB += $VecB[$i] * $VecB[$i]
    }
    $MagA = [Math]::Sqrt($MagA); $MagB = [Math]::Sqrt($MagB)
    if ($MagA -eq 0 -or $MagB -eq 0) { return 0.0 }
    return $Dot / ($MagA * $MagB)
}

function Get-Sha256 {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-','').ToLower() }
        finally { $hasher.Dispose() }
    } catch { return $null }
}

# Bedrock InvokeModel via the AWS SDK for .NET. Returns the parsed JSON
# response, or throws on non-retryable failure.
function Invoke-BedrockEmbed {
    param([string]$Text, [string]$ProviderName)
    $cfg = $ProviderConfig[$ProviderName]

    # Titan Embed v2 has an 8192-token input limit. The chunking stage splits
    # long sections; this is a final safety trim for any single-line edge case.
    $MaxTextLength = 24000
    if ($Text.Length -gt $MaxTextLength) {
        Write-EmbedEvent 'embed-truncate' "truncating input from $($Text.Length) to $MaxTextLength characters for $ProviderName" 'warn' 0 $ProviderName
        $Text = $Text.Substring(0, $MaxTextLength)
    }

    $body = (& $cfg.MakeBody $Text) | ConvertTo-Json -Compress -Depth 5
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    # 3 attempts with exponential backoff: 1s, 2s, 4s. Retry on any failure
    # (network, throttling, transient 5xx). Non-retryable errors (auth,
    # validation) will fail all 3 fast and surface clearly.
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $req = New-Object Amazon.BedrockRuntime.Model.InvokeModelRequest -Property @{
                ModelId     = $cfg.ModelId
                ContentType = 'application/json'
                Accept      = 'application/json'
                Body        = New-Object System.IO.MemoryStream -ArgumentList (,$bodyBytes)
            }
            $resp = $BedrockClient.InvokeModelAsync($req).GetAwaiter().GetResult()
            $out = New-Object System.IO.MemoryStream
            $resp.Body.CopyTo($out)
            $parsed = [System.Text.Encoding]::UTF8.GetString($out.ToArray()) | ConvertFrom-Json
            $vec = & $cfg.ParseVec $parsed
            if (-not $vec -or $vec -isnot [System.Array]) { throw "could not parse embedding vector from response" }
            return @{ vector = $vec; model = $cfg.ModelId }
        } catch {
            if ($attempt -lt $maxAttempts) {
                $backoff = [Math]::Pow(2, $attempt - 1)  # 1, 2, 4
                Write-EmbedEvent 'embed-retry' "attempt $attempt/$maxAttempts failed ($ProviderName): $_ — retrying in ${backoff}s" 'warn' 0 $ProviderName
                Start-Sleep -Seconds $backoff
            } else {
                throw $_
            }
        }
    }
}

# Embed with the configured Titan provider only. No fallback, since Cohere
# has been discontinued as an embedding option.
function Invoke-EmbedWithFallback {
    param([string]$Text)
    try {
        $result = Invoke-BedrockEmbed -Text $Text -ProviderName $Provider
        $result.provider = $Provider
        return $result
    } catch {
        Write-EmbedEvent 'embed-provider-failed' "$Provider failed all retries: $_" 'error' 0 $Provider
    }
    return $null
}

# ---------- QUERY MODE ----------
if ($Query) {
    if (-not (Test-Path $CachePath)) {
        Write-Host "[ERROR] Cache not found at $CachePath. Run without -Query to index first." -ForegroundColor Red
        exit 1
    }
    Write-EmbedEvent 'query-start' "query='$Query' against $CachePath" 'info'
    $qStart = [System.Diagnostics.Stopwatch]::StartNew()

    $qResult = Invoke-EmbedWithFallback -Text $Query
    if (-not $qResult) { Write-Host "[ERROR] Could not embed query." -ForegroundColor Red; exit 1 }
    $QueryVec = $qResult.vector

    $Cache = Get-Content -Path $CachePath -Raw | ConvertFrom-Json
    $Results = @()
    foreach ($Key in ($Cache.PSObject.Properties.Name)) {
        $Doc = $Cache.$Key
        if (-not $Doc.embedding -or $Doc.embedding -isnot [System.Array]) { continue }
        $Results += [PSCustomObject]@{
            Key        = $Key
            Title      = $Doc.title
            Similarity = (Get-CosineSimilarity -VecA $QueryVec -VecB $Doc.embedding)
        }
    }
    # Dedupe by parent file so one doc doesn't fill all 3 slots.
    $Top = $Results | Sort-Object Similarity -Descending | Group-Object { ($_.Key -split '#')[0] } |
        ForEach-Object { $_.Group | Select-Object -First 1 } | Select-Object -First 3

    $qStart.Stop()
    Write-Host "`n  Top 3 for '$Query':" -ForegroundColor Cyan
    foreach ($R in $Top) {
        $Pct = "{0:P1}" -f $R.Similarity
        Write-Host "  [$Pct] $($R.Key)" -ForegroundColor Green
        Write-Host "         $($R.Title)" -ForegroundColor Gray
    }
    Write-EmbedEvent 'query-complete' "returned $($Top.Count) results" 'info' ([int]$qStart.ElapsedMilliseconds)
    return $Top
}

# ---------- INDEX MODE ----------
$idxStart = [System.Diagnostics.Stopwatch]::StartNew()
Write-EmbedEvent 'index-start' "targets=$($TargetDir -join ',') provider=$Provider region=$Region force=$([bool]$Force)" 'info'

# 1. Load existing cache (or start fresh).
$Cache = @{}
if ((-not $Force) -and (Test-Path $CachePath)) {
    try {
        $raw = Get-Content -Path $CachePath -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $Cache[$prop.Name] = $prop.Value
        }
        Write-EmbedEvent 'cache-loaded' "$($Cache.Count) existing records" 'info'
    } catch {
        Write-EmbedEvent 'cache-load-failed' "could not parse $CachePath — starting fresh: $_" 'warn'
    }
}

# 2. Enumerate + chunk candidate files.
$allChunks = @{}   # key -> {path, anchor, title, text, sha256}
foreach ($dir in $TargetDir) {
    $absDir = Join-Path $RepoRoot $dir
    if (-not (Test-Path $absDir)) {
        Write-EmbedEvent 'target-missing' "$dir not found — skipping" 'warn'
        continue
    }
    $files = Get-ChildItem -Path $absDir -Filter "*.md" -File -Recurse
    foreach ($file in $files) {
        $relPath = $file.FullName.Substring($RepoRoot.Length + 1).Replace('\','/')
        $sha = Get-Sha256 -Path $file.FullName
        if (-not $sha) { Write-EmbedEvent 'file-skip' "could not hash $relPath" 'warn'; continue }

        $content = Get-Content -Path $file.FullName -Raw
        # Split on ## headings. Content before the first ## becomes the 'intro' chunk.
        $sections = [System.Collections.ArrayList]@()
        $lines = $content -split "`r?`n"
        $curAnchor = "intro"
        $curTitle = if ($content -match '^#\s+(.+)$') { $Matches[1] } else { $file.BaseName }
        $curBody = [System.Collections.ArrayList]@()
        foreach ($line in $lines) {
            if ($line -match '^##\s+(.+)$') {
                if ($curBody.Count -gt 0) {
                    $null = $sections.Add([PSCustomObject]@{ anchor = $curAnchor; title = $curTitle; body = ($curBody -join "`n").Trim() })
                }
                $headingText = $Matches[1]
                $curAnchor = ($headingText -replace '[^a-z0-9\- ]','' -replace '\s+','-').ToLower()
                $curTitle = "$curTitle — $headingText"
                $curBody = [System.Collections.ArrayList]@()
            } else {
                $null = $curBody.Add($line)
            }
        }
        if ($curBody.Count -gt 0) {
            $null = $sections.Add([PSCustomObject]@{ anchor = $curAnchor; title = $curTitle; body = ($curBody -join "`n").Trim() })
        }

        # The file sha covers the whole file; a section change mutates it. For
        # finer gating we hash each section body, but for cache-key stability we
        # key on path#anchor and gate on the section sha (stored per record).
        # Sections longer than the model's input limit are split into numbered
        # parts; the first part keeps the original anchor, subsequent parts use
        # <anchor>-<n>.
        $MaxSectionChars = 24000
        foreach ($sec in $sections) {
            if ([string]::IsNullOrWhiteSpace($sec.body)) { continue }

            $subSections = [System.Collections.ArrayList]@()
            $fullText = $sec.title + "`n" + $sec.body
            if ($fullText.Length -le $MaxSectionChars) {
                $null = $subSections.Add([PSCustomObject]@{ anchor = $sec.anchor; title = $sec.title; body = $sec.body })
            } else {
                $bodyLines = $sec.body -split "`r?`n"
                $titleBudget = $MaxSectionChars - $sec.title.Length - 1
                $curLines = [System.Collections.ArrayList]@()
                $curLen = 0
                $part = 1
                foreach ($line in $bodyLines) {
                    $lineLen = $line.Length + 1
                    if (($curLen + $lineLen) -gt $titleBudget -and $curLines.Count -gt 0) {
                        $partAnchor = if ($part -eq 1) { $sec.anchor } else { "$($sec.anchor)-$part" }
                        $partTitle = if ($part -eq 1) { $sec.title } else { "$($sec.title) (part $part)" }
                        $null = $subSections.Add([PSCustomObject]@{ anchor = $partAnchor; title = $partTitle; body = ($curLines -join "`n").Trim() })
                        $curLines = [System.Collections.ArrayList]@()
                        $curLen = 0
                        $part++
                    }
                    $null = $curLines.Add($line)
                    $curLen += $lineLen
                }
                if ($curLines.Count -gt 0) {
                    $partAnchor = if ($part -eq 1) { $sec.anchor } else { "$($sec.anchor)-$part" }
                    $partTitle = if ($part -eq 1) { $sec.title } else { "$($sec.title) (part $part)" }
                    $null = $subSections.Add([PSCustomObject]@{ anchor = $partAnchor; title = $partTitle; body = ($curLines -join "`n").Trim() })
                }
            }

            foreach ($sub in $subSections) {
                if ([string]::IsNullOrWhiteSpace($sub.body)) { continue }
                $chunkKey = "$relPath#$($sub.anchor)"
                # Hash only the body to preserve cache stability when the title is unchanged.
                $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($sub.body)
                $h = [System.Security.Cryptography.SHA256]::Create()
                try { $secSha = ([System.BitConverter]::ToString($h.ComputeHash($bodyBytes)) -replace '-','').ToLower() }
                finally { $h.Dispose() }

                $allChunks[$chunkKey] = [PSCustomObject]@{
                    path = $relPath; anchor = $sub.anchor; title = $sub.title
                    text = $sub.title + "`n" + $sub.body; sha256 = $secSha
                }
            }
        }
    }
}
Write-EmbedEvent 'chunks-discovered' "$($allChunks.Count) chunks across $($TargetDir -join ',')" 'info'

# 3. Classify: unchanged / changed / new / deleted.
$unchanged = @(); $changed = @(); $new = @(); $deleted = @()
foreach ($key in $allChunks.Keys) {
    if ($Cache.ContainsKey($key)) {
        if ($Cache[$key].sha256 -eq $allChunks[$key].sha256) { $unchanged += $key }
        else { $changed += $key }
    } else { $new += $key }
}
foreach ($key in @($Cache.Keys)) {
    if (-not $allChunks.ContainsKey($key)) { $deleted += $key }
}
$work = @($changed) + @($new)
Write-EmbedEvent 'diff-classified' "unchanged=$($unchanged.Count) changed=$($changed.Count) new=$($new.Count) deleted=$($deleted.Count) work=$($work.Count)" 'info'

# 4. Early exit — no-change day.
if ($work.Count -eq 0 -and $deleted.Count -eq 0) {
    $idxStart.Stop()
    Write-EmbedEvent 'index-noop' "no changes — zero embedding calls" 'info' ([int]$idxStart.ElapsedMilliseconds)
    Write-Host "[OK] No changes since last run. Zero embedding calls. Cache unchanged ($($Cache.Count) records)." -ForegroundColor Green
    exit 0
}

# 5. Embed the work set (changed + new).
$embedCalls = 0; $embedFails = 0
foreach ($key in $work) {
    $chunk = $allChunks[$key]
    $eStart = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-EmbedWithFallback -Text $chunk.text
    $eStart.Stop()
    $embedCalls++
    if ($result) {
        $Cache[$key] = [PSCustomObject]@{
            title = $chunk.title; path = $chunk.path; anchor = $chunk.anchor
            sha256 = $chunk.sha256; embedding = $result.vector
            model = $result.model; provider = $result.provider
            size = $chunk.text.Length; ts = (Get-Date -Format "o")
        }
        Write-EmbedEvent 'chunk-embedded' "$key via $($result.provider)" 'info' ([int]$eStart.ElapsedMilliseconds) 'embed'
    } else {
        $embedFails++
        # Stale-and-present beats absent: keep the prior record if one exists.
        if ($Cache.ContainsKey($key)) {
            Write-EmbedEvent 'chunk-keep-stale' "$key embed failed — preserving prior embedding" 'warn' ([int]$eStart.ElapsedMilliseconds) 'embed'
        } else {
            Write-EmbedEvent 'chunk-abandoned' "$key embed failed — no prior embedding, will retry next run" 'error' ([int]$eStart.ElapsedMilliseconds) 'embed'
        }
    }
}

# 6. Drop deleted.
foreach ($key in $deleted) { $Cache.Remove($key) }
if ($deleted.Count -gt 0) { Write-EmbedEvent 'chunks-deleted' "removed $($deleted.Count) stale records" 'info' }

# 7. Write cache once.
$cacheDir = Split-Path $CachePath -Parent
if (-not (Test-Path $cacheDir)) { $null = New-Item -ItemType Directory -Path $cacheDir -Force }
$Cache | ConvertTo-Json -Depth 11 -Compress | Set-Content -Path $CachePath -Encoding UTF8

$idxStart.Stop()
Write-EmbedEvent 'index-complete' "cache=$($Cache.Count) records embedCalls=$embedCalls fails=$embedFails" 'info' ([int]$idxStart.ElapsedMilliseconds)
Write-Host "[OK] Index refreshed. $($Cache.Count) records. $embedCalls embed calls, $embedFails failed." -ForegroundColor Green
