<#
.SYNOPSIS
    Conditionally runs a script block unless WhatIf mode is active.
.DESCRIPTION
    When WhatIf is true, logs the intended action and skips execution.
    Otherwise invokes the provided script block.
#>
function Invoke-WhatIfGuard {
    param(
        [string]$Message,
        [scriptblock]$ScriptBlock,
        [bool]$WhatIf
    )
    if ($WhatIf) {
        Write-Information -MessageData "  WOULD: $Message" -Tags "WARN"
        return
    }
    & $ScriptBlock
}
