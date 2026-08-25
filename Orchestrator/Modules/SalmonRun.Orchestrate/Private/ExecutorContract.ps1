function New-ExecutorTask {
    param($Handle, $StreamId, $StartTime, $Role, $Namespace)
    return [PSCustomObject]@{
        Handle    = $Handle
        StreamId  = $StreamId
        StartTime = $StartTime
        Role      = $Role
        Namespace = $Namespace
        HasExited   = $false
        ExitCode    = $null
        Output      = $null
    }
}
