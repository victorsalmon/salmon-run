# Attio.Lists — capability gate for list/object-list operations.
# Required keys: ATTIO_WRITE_KEY, ATTIO_READ_KEY, ATTIO_ARCHIVE_KEY.
# Capabilities: attio:read, attio:write, attio:archive.

function Get-AttioList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ListId
    )

    Test-MarketerCapability -RequiredCapability 'attio:read'

    $result = Invoke-AttioApi -Method GET -Endpoint "/lists/$ListId" -ApiKey $script:AttioReadKey
    if ($result.Success -and $result.Data.data) {
        $l = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:read' -Action "Get-AttioList" -Context @{ ListId = $ListId } -Result 'allow'
        return [pscustomobject]@{
            ListId       = $l.id.list_id
            DisplayName  = $l.name
            ObjectType   = $l.object
        }
    }
    return $result
}

function New-AttioList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ObjectType
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $body = @{
        data = @{
            name   = $DisplayName
            object = $ObjectType
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $result = Invoke-AttioApi -Method POST -Endpoint "/lists" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success -and $result.Data.data) {
        $l = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "New-AttioList" -Context @{ Name = $DisplayName } -Result 'allow'
        return [pscustomobject]@{
            ListId       = $l.id.list_id
            DisplayName  = $l.name
            ObjectType   = $l.object
        }
    }
    return $result
}

function Update-AttioList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ListId,
        [string]$DisplayName
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $body = @{ data = @{ name = $DisplayName } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method PATCH -Endpoint "/lists/$ListId" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "Update-AttioList" -Context @{ ListId = $ListId } -Result 'allow'
    }
    return $result
}

function Add-AttioListEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ListId,
        [Parameter(Mandatory)][string]$RecordId
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $body = @{ data = @{ record_id = $RecordId } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method POST -Endpoint "/lists/$ListId/entries" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "Add-AttioListEntry" -Context @{ ListId = $ListId; RecordId = $RecordId } -Result 'allow'
    }
    return $result
}

function Remove-AttioListEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ListId,
        [Parameter(Mandatory)][string]$RecordId
    )

    Test-MarketerCapability -RequiredCapability 'attio:archive'

    $body = @{ data = @{ record_id = $RecordId } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method DELETE -Endpoint "/lists/$ListId/entries" -Body $body -ApiKey $script:AttioArchiveKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:archive' -Action "Remove-AttioListEntry" -Context @{ ListId = $ListId; RecordId = $RecordId } -Result 'allow'
    }
    return $result
}
