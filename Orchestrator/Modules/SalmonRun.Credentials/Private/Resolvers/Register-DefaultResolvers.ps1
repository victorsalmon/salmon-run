function Get-WorktreeHost {
    <#
    .SYNOPSIS
        Resolves the Worktree / Gitea-compatible host for the Credentials resolver.
    .DESCRIPTION
        Checks $env:WORKTREE_HOST and ~/.salmon/.env, defaulting to
        https://worktree.example.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:WORKTREE_HOST)) {
        return $env:WORKTREE_HOST
    }

    $salmonHome = if (Get-Command Get-SalmonHome -ErrorAction SilentlyContinue) {
        Get-SalmonHome
    } else {
        if (-not [string]::IsNullOrWhiteSpace($env:SALMON_RUN_HOME)) {
            $env:SALMON_RUN_HOME
        } else {
            Join-Path $HOME '.salmon'
        }
    }

    $envPath = Join-Path $salmonHome '.env'
    if (Test-Path $envPath -PathType Leaf) {
        $values = Get-SalmonRunEnvFile -Path $envPath
        if ($values.Contains('WORKTREE_HOST') -and -not [string]::IsNullOrWhiteSpace($values['WORKTREE_HOST'])) {
            return $values['WORKTREE_HOST']
        }
    }

    return 'https://worktree.example'
}

function Register-DefaultSalmonRunCredentialResolvers {
    # Env resolver: returns the named environment variable, or the joined
    # arguments as a literal if the env var is not set.
    Register-SalmonRunCredentialResolver -Name 'Env' -ScriptBlock {
        param([string[]]$Arguments)
        if ($Arguments.Count -eq 0) { return $null }
        $varName = $Arguments[0]
        if ($varName -and (Get-Item -Path "Env:\$varName" -ErrorAction SilentlyContinue)) {
            return (Get-Item -Path "Env:\$varName").Value
        }
        return ($Arguments -join ' ')
    }

    # File resolver: reads the first line from the specified path.
    Register-SalmonRunCredentialResolver -Name 'File' -ScriptBlock {
        param([string[]]$Arguments)
        if ($Arguments.Count -eq 0) { throw 'File resolver requires a path' }
        $path = $Arguments -join ' '
        if (-not (Test-Path $path)) { throw "File not found: $path" }
        return [System.IO.File]::ReadAllLines($path)[0]
    }

    # AWS resolver:
    #   aws <profile> credentials <key>          -> ~/.aws/credentials
    #   aws <profile> config <key>               -> ~/.aws/config
    #   aws <profile> secretsmanager <secret>    -> full SecretString
    #   aws <profile> secretsmanager <secret> <json-key>
    Register-SalmonRunCredentialResolver -Name 'AWS' -ScriptBlock {
        param([string[]]$Arguments)
        if ($Arguments.Count -lt 3) { throw 'AWS resolver requires at least profile, mode, and target' }

        $profile = $Arguments[0]
        $mode = $Arguments[1].ToLower()

        switch ($mode) {
            'credentials' {
                $key = $Arguments[2]
                $credPath = Join-Path $HOME '.aws' 'credentials'
                if (-not (Test-Path $credPath)) { throw "AWS credentials file not found: $credPath" }
                $inProfile = $false
                foreach ($line in [System.IO.File]::ReadLines($credPath)) {
                    $trim = $line.Trim()
                    if ($trim -match '^\[(.+?\s*)\]') {
                        $inProfile = ($matches[1].Trim() -eq $profile -or $matches[1].Trim() -eq "profile $profile")
                    } elseif ($inProfile -and $trim -match "^$([regex]::Escape($key))\s*=\s*(.+)") {
                        return $matches[1].Trim()
                    }
                }
                throw "AWS credentials key '$key' not found for profile '$profile'"
            }
            'config' {
                $key = $Arguments[2]
                $configPath = Join-Path $HOME '.aws' 'config'
                if (-not (Test-Path $configPath)) { throw "AWS config file not found: $configPath" }
                $inProfile = $false
                foreach ($line in [System.IO.File]::ReadLines($configPath)) {
                    $trim = $line.Trim()
                    if ($trim -match '^(?:\[profile\s+)?(.+?)\s*\]') {
                        $inProfile = ($matches[1].Trim() -eq $profile)
                    } elseif ($inProfile -and $trim -match "^$([regex]::Escape($key))\s*=\s*(.+)") {
                        return $matches[1].Trim()
                    }
                }
                throw "AWS config key '$key' not found for profile '$profile'"
            }
            'secretsmanager' {
                $secretName = $Arguments[2]
                $jsonKey = if ($Arguments.Count -ge 4) { $Arguments[3] } else { $null }
                if (-not (Get-Command 'aws' -ErrorAction SilentlyContinue)) {
                    throw 'AWS CLI (aws) is not available'
                }
                $json = (& aws secretsmanager get-secret-value --secret-id $secretName --query 'SecretString' --output text --profile $profile 2>&1) | Out-String
                if ($LASTEXITCODE -ne 0) { throw "AWS Secrets Manager lookup failed: $json" }
                if ($jsonKey) {
                    $obj = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($obj -and $obj.PSObject.Properties[$jsonKey]) {
                        return $obj.$jsonKey
                    }
                    throw "JSON key '$jsonKey' not found in secret '$secretName'"
                }
                return $json.Trim()
            }
            default {
                throw "Unknown AWS resolver mode: $mode. Use credentials, config, or secretsmanager."
            }
        }
    }

    # Worktree resolver: reads a repository secret from a Worktree / Gitea-compatible host.
    #   worktree <owner> <repo> <secret-name>
    Register-SalmonRunCredentialResolver -Name 'Worktree' -ScriptBlock {
        param([string[]]$Arguments)
        if ($Arguments.Count -ne 3) { throw 'Worktree resolver requires owner, repo, and secret-name' }
        $owner, $repo, $secretName = $Arguments
        $token = $env:WORKTREE_REPO_RW_ACCESS_TOKEN
        if ([string]::IsNullOrWhiteSpace($token)) {
            if (Get-Module 'SalmonRun.GitCloud' -ErrorAction SilentlyContinue) {
                $token = Get-WorktreeToken
            }
        }
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Worktree resolver: no token available' }

        $host = Get-WorktreeHost
        $uri = "$host/api/v1/repos/$owner/$repo/actions/secrets/$secretName"
        $headers = @{
            Authorization = "token $token"
            Accept        = 'application/json'
        }
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
        if ($response -and $response.data) {
            return $response.data
        }
        if ($response -and $response.value) { return $response.value }
        return $response.ToString()
    }

    # GitHub resolver: points at a named environment variable (GitHub tokens are not
    # readable through the repository-secrets API, so this is a redirect resolver).
    #   github token <env-var>
    Register-SalmonRunCredentialResolver -Name 'GitHub' -ScriptBlock {
        param([string[]]$Arguments)
        if ($Arguments.Count -lt 2 -or $Arguments[0].ToLower() -ne 'token') {
            throw 'GitHub resolver currently supports: github token <env-var>'
        }
        $varName = $Arguments[1]
        if (Get-Item -Path "Env:\$varName" -ErrorAction SilentlyContinue) {
            return (Get-Item -Path "Env:\$varName").Value
        }
        throw "GitHub resolver: env var '$varName' is not set"
    }
}
