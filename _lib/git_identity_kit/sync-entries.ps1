function New-ManagedConfigEntries {
    $entries = @(
        [pscustomobject]@{ ConfigKey = "user.name"; Values = @($env:GIT_ID_NAME); MarkerKey = "swaw-kit-git.user-name"; Required = $true },
        [pscustomobject]@{ ConfigKey = "user.email"; Values = @($env:GIT_ID_EMAIL); MarkerKey = "swaw-kit-git.user-email"; Required = $true },
        [pscustomobject]@{ ConfigKey = "transfer.credentialsInUrl"; Values = @("die"); MarkerKey = "swaw-kit-git.credentials-in-url"; Required = $false }
    )

    if ($env:GIT_ID_TRANSPORT -eq "ssh") {
        $entries += [pscustomobject]@{
            ConfigKey = "credential.helper"
            Values    = @('')
            MarkerKey = "swaw-kit-git.credential-helper"
            Required  = $false
        }
    } else {
        $credentialUrl = "https://$env:GIT_ID_HTTPS_HOST"
        $entries += @(
            [pscustomobject]@{ ConfigKey = "credential.helper"; Values = @("", $env:GIT_ID_HTTPS_CREDENTIAL_HELPER); MarkerKey = "swaw-kit-git.credential-helper"; Required = $true },
            [pscustomobject]@{ ConfigKey = "credential.namespace"; Values = @($env:GIT_ID_CREDENTIAL_NAMESPACE); MarkerKey = "swaw-kit-git.credential-namespace"; Required = $true },
            [pscustomobject]@{ ConfigKey = "credential.credentialStore"; Values = @("wincredman"); MarkerKey = "swaw-kit-git.credential-store"; Required = $true },
            [pscustomobject]@{ ConfigKey = "credential.interactive"; Values = @("false"); MarkerKey = "swaw-kit-git.credential-interactive"; Required = $true },
            [pscustomobject]@{
                ConfigKey       = "credential.$credentialUrl.provider"
                Values          = @($env:GIT_ID_HTTPS_PROVIDER)
                MarkerKey       = "swaw-kit-git.https-provider"
                ConfigKeyMarker = "swaw-kit-git.https-provider-config-key"
                Required        = $true
            },
            [pscustomobject]@{
                ConfigKey       = "credential.$credentialUrl.username"
                Values          = @($env:GIT_ID_HTTPS_CREDENTIAL_USER)
                MarkerKey       = "swaw-kit-git.https-username"
                ConfigKeyMarker = "swaw-kit-git.https-username-config-key"
                Required        = $true
            }
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GIT_SSH_COMMAND)) {
        $entries += [pscustomobject]@{
            ConfigKey = "core.sshCommand"
            Values    = @($env:GIT_SSH_COMMAND)
            MarkerKey = "swaw-kit-git.ssh-command"
            Required  = $false
        }
    }

    $signingKey = [string]$env:GIT_ID_SIGNING_KEY
    $signingFormat = [string]$env:GIT_ID_GPG_FORMAT
    $hasSigningKey = -not [string]::IsNullOrEmpty($signingKey)
    $hasSigningFormat = -not [string]::IsNullOrEmpty($signingFormat)
    if (($hasSigningKey -and [string]::IsNullOrWhiteSpace($signingKey)) -or
        ($hasSigningFormat -and [string]::IsNullOrWhiteSpace($signingFormat))) {
        throw "Git signing key and format must not contain only whitespace."
    }
    if ($hasSigningKey -ne $hasSigningFormat) {
        throw "GIT_ID_SIGNING_KEY and GIT_ID_GPG_FORMAT must be configured together."
    }

    $signingEnabled = $hasSigningKey -and $hasSigningFormat
    if ($signingEnabled) {
        $signingFormat = $signingFormat.ToLowerInvariant()
        if ($signingFormat -notin @("openpgp", "ssh", "x509")) {
            throw "Invalid GIT_ID_GPG_FORMAT '$($env:GIT_ID_GPG_FORMAT)'. Use openpgp, ssh, or x509."
        }
    }

    $entries += @(
        [pscustomobject]@{ ConfigKey = "commit.gpgSign"; Values = @(if ($signingEnabled) { "true" } else { "false" }); MarkerKey = "swaw-kit-git.commit-gpg-sign"; Required = $false },
        [pscustomobject]@{ ConfigKey = "tag.gpgSign"; Values = @("false"); MarkerKey = "swaw-kit-git.tag-gpg-sign"; Required = $false }
    )
    if ($signingEnabled) {
        $entries += @(
            [pscustomobject]@{ ConfigKey = "user.signingkey"; Values = @($signingKey); MarkerKey = "swaw-kit-git.signing-key"; Required = $false },
            [pscustomobject]@{ ConfigKey = "gpg.format"; Values = @($signingFormat); MarkerKey = "swaw-kit-git.gpg-format"; Required = $false }
        )
    }

    foreach ($entry in $entries) {
        $values = @($entry.Values)
        if ($entry.Required -and ($values.Count -eq 0 -or ($values.Count -eq 1 -and [string]::IsNullOrWhiteSpace($values[0])))) {
            Write-Host "[ERROR] Missing required Git identity value for $($entry.ConfigKey)."
            exit 1
        }
    }
    return @($entries)
}

function Get-MarkerEntries {
    $catalog = @(
        @("user.name", "swaw-kit-git.user-name"),
        @("user.email", "swaw-kit-git.user-email"),
        @("transfer.credentialsInUrl", "swaw-kit-git.credentials-in-url"),
        @("credential.helper", "swaw-kit-git.credential-helper"),
        @("credential.namespace", "swaw-kit-git.credential-namespace"),
        @("credential.credentialStore", "swaw-kit-git.credential-store"),
        @("credential.interactive", "swaw-kit-git.credential-interactive"),
        @("core.sshCommand", "swaw-kit-git.ssh-command"),
        @("commit.gpgSign", "swaw-kit-git.commit-gpg-sign"),
        @("tag.gpgSign", "swaw-kit-git.tag-gpg-sign"),
        @("user.signingkey", "swaw-kit-git.signing-key"),
        @("gpg.format", "swaw-kit-git.gpg-format")
    )

    $entries = foreach ($item in $catalog) {
        $values = @(Get-LocalConfigValues $item[1])
        if ($values.Count -gt 0) {
            [pscustomobject]@{
                ConfigKey = $item[0]
                MarkerKey = $item[1]
                Values    = $values
            }
        }
    }

    foreach ($dynamic in @(
        [pscustomobject]@{ ConfigKeyMarker = "swaw-kit-git.https-provider-config-key"; MarkerKey = "swaw-kit-git.https-provider"; Suffix = "provider" },
        [pscustomobject]@{ ConfigKeyMarker = "swaw-kit-git.https-username-config-key"; MarkerKey = "swaw-kit-git.https-username"; Suffix = "username" }
    )) {
        $configKey = Get-LocalConfigValue $dynamic.ConfigKeyMarker
        $values = @(Get-LocalConfigValues $dynamic.MarkerKey)
        if ([string]::IsNullOrWhiteSpace($configKey) -or $values.Count -eq 0) {
            continue
        }
        $suffix = [regex]::Escape($dynamic.Suffix)
        if ($configKey -notmatch "^credential\.https://[A-Za-z0-9.-]+(?::[1-9][0-9]{0,4})?\.$suffix$") {
            Write-Host "[ERROR] Invalid managed HTTPS config marker: $configKey"
            exit 1
        }
        $entries += [pscustomobject]@{
            ConfigKey       = $configKey
            MarkerKey       = $dynamic.MarkerKey
            ConfigKeyMarker = $dynamic.ConfigKeyMarker
            Values          = $values
        }
    }
    return @($entries)
}
