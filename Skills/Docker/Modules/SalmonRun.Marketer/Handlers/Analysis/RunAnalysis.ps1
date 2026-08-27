# Analysis.RunAnalysis — capability gate for CRO/landing page analysis via OpenRouter.
# Required keys: OPENROUTER_API_KEY.
# Capabilities: analysis:run.

$script:OpenrouterBaseUrl = "https://openrouter.ai/api/v1"
$script:AnalysisDefaultModel = "openai/gpt-4o-mini"

function Invoke-AnalysisRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Prompt,
        [string]$Model = $script:AnalysisDefaultModel,
        [int]$MaxTokens = 2000
    )

    Test-MarketerCapability -RequiredCapability 'analysis:run'

    $systemPrompt = "You are a CRO and marketing analyst. Analyze the given landing page content and provide actionable recommendations."
    $userPrompt = if ($Prompt) { $Prompt } else { "Analyze this landing page URL for conversion optimization: $Url" }

    $body = @{
        model    = $Model
        messages = @(
            @{ role = "system"; content = $systemPrompt }
            @{ role = "user";   content = $userPrompt }
        )
        max_tokens = $MaxTokens
    } | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-ApiCall -Uri "${script:OpenrouterBaseUrl}/chat/completions" -Method POST `
            -Headers @{
                Authorization  = "Bearer $script:OpenrouterApiKey"
                "Content-Type" = "application/json"
            } `
            -Body $body -Domain "marketer" -Action "analysis:openrouter" -ReturnRaw

        $StatusCode = [int]$response.StatusCode
        if ($StatusCode -ge 400) {
            $detail = try { ($response.Content | ConvertFrom-Json).error.message } catch { $response.Content.Substring(0, [math]::Min(500, $response.Content.Length)) }
            return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $detail }
        }

        $parsed = $response.Content | ConvertFrom-Json
        Write-MarketerAuditEntry -Capability 'analysis:run' -Action "Invoke-AnalysisRun" -Context @{ Url = $Url; Model = $Model } -Result 'allow'

        return [pscustomobject]@{
            Success  = $true
            Url      = $Url
            Analysis = $parsed.choices[0].message.content
            Model    = $parsed.model
            Usage    = $parsed.usage
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Analysis API error - see marketer log for details" }
    }
}
