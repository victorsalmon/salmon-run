$script:WebAuditLogPath = "/home/node/app/audit/audit.jsonl"
$script:TavilyUsage = @{ TotalCalls = 0; KeyExhausted = $false; LastExhaustedAt = $null; RemainingQuota = $null }
$script:FirecrawlUsage = @{ TotalCalls = 0; KeyExhausted = $false; LastExhaustedAt = $null; RemainingQuota = $null }
