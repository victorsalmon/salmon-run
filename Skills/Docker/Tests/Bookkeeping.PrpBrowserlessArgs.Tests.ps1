# PRP browserless docker arg-array behavior.
# Regression guard for the docker invocation technique used by
# Skills/Bookkeeping/Scripts/reconciliation/Invoke-PrpBrowserlessReconcile.ps1:
# docker is invoked via array splatting (`& docker @dockerArgs`), so a mount
# path containing spaces or metacharacters (e.g. ';') must arrive as a single
# argument, never split or injected.
# To run: Invoke-Pester -Path .\Bookkeeping.PrpBrowserlessArgs.Tests.ps1
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "PRP Browserless Docker Invocation — array splatting" -Tag "Bookkeeping", "Unit" {
    It "passes a path with a space as a single -v mount argument (not split)" {
        $capturedArgs = [System.Collections.Generic.List[string]]::new()
        function docker {
            param()
            foreach ($arg in $args) { $capturedArgs.Add([string]$arg) }
        }

        $pathWithSpace = "C:\Users\Test User\intersite-docs\Taxes and Bookkeeping\reconcile-config.json"
        $volMount2 = $pathWithSpace + ":/data/reconcile-config.json"
        $dockerArgs = @(
            "run", "--rm", "-i", "--network", "service_net",
            "-v", "C:\data:/data", "-v", $volMount2,
            "-w", "/data", "node:20-slim", "sh", "-c",
            "npm install playwright; node /data/zoho-reconcile.js"
        )
        & docker @dockerArgs

        $capturedArgs | Should -Not -BeNullOrEmpty
        $capturedArgs.Count | Should -Be $dockerArgs.Count -Because "array splatting must not split or drop any argument"
        $secondMountIdx = $capturedArgs.IndexOf("-v", $capturedArgs.IndexOf("-v") + 1)
        $capturedArgs[$secondMountIdx + 1] | Should -Be $volMount2 -Because "the mount token must arrive intact as one argument"
    }

    It "passes a path containing a semicolon as a single mount argument (no metacharacter injection)" {
        $capturedArgs = [System.Collections.Generic.List[string]]::new()
        function docker {
            param()
            foreach ($arg in $args) { $capturedArgs.Add([string]$arg) }
        }

        $weirdPath = "C:\Users\Test;user\dir"
        $volMount1 = $weirdPath + ":/data"
        $dockerArgs = @("run", "--rm", "-i", "-v", $volMount1, "-w", "/data", "node:20-slim", "sh", "-c", "echo hi")
        & docker @dockerArgs

        $mountIdx = $capturedArgs.IndexOf("-v")
        $capturedArgs[$mountIdx + 1] | Should -Be $volMount1 -Because "the semicolon must not be interpreted as a command separator"
        $capturedArgs.Count | Should -Be $dockerArgs.Count -Because "no extra tokens should be introduced by the path"
    }
}
