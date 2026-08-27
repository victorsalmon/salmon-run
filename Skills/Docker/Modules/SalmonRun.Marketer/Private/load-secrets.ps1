function Initialize-MarketerSecrets {
    try {
        $bundle = Get-MarketerSecretBundle -ErrorAction Stop
    } catch {
        Write-Warning "Initialize-MarketerSecrets: failed to get secret bundle - $_"
        $bundle = @{}
    }

    $script:AttioReadKey        = if ($bundle.ContainsKey('AttioReadKey'))        { $bundle.AttioReadKey }        else { $null }
    $script:AttioWriteKey       = if ($bundle.ContainsKey('AttioWriteKey'))       { $bundle.AttioWriteKey }       else { $null }
    $script:AttioArchiveKey     = if ($bundle.ContainsKey('AttioArchiveKey'))     { $bundle.AttioArchiveKey }     else { $null }
    $script:HunterApiKey        = if ($bundle.ContainsKey('HunterApiKey'))        { $bundle.HunterApiKey }        else { $null }
    $script:SmartleadApiKey     = if ($bundle.ContainsKey('SmartleadApiKey'))     { $bundle.SmartleadApiKey }     else { $null }
    $script:OpenrouterApiKey    = if ($bundle.ContainsKey('OpenrouterApiKey'))    { $bundle.OpenrouterApiKey }    else { $null }
    $script:ApolloSearchKey     = if ($bundle.ContainsKey('ApolloApiKey'))        { $bundle.ApolloApiKey }        else { $null }
    $script:ApolloEnrichKey     = if ($bundle.ContainsKey('ApolloEnrichKey'))     { $bundle.ApolloEnrichKey }     else { $null }
    $script:ZerobounceApiKey    = if ($bundle.ContainsKey('ZeroBounceApiKey'))    { $bundle.ZeroBounceApiKey }    else { $null }
}
