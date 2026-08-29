function Write-PondFeedbackSidecar {
    [CmdletBinding()]
    param([string]$PlanPath,[string]$Gate,[string]$TaskRoot,[string]$Reason)
    $content=Get-Content $PlanPath -Raw; $planId=Get-PondPlanHeader $content 'PlanId'; $attemptId=Get-PondPlanHeader $content 'AttemptId'
    if(-not $planId -or -not $attemptId){$identity=Initialize-PondGateAttempt $PlanPath $Gate $TaskRoot; $planId=$identity.PlanId; $attemptId=$identity.AttemptId}
    $relative="Results/$planId/$Gate/$attemptId.feedback.json"; $path=Join-Path (Split-Path $TaskRoot -Parent) $relative
    $null=New-Item (Split-Path $path) -ItemType Directory -Force
    $feedback=[ordered]@{planId=$planId;gate=$Gate;attemptId=$attemptId;createdAt=[datetimeoffset]::UtcNow.ToString('o');reason=$Reason;fixActions=@($Reason);status='open'}
    $tmp="$path.tmp-$PID";$feedback|ConvertTo-Json -Depth 5|Set-Content $tmp -Encoding utf8 -NoNewline;Move-Item $tmp $path -Force
    Set-PondPlanHeader $PlanPath 'Feedback' $relative; Set-PondPlanHeader $PlanPath 'Blocked' 'false'; Set-PondPlanHeader $PlanPath 'BlockedBy' $Gate; Set-PondPlanHeader $PlanPath 'BlockedReason' $Reason
    return Get-Item $path
}