# Zoho.JournalEntries — journal entry creation for manual adjustments.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH (same as Expenses).
# Capabilities: zoho:expense:write.

function New-ZohoJournalEntry {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$Date,
        [string]$Description,
        [array]$Entries
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $lineItems = foreach ($entry in $Entries) {
        [pscustomobject]@{
            account_id      = $entry.account_id
            debit_or_credit = $entry.type
            amount          = [double]$entry.amount
            description     = $entry.description
        }
    }

    $body = @{
        journal_date = $Date
        description  = $Description
        line_items   = @($lineItems)
    }

    $result = Invoke-ZohoExpenseApi -Method POST -Endpoint "/journals" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.journal) {
        $je = $result.Data.journal
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:write' -Action "New-ZohoJournalEntry" -Context @{ JournalId = $je.journal_id; Description = $Description } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            journal_id = $je.journal_id
        }
    }
    return $result
}

function Get-ZohoJournals {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [int]$Page = 1,
        [int]$PerPage = 200
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $queryParams = @{ page = $Page; per_page = [math]::Min($PerPage, 200) }

    $result = Invoke-ZohoExpenseApi -Method GET -Endpoint "/journals" -OrganizationId $orgId -QueryParams $queryParams
    if ($result.Success) {
        $journals = @()
        if ($result.Data.journals) {
            $journals = $result.Data.journals | ForEach-Object {
                [pscustomobject]@{
                    JournalId   = $_.journal_id
                    Date        = $_.date
                    Description = $_.description
                    Total       = $_.total
                    JournalType = $_.journal_type
                    Status      = $_.status
                }
            }
        }
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:read' -Action "Get-ZohoJournals" -Context @{ OrgName = $OrgName; Count = $journals.Count } -Result 'allow'
        return [pscustomobject]@{
            Success  = $true
            Journals = $journals
            PageContext = if ($result.Data.page_context) { $result.Data.page_context } else { $null }
        }
    }
    return $result
}

function Remove-ZohoJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalId,
        [string]$OrgName = 'Intersite'
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $result = Invoke-ZohoExpenseApi -Method DELETE -Endpoint "/journals/$JournalId" -OrganizationId $orgId
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:write' -Action "Remove-ZohoJournalEntry" -Context @{ JournalId = $JournalId } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            JournalId = $JournalId
        }
    }
    return $result
}
