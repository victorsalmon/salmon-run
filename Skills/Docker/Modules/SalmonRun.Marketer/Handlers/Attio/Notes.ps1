# Attio.Notes — capability gate for note operations on records.
# Required keys: ATTIO_WRITE_KEY, ATTIO_READ_KEY, ATTIO_ARCHIVE_KEY.
# Capabilities: attio:read, attio:write, attio:archive.

function Get-AttioNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NoteId
    )

    Test-MarketerCapability -RequiredCapability 'attio:read'

    $result = Invoke-AttioApi -Method GET -Endpoint "/notes/$NoteId" -ApiKey $script:AttioReadKey
    if ($result.Success -and $result.Data.data) {
        $n = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:read' -Action "Get-AttioNote" -Context @{ NoteId = $NoteId } -Result 'allow'
        return [pscustomobject]@{
            NoteId      = $n.id.note_id
            ParentObject = $n.parent_object
            ParentRecord = $n.parent_record_id
            Content     = $n.content
        }
    }
    return $result
}

function New-AttioNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$ParentObject,
        [Parameter(Mandatory)][string]$ParentRecordId
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $body = @{
        data = @{
            content        = $Content
            parent_object  = $ParentObject
            parent_record_id = $ParentRecordId
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $result = Invoke-AttioApi -Method POST -Endpoint "/notes" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success -and $result.Data.data) {
        $n = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "New-AttioNote" -Context @{ ParentObject = $ParentObject; ParentRecordId = $ParentRecordId } -Result 'allow'
        return [pscustomobject]@{
            NoteId       = $n.id.note_id
            ParentObject = $n.parent_object
            ParentRecord = $n.parent_record_id
            Content      = $n.content
        }
    }
    return $result
}

function Update-AttioNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NoteId,
        [Parameter(Mandatory)][string]$Content
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $body = @{ data = @{ content = $Content } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method PUT -Endpoint "/notes/$NoteId" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "Update-AttioNote" -Context @{ NoteId = $NoteId } -Result 'allow'
    }
    return $result
}

function Archive-AttioNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NoteId
    )

    Test-MarketerCapability -RequiredCapability 'attio:archive'

    $result = Invoke-AttioApi -Method DELETE -Endpoint "/notes/$NoteId" -ApiKey $script:AttioArchiveKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:archive' -Action "Archive-AttioNote" -Context @{ NoteId = $NoteId } -Result 'allow'
    }
    return $result
}
