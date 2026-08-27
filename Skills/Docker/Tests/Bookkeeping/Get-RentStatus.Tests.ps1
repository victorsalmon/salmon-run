#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $script:HandlerPath = Join-Path $script:RepoRoot "Infrastructure" "Bookkeeper" "handlers" "SalmonRun.Bookkeeping"
    $script:TestDataDir = Join-Path $env:TEMP "RentStatusTests-$(Get-Random)"
    $script:NoRegisterDir = Join-Path $env:TEMP "RentStatusTestsNoRegister-$(Get-Random)"
    $script:NoConfigDir = Join-Path $env:TEMP "RentStatusTestsNoConfig-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TestDataDir -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $script:TestDataDir "Contracts") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $script:NoRegisterDir "Contracts") -Force
    $null = New-Item -ItemType Directory -Path $script:NoConfigDir -Force

    $sampleConfig = @'
{
  "properties": {
    "TMH": { "name": "The Manor House", "address": "***REMOVED-ADDRESS***, Abbotsford BC" },
    "FRA": { "name": "Francis", "address": "Francis, Vernon BC" }
  },
  "rooms": [
    {
      "id": "tmh-amethyst", "name": "Amethyst", "property": "TMH",
      "occupants": ["Bonnie Rideout"], "contractStart": "2023-10-03", "contractEnd": "2026-08-01",
      "rent": 1331, "damageDeposit": 1350, "statusOverride": "", "custom": "", "notes": ""
    },
    {
      "id": "tmh-emerald", "name": "Emerald", "property": "TMH",
      "occupants": ["Adam Shepherd"], "contractStart": "2025-12-01", "contractEnd": "2027-07-01",
      "rent": 965, "damageDeposit": 965, "statusOverride": "", "custom": "", "notes": ""
    },
    {
      "id": "fra-jasper", "name": "Jasper", "property": "FRA",
      "occupants": ["***REMOVED-NAME***"], "contractStart": "2022-06-06", "contractEnd": "2027-05-01",
      "rent": 1400, "damageDeposit": 1400, "statusOverride": "", "custom": "", "notes": ""
    }
  ]
}
'@
    Set-Content -Path (Join-Path $script:TestDataDir "Contracts" "rooms-config.json") -Value $sampleConfig -Encoding utf8
    Set-Content -Path (Join-Path $script:NoRegisterDir "Contracts" "rooms-config.json") -Value $sampleConfig -Encoding utf8

    $sampleRegister = @'
room_id,payment_date,amount,paid_for_month,notes
tmh-amethyst,2026-05-01,1331,2026-06,Paid early
tmh-emerald,2026-05-15,965,2026-06,e-transfer
fra-jasper,2026-05-28,700,2026-06,Partial payment
'@
    Set-Content -Path (Join-Path $script:TestDataDir "rent-register.csv") -Value $sampleRegister -Encoding utf8
    Set-Content -Path (Join-Path $script:NoConfigDir "rent-register.csv") -Value $sampleRegister -Encoding utf8

    $script:OriginalRentDataDir = $env:RENT_DATA_DIR
    $env:RENT_DATA_DIR = $script:TestDataDir

    $handlerFile = Join-Path $script:HandlerPath "Public" "Get-RentStatus.ps1"
    if (Test-Path $handlerFile) {
        . $handlerFile
    }
}

AfterAll {
    if ($null -ne $script:OriginalRentDataDir) { $env:RENT_DATA_DIR = $script:OriginalRentDataDir } else { Remove-Item Env:RENT_DATA_DIR -ErrorAction SilentlyContinue }
    foreach ($dir in @($script:TestDataDir, $script:NoRegisterDir, $script:NoConfigDir)) {
        if ($dir -and (Test-Path $dir)) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Get-RentStatus" -Tag "Bookkeeping", "Unit", "Rent", "Regression" {
    It "returns Success for valid data" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Success | Should -Be $true
    }

    It "returns correct property count" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Properties.Keys.Count | Should -Be 2
    }

    It "reports tmh-amethyst as paid" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Properties.TMH.rooms['tmh-amethyst'].status | Should -Be "paid"
    }

    It "reports tmh-emerald as paid" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Properties.TMH.rooms['tmh-emerald'].status | Should -Be "paid"
    }

    It "reports fra-jasper as partial (700 of 1400)" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Properties.FRA.rooms['fra-jasper'].status | Should -Be "partial"
        $result.Properties.FRA.rooms['fra-jasper'].received | Should -Be 700
    }

    It "reports fra-jasper expected rent" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Properties.FRA.rooms['fra-jasper'].expected | Should -Be 1400
    }

    It "returns payment details with method inference" {
        $result = Get-RentStatus -Period "2026-06"
        $payment = $result.Properties.TMH.rooms['tmh-emerald'].payments[0]
        $payment.method | Should -Be "e-transfer"
        $payment.amount | Should -Be 965
    }

    It "filters by room_id" {
        $result = Get-RentStatus -Period "2026-06" -RoomId "tmh-emerald"
        $result.Properties.TMH.rooms.Keys.Count | Should -Be 1
        $result.Properties.TMH.rooms['tmh-emerald'].name | Should -Be "Emerald"
    }

    It "returns correct summary counts" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Summary.paid | Should -Be 2
        $result.Summary.partial | Should -Be 1
        $result.Summary.totalRooms | Should -Be 3
    }

    It "returns Error for missing register" {
        $env:RENT_DATA_DIR = $script:NoRegisterDir
        try {
            $result = Get-RentStatus -Period "2026-06"
            $result.Success | Should -Be $false
            $result.Error | Should -Match "not found"
        } finally {
            $env:RENT_DATA_DIR = $script:TestDataDir
        }
    }

    It "returns Error for missing config" {
        $env:RENT_DATA_DIR = $script:NoConfigDir
        try {
            $result = Get-RentStatus -Period "2026-06"
            $result.Success | Should -Be $false
            $result.Error | Should -Match "not found"
        } finally {
            $env:RENT_DATA_DIR = $script:TestDataDir
        }
    }

    It "reports rooms without payment in period as unpaid" {
        $result = Get-RentStatus -Period "2026-07"
        $result.Properties.TMH.rooms['tmh-amethyst'].status | Should -Be "unpaid"
    }

    It "reports rooms after contract end as ended" {
        $result = Get-RentStatus -Period "2026-09"
        $result.Properties.TMH.rooms['tmh-amethyst'].status | Should -Be "ended"
    }

    It "exposes no caller-supplied path parameters" {
        $params = Get-Command Get-RentStatus | Select-Object -ExpandProperty Parameters
        $params.ContainsKey('RegisterPath') | Should -Be $false
        $params.ContainsKey('ConfigPath') | Should -Be $false
    }

    It "reads only from RENT_DATA_DIR" {
        $result = Get-RentStatus -Period "2026-06"
        $result.Source | Should -Be (Join-Path $script:TestDataDir "rent-register.csv")
        $result.Properties.TMH.rooms['tmh-amethyst'].status | Should -Be "paid"
    }
}
