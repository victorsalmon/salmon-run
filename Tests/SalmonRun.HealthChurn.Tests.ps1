Describe 'Churn-aware health' {
 It 'is unhealthy when live-looking work cycles without forward gate progress' {
  $taskHome=Join-Path $TestDrive '.salmon';$tasks=Join-Path $taskHome 'Tasks';$logs=Join-Path $taskHome 'Logs';$null=New-Item (Join-Path $tasks 'Code') -ItemType Directory -Force;$null=New-Item $logs -ItemType Directory -Force
  '# plan'|Set-Content (Join-Path $tasks 'Code/plan.md') -NoNewline;@{ts=[datetimeoffset]::Now.ToString('o');pid=$PID;state='running';detail='test'}|ConvertTo-Json|Set-Content (Join-Path $logs 'orchestrator.heartbeat.json') -NoNewline
  1..6|ForEach-Object { @{ts=[datetimeoffset]::Now.ToString('o');action='transition';planId='plan-1';pond='Review';failureKind='semantic-failure';detail='Rework'}|ConvertTo-Json -Compress|Add-Content (Join-Path $logs 'workflow-events.jsonl') }
  $report=& "$PSScriptRoot/../Tools/Get-SalmonRunHealthReport.ps1" -TaskRoot $taskHome -LogDir $logs;$report.healthy|Should -BeFalse;$report.forwardTransitions|Should -Be 0;$report.backwardTransitions|Should -Be 6;$report.cycleCount|Should -Be 1;$report.usefulAgentRunRatio|Should -Be 0
 }
 It 'ignores completed log-only lane directories as working state' {
  $taskHome=Join-Path $TestDrive 'empty-lane-home';$tasks=Join-Path $taskHome 'Tasks';$logs=Join-Path $taskHome 'Logs';$lane=New-Item (Join-Path $tasks 'Working/lane-coder-complete-1') -ItemType Directory -Force;$null=New-Item $logs -ItemType Directory -Force
  'completed'|Set-Content (Join-Path $lane 'executor.log') -NoNewline;@{ts=[datetimeoffset]::Now.ToString('o');pid=$PID;state='running';detail='test'}|ConvertTo-Json|Set-Content (Join-Path $logs 'orchestrator.heartbeat.json') -NoNewline
  $report=& "$PSScriptRoot/../Tools/Get-SalmonRunHealthReport.ps1" -TaskRoot $taskHome -LogDir $logs
  @($report.working)|Should -HaveCount 0;$report.staleWorking|Should -Be 0
 }}