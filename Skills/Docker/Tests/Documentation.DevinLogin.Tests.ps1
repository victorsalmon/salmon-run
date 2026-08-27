Describe "Invoke-DevinBrowserLogin helper" -Tag "Devin", "Config" {
    BeforeAll {
        $script:UnderTest = Resolve-Path "C:\Repos\salmon-orchestrator\Orchestrator\Scripts\Invoke-DevinBrowserLogin.ps1"
        . $script:UnderTest
    }

    Context "Get-DevinAuthCodeFromUrl" {
        It "extracts the code from a Devin callback URL" {
            $url = "http://127.0.0.1:60590/callback?code=mG5L3ocCsi4W4ivDsGBHgB9STb--HgkJpO7n9XRWpZo&state=a3b94d4a-05cd-4c50-8dff-f55ffd3540bc"
            $code = Get-DevinAuthCodeFromUrl -Url $url
            $code | Should -Be "mG5L3ocCsi4W4ivDsGBHgB9STb--HgkJpO7n9XRWpZo"
        }

        It "returns null when the URL has no code" {
            $url = "https://example.com/callback?state=123"
            Get-DevinAuthCodeFromUrl -Url $url | Should -Be $null
        }

        It "returns null for an empty or invalid URL" {
            Get-DevinAuthCodeFromUrl -Url "" | Should -Be $null
            Get-DevinAuthCodeFromUrl -Url "not-a-url" | Should -Be $null
        }
    }
}
