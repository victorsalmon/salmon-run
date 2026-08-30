function Set-PondPlanHeader {
    param([string]$Path,[string]$Name,[string]$Value)
    $content=Get-Content $Path -Raw
    $pattern="(?im)^\*\*$([regex]::Escape($Name))\*\*:[ \t]*[^\r\n]+"
    if($content -match $pattern){$content=[regex]::Replace($content,$pattern,"**$Name**: $Value",1)}
    else{$content=$content.TrimEnd()+"`n`n**$Name**: $Value`n"}
    Set-Content $Path $content -Encoding utf8 -NoNewline
}
function Get-PondPlanHeader { param([string]$Content,[string]$Name); $m=[regex]::Match($Content,"(?im)^\*\*$([regex]::Escape($Name))\*\*:[ \t]*(?<v>[^\r\n]+)"); if($m.Success){return $m.Groups['v'].Value.Trim()}; return '' }
function Get-PondStablePlanId {
    param([string]$PlanPath)
    $content=Get-Content $PlanPath -Raw
    $id=Get-PondPlanHeader $content 'PlanId'; if($id){return $id}
    $base=[IO.Path]::GetFileNameWithoutExtension($PlanPath) -replace '-feedback\d*$',''
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($base.ToLowerInvariant()))).Substring(0,16).ToLowerInvariant()
    return "plan-$hash"
}
function Initialize-PondGateAttempt {
    param([string]$PlanPath,[string]$Gate,[string]$TaskRoot)
    $content=Get-Content $PlanPath -Raw; $planId=Get-PondStablePlanId $PlanPath; $n=0
    $currentAttempt=Get-PondPlanHeader $content 'AttemptId'; $currentRelative=Get-PondPlanHeader $content 'GateResult'
    [void][int]::TryParse((Get-PondPlanHeader $content 'GateAttempt'),[ref]$n)
    if ($currentAttempt -and $currentRelative -match "(?i)^Results/$([regex]::Escape($planId))/$([regex]::Escape($Gate))/$([regex]::Escape($currentAttempt))\.json$" -and -not (Test-Path (Join-Path (Split-Path $TaskRoot -Parent) $currentRelative))) {
        return [pscustomobject]@{PlanId=$planId;AttemptId=$currentAttempt;GateAttempt=$n;RelativePath=$currentRelative;Path=(Join-Path (Split-Path $TaskRoot -Parent) $currentRelative)}
    }
    $n++
    $attemptId=[guid]::NewGuid().ToString('n')
    Set-PondPlanHeader $PlanPath 'PlanId' $planId; Set-PondPlanHeader $PlanPath 'AttemptId' $attemptId; Set-PondPlanHeader $PlanPath 'GateAttempt' ([string]$n)
    $relative="Results/$planId/$Gate/$attemptId.json"; Set-PondPlanHeader $PlanPath 'GateResult' $relative
    return [pscustomobject]@{PlanId=$planId;AttemptId=$attemptId;GateAttempt=$n;RelativePath=$relative;Path=(Join-Path (Split-Path $TaskRoot -Parent) $relative)}
}
function Write-PondGateResult {
    param([string]$PlanPath,[string]$Gate,[string]$TaskRoot,[bool]$ProviderSucceeded,[string]$RepoDir)
    $content=Get-Content $PlanPath -Raw; $planId=Get-PondPlanHeader $content 'PlanId'; $attemptId=Get-PondPlanHeader $content 'AttemptId'; $gateAttempt=0
    [void][int]::TryParse((Get-PondPlanHeader $content 'GateAttempt'),[ref]$gateAttempt)
    if(-not $planId -or -not $attemptId){
        $identity=Initialize-PondGateAttempt -PlanPath $PlanPath -Gate $Gate -TaskRoot $TaskRoot
        $content=Get-Content $PlanPath -Raw; $planId=$identity.PlanId; $attemptId=$identity.AttemptId; $gateAttempt=$identity.GateAttempt
    }
    $contract=switch($Gate){'Review'{@{Decision='ReviewDecision';Evidence='Reviewed'}};'Audit'{@{Decision='AuditDecision';Evidence='Audit'}};'QA'{@{Decision='QADecision';Evidence='QA'}};'ProjectReview'{@{Decision='ProjectReviewDecision';Evidence='ProjectReview'}};'Code'{@{Decision=$null;Evidence='Implementation'}};'Investigate'{@{Decision='InvestigatorDecision';Evidence='Investigated'}};default{@{Decision=$null;Evidence=$Gate}}}
    $verdict=Get-PondGateVerdict -Content $content -DecisionHeader $contract.Decision -EvidenceHeader $contract.Evidence
    $qaEvidence = $null
    $requiresQAEvidenceValidation = $Gate -eq 'QA' -and ($content -match '(?im)^\*\*MutationTooling\*\*:\s*unavailable\s*$' -or ($ProviderSucceeded -and $verdict.Passed))
    if ($requiresQAEvidenceValidation) {
        if ([string]::IsNullOrWhiteSpace($RepoDir)) {
            $qaEvidence = New-PondQAEvidenceResult $false $false 'QA evidence cannot be validated without the target repository path.'
        } else {
            $qaEvidence = Test-PondQAEvidence -PlanPath $PlanPath -RepoDir $RepoDir
        }
        if ($qaEvidence.DecisionRequired) {
            Set-PondPlanHeader -Path $PlanPath -Name 'DecisionRequired' -Value 'yes'
            Set-PondPlanHeader -Path $PlanPath -Name 'DecisionReason' -Value $qaEvidence.Error
            $content = Get-Content $PlanPath -Raw
        }
    }
    $implicitSuccess = $ProviderSucceeded -and (-not $verdict.Found) -and $Gate -in @('Code','Project','Intake','Archive')
    $decisionValue = if ($contract.Decision) { Get-PondPlanHeader $content $contract.Decision } else { '' }
    $explicitDecision = Get-PondPlanHeader $content 'DecisionRequired'
    $qaPassed = $Gate -ne 'QA' -or -not $requiresQAEvidenceValidation -or ($qaEvidence -and $qaEvidence.Passed)
    $failureKind=if($ProviderSucceeded -and ($verdict.Passed -or $implicitSuccess) -and $qaPassed){'success'}elseif($explicitDecision -match '(?i)yes|true|required' -or $decisionValue -match '(?i)decision.required|manual'){ 'decision-required' }elseif($content -match '(?i)timeout|timed out'){ 'timeout' }elseif($verdict.Failed -or ($Gate -eq 'QA' -and -not $qaPassed)){'semantic-failure'}elseif(-not $ProviderSucceeded){'transport-failure'}else{'engine-error'}
    $value=if($Gate -eq 'QA' -and $qaEvidence -and -not $qaEvidence.Passed){$qaEvidence.Error}elseif($verdict.Found){$verdict.Value}else{'missing explicit verdict'}
    $signature=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Gate|$failureKind|$value"))).Substring(0,16).ToLowerInvariant()
    $result=[ordered]@{planId=$planId;gate=$Gate;attemptId=$attemptId;gateAttempt=$gateAttempt;verdict=if($failureKind -eq 'success'){'pass'}else{'fail'};failureKind=$failureKind;startedAt='';completedAt=[datetimeoffset]::UtcNow.ToString('o');evidenceSummary=$value;failedChecks=@();fixActions=@();changedFileScope=@();failureSignature=$signature}
    if ($qaEvidence) { $result.qaEvidence = @{ path=$qaEvidence.Path; sha256=$qaEvidence.Sha256; passed=$qaEvidence.Passed } }
    $relative=Get-PondPlanHeader $content 'GateResult'; $path=Join-Path (Split-Path $TaskRoot -Parent) $relative; $null=New-Item (Split-Path $path) -ItemType Directory -Force
    $tmp="$path.tmp-$PID"; $result|ConvertTo-Json -Depth 6|Set-Content $tmp -Encoding utf8 -NoNewline; Move-Item $tmp $path -Force
    $current=Join-Path (Split-Path $path) 'current.json'; Copy-Item $path "$current.tmp-$PID" -Force; Move-Item "$current.tmp-$PID" $current -Force
    return [pscustomobject]$result
}
function Get-PondValidatedGateResult {
    param([string]$PlanPath,[string]$Gate,[string]$TaskRoot)
    $content=Get-Content $PlanPath -Raw; $relative=Get-PondPlanHeader $content 'GateResult'; if(-not $relative){return $null}
    $path=Join-Path (Split-Path $TaskRoot -Parent) $relative; if(-not(Test-Path $path)){return $null}
    $result=Get-Content $path -Raw|ConvertFrom-Json -ErrorAction SilentlyContinue; if(-not $result){return $null}
    foreach($name in @('planId','gate','attemptId','gateAttempt','verdict','failureKind','completedAt','evidenceSummary')){if(-not $result.PSObject.Properties[$name]){return $null}}
    if($result.planId -ne (Get-PondPlanHeader $content 'PlanId') -or $result.attemptId -ne (Get-PondPlanHeader $content 'AttemptId') -or $result.gate -ne $Gate){return $null}
    if($result.failureKind -notin @('success','semantic-failure','transport-failure','timeout','decision-required','engine-error')){return $null}
    return $result
}
