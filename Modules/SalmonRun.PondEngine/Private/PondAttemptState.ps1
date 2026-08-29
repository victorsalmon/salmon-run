function Register-PondAttemptOutcome {
    [CmdletBinding()]
    param([string]$PlanPath,[string]$Gate,[string]$TaskRoot,[object]$Result)
    $planId=[string]$Result.planId; $stateDir=Join-Path (Split-Path $TaskRoot -Parent) 'State';$null=New-Item $stateDir -ItemType Directory -Force;$path=Join-Path $stateDir "$planId.json"
    $state=if(Test-Path $path){Get-Content $path -Raw|ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue}else{$null}
    if(-not $state){$state=@{planId=$planId;gates=@{};transitions=@();highestGate=-1}}
    if(-not $state.gates){$state.gates=@{}};if(-not $state.gates.ContainsKey($Gate)){$state.gates[$Gate]=@{transportAttempts=0;semanticAttempts=0;lastSignature='';identicalFailures=0}}
    $gateState=$state.gates[$Gate];$now=[datetimeoffset]::UtcNow;$kind=[string]$Result.failureKind;$directive=''
    if($kind -eq 'success'){
        $gateState.transportAttempts=0;$gateState.semanticAttempts=0;$gateState.identicalFailures=0;$directive='Forward'
        $ranks=@{Code=0;Review=1;Audit=2;QA=3;ProjectReview=3;Complete=4};if($ranks.ContainsKey($Gate) -and $ranks[$Gate] -gt [int]$state.highestGate){$state.highestGate=$ranks[$Gate]}
    } elseif($kind -in @('transport-failure','timeout')){
        $gateState.transportAttempts=[int]$gateState.transportAttempts+1;$directive=if($gateState.transportAttempts -le 2){'Retry'}else{'Pause'}
    } elseif($kind -eq 'semantic-failure'){
        $gateState.semanticAttempts=[int]$gateState.semanticAttempts+1
        if($gateState.lastSignature -eq $Result.failureSignature){$gateState.identicalFailures=[int]$gateState.identicalFailures+1}else{$gateState.identicalFailures=1}
        $gateState.lastSignature=$Result.failureSignature;$directive=if($gateState.semanticAttempts -ge 2 -or $gateState.identicalFailures -ge 2){'Investigate'}else{'Rework'}
    } elseif($kind -eq 'decision-required'){$directive='Decision'}else{$directive='Pause'}
    $recent=@($state.transitions|Where-Object{try{[datetimeoffset]$_.ts -ge $now.AddMinutes(-30)}catch{$false}})
    $recent+=@{ts=$now.ToString('o');gate=$Gate;attemptId=$Result.attemptId;failureKind=$kind;directive=$directive;signature=$Result.failureSignature}
    if(@($recent|Where-Object{$_.failureKind -ne 'success'}).Count -ge 6 -and @($recent|Where-Object{$_.failureKind -eq 'success'}).Count -eq 0){$directive='Pause'}
    $state.transitions=@($recent|Select-Object -Last 20);$state.gates[$Gate]=$gateState;$state.updatedAt=$now.ToString('o')
    $tmp="$path.tmp-$PID";$state|ConvertTo-Json -Depth 8|Set-Content $tmp -Encoding utf8 -NoNewline;Move-Item $tmp $path -Force
    Write-PondOperationalEvent -PlanPath $PlanPath -Entry @{pond=$Gate;role='coordinator';action='transition';detail=$directive;failureKind=$kind;attemptId=$Result.attemptId;planId=$planId}|Out-Null
    return [pscustomobject]@{Directive=$directive;TransportAttempts=[int]$gateState.transportAttempts;SemanticAttempts=[int]$gateState.semanticAttempts;IdenticalFailures=[int]$gateState.identicalFailures;StatePath=$path}
}