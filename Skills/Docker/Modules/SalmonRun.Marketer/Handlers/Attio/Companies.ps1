# Attio.Companies — capability gate for company (organization) operations.
# Required keys: ATTIO_WRITE_KEY, ATTIO_READ_KEY, ATTIO_ARCHIVE_KEY.
# Capabilities: attio:read, attio:write, attio:archive.

function Get-AttioCompany {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CompanyId
    )

    Test-MarketerCapability -RequiredCapability 'attio:read'

    $result = Invoke-AttioApi -Method GET -Endpoint "/objects/companies/records/$CompanyId" -ApiKey $script:AttioReadKey
    if ($result.Success -and $result.Data.data) {
        $c = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:read' -Action "Get-AttioCompany" -Context @{ CompanyId = $CompanyId } -Result 'allow'
        return [pscustomobject]@{
            CompanyId    = $c.id.record_id
            DisplayName  = $c.values.name
            Domain       = $c.values.domains
        }
    }
    return $result
}

function New-AttioCompany {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Domain
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $values = @{ name = @(@{ value = $DisplayName }) }
    if ($Domain) { $values.domains = @(@{ domain = $Domain }) }

    $body = @{ data = @{ values = $values } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method POST -Endpoint "/objects/companies/records" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success -and $result.Data.data) {
        $c = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "New-AttioCompany" -Context @{ Name = $DisplayName } -Result 'allow'
        return [pscustomobject]@{
            CompanyId    = $c.id.record_id
            DisplayName  = $DisplayName
            Domain       = $Domain
        }
    }
    return $result
}

function Update-AttioCompany {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CompanyId,
        [string]$DisplayName,
        [string]$Domain
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $values = @{}
    if ($DisplayName) { $values.name = @(@{ value = $DisplayName }) }
    if ($Domain) { $values.domains = @(@{ domain = $Domain }) }

    $body = @{ data = @{ values = $values } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method PATCH -Endpoint "/objects/companies/records/$CompanyId" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "Update-AttioCompany" -Context @{ CompanyId = $CompanyId } -Result 'allow'
    }
    return $result
}

function Archive-AttioCompany {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CompanyId
    )

    Test-MarketerCapability -RequiredCapability 'attio:archive'

    $body = @{
        data = @{
            values = @{
                lifecycle_stage = @(@{
                    active_from   = (Get-Date -Format 'o')
                    active_option = "archived"
                })
            }
        }
    } | ConvertTo-Json -Depth 5

    $result = Invoke-AttioApi -Method PATCH -Endpoint "/objects/companies/records/$CompanyId" -Body $body -ApiKey $script:AttioArchiveKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:archive' -Action "Archive-AttioCompany" -Context @{ CompanyId = $CompanyId } -Result 'allow'
    }
    return $result
}
