<#
.SYNOPSIS
    Restricts file ACL to current user only (full control).
.DESCRIPTION
    Removes inherited permissions and grants the current user exclusive
    FullControl access. Silently skips if the path does not exist.
#>
function Restrict-FileAccess {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Restrict file ACL to current user only')) {
        try {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $acl.SetAccessRuleProtection($true, $false)
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])
            foreach ($rule in $rules) {
                $null = $acl.RemoveAccessRule($rule)
            }
            $newRule = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, 'FullControl', 'Allow')
            $acl.SetAccessRule($newRule)
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        } catch {
            Write-Warning "Failed to restrict ACL on $Path : $_"
            throw
        }
    }
}
