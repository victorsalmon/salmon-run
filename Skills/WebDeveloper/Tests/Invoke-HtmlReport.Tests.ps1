#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $ModuleFile = Resolve-Path (Join-Path $PSScriptRoot '..' 'Invoke-HtmlReport.ps1')
    . $ModuleFile
}

Describe 'Invoke-HtmlReport' -Tag 'Unit' {
    It 'generates a valid estimate HTML report' {
        $estimate = @{
            Title = 'Automation Audit'
            Client = 'Acme Corp'
            Date = '2026-07-24'
            PreparedBy = 'Interclaw'
            Scope = 'Full automation audit of financial workflows'
            Items = @(
                @{ Description = 'Process audit'; Hours = '20'; Rate = '$150'; Subtotal = '$3,000' }
                @{ Description = 'Implementation'; Hours = '40'; Rate = '$150'; Subtotal = '$6,000' }
            )
            Total = '9,000'
            Terms = 'Payment due within 30 days of invoice. Estimate valid for 14 days.'
        }
        $outPath = Join-Path $TestDrive 'estimate.html'
        $result = Invoke-HtmlReport -Type estimate -Data $estimate -OutputPath $outPath
        $result | Should -Exist
        $html = Get-Content -Path $result -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'Automation Audit'
        $html | Should -Match 'Acme Corp'
        $html | Should -Match '\$9,000'
        $html | Should -Match '</html>'
    }

    It 'generates a valid guide HTML report' {
        $guide = @{
            Title = 'Client Onboarding'
            Intro = 'Welcome to Clock Lobster Consulting'
            Timeline = @(
                @{ date = 'Week 1'; label = 'Discovery' }
                @{ date = 'Week 2'; label = 'Audit' }
            )
            Steps = @(
                @{ title = 'Initial Meeting'; description = 'Scope discussion' }
                @{ title = 'Data Gathering'; description = 'Collect financial records' }
            )
            Deliverables = @(
                @{ Item = 'Audit Report'; Due = 'Week 3'; Owner = 'Consultant' }
            )
            NextSteps = 'Schedule follow-up meeting'
        }
        $outPath = Join-Path $TestDrive 'guide.html'
        $result = Invoke-HtmlReport -Type guide -Data $guide -OutputPath $outPath
        $result | Should -Exist
        $html = Get-Content -Path $result -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'Client Onboarding'
    }

    It 'generates a valid status HTML report' {
        $status = @{
            Title = 'Project Status Update'
            Client = 'Acme Corp'
            Updated = '2026-07-24'
            Status = 'On Track'
            StatusClass = 'on-track'
            Milestones = '<div class="milestone"><div class="milestone-header"><span class="name">Discovery Phase</span><span class="pct">80%</span></div><div class="progress-bar"><div class="progress-fill green" style="width:80%"></div></div></div>'
            Risks = '<span class="risk-indicator green"><span class="risk-dot green"></span> No critical risks</span>'
            NextSteps = '<li class="done">Complete audit</li><li class="pending">Review findings</li>'
            Summary = 'Project is on track for delivery'
        }
        $outPath = Join-Path $TestDrive 'status.html'
        $result = Invoke-HtmlReport -Type status -Data $status -OutputPath $outPath
        $result | Should -Exist
        $html = Get-Content -Path $result -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'Project Status Update'
    }

    It 'strips {{#if}} block when conditional key is absent' {
        $guide = @{
            Title = 'Minimal Guide'
            Intro = 'Brief intro'
            Timeline = @()
            Steps = @(@{ title = 'Step 1'; description = 'Do thing' })
        }
        $outPath = Join-Path $TestDrive 'guide-no-conditional.html'
        $result = Invoke-HtmlReport -Type guide -Data $guide -OutputPath $outPath
        $html = Get-Content -Path $result -Raw
        $html | Should -Not -Match '\{\{'
        $html | Should -Not -Match '<h2>Timeline</h2>'
    }

    It 'strips {{#if}} block when conditional key is empty string' {
        $guide = @{
            Title = 'Minimal Guide'
            Intro = 'Brief intro'
            Timeline = @()
            Steps = @(@{ title = 'Step 1'; description = 'Do thing' })
            Deliverables = ''
        }
        $outPath = Join-Path $TestDrive 'guide-empty-deliverables.html'
        $result = Invoke-HtmlReport -Type guide -Data $guide -OutputPath $outPath
        $html = Get-Content -Path $result -Raw
        $html | Should -Not -Match '\{\{'
        $html | Should -Not -Match '<h2>Deliverables</h2>'
    }

    It 'renders {{#if}} block content when conditional key is present' {
        $guide = @{
            Title = 'Full Guide'
            Intro = 'Full intro'
            Timeline = @(@{ date = 'Week 1'; label = 'Start' })
            Steps = @(@{ title = 'Step 1'; description = 'Do thing' })
            Deliverables = @(@{ Item = 'Report'; Due = 'Week 2'; Owner = 'Consultant' })
            NextSteps = 'Follow up'
        }
        $outPath = Join-Path $TestDrive 'guide-full.html'
        $result = Invoke-HtmlReport -Type guide -Data $guide -OutputPath $outPath
        $html = Get-Content -Path $result -Raw
        $html | Should -Not -Match '\{\{'
        $html | Should -Match '<h2>Timeline</h2>'
        $html | Should -Match '<h2>Deliverables</h2>'
        $html | Should -Match 'Next Steps'
    }

    It 'strips status {{#if Summary}} block when Summary is absent' {
        $status = @{
            Title = 'Status No Summary'
            Client = 'Acme'
            Updated = '2026-07-24'
            Status = 'On Track'
            StatusClass = 'on-track'
            Milestones = '<div class="milestone">...</div>'
            Risks = '<span>No risks</span>'
            NextSteps = '<li>Done</li>'
        }
        $outPath = Join-Path $TestDrive 'status-no-summary.html'
        $result = Invoke-HtmlReport -Type status -Data $status -OutputPath $outPath
        $html = Get-Content -Path $result -Raw
        $html | Should -Not -Match '\{\{'
        $html | Should -Not -Match '<h2>Summary</h2>'
    }

    It 'produces self-contained HTML with inline CSS' {
        $estimate = @{
            Title = 'Test'
            Client = 'Test'
            Date = '2026-07-24'
            PreparedBy = 'Test'
            Items = @(@{ Description = 'Item'; Hours = '1'; Rate = '$100'; Subtotal = '$100' })
            Total = '100'
            Terms = 'Standard terms'
        }
        $outPath = Join-Path $TestDrive 'self-contained.html'
        $result = Invoke-HtmlReport -Type estimate -Data $estimate -OutputPath $outPath
        $html = Get-Content -Path $result -Raw
        $html | Should -Match '<style>'
        $html | Should -Not -Match '<link rel="stylesheet"'
        $html | Should -Not -Match '@import'
    }
}
