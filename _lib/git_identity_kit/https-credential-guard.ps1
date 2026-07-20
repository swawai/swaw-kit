[CmdletBinding()]
param(
    [ValidateSet("get", "store", "erase")]
    [string]$Operation = "get"
)

$ErrorActionPreference = "Stop"

function ConvertFrom-CredentialRequest {
    param([string]$Request)

    $fields = @{}
    foreach ($line in @($Request -split "`r?`n")) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { continue }
        $fields[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
    return $fields
}

function Get-LocalConfigValue {
    param([string]$Key)

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $lines = @(& git config --local --get $Key 2>$null | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0 -or $lines.Count -ne 1) { return $null }
    return $lines[0]
}

function Get-HttpsIdentityContext {
    if (
        $env:GIT_ID_HTTPS_PROVIDER -in @("github", "gitlab") -and
        -not [string]::IsNullOrWhiteSpace($env:GIT_ID_HTTPS_HOST) -and
        -not [string]::IsNullOrWhiteSpace($env:GIT_ID_HTTPS_USER) -and
        -not [string]::IsNullOrWhiteSpace($env:GIT_ID_HTTPS_CREDENTIAL_USER) -and
        -not [string]::IsNullOrWhiteSpace($env:GIT_ID_CREDENTIAL_NAMESPACE)
    ) {
        return [pscustomobject]@{
            Provider       = $env:GIT_ID_HTTPS_PROVIDER
            HostName       = $env:GIT_ID_HTTPS_HOST
            AccountUser    = $env:GIT_ID_HTTPS_USER
            CredentialUser = $env:GIT_ID_HTTPS_CREDENTIAL_USER
            EntryCommand   = $env:GIT_ID_ENTRY_COMMAND
            Namespace      = $env:GIT_ID_CREDENTIAL_NAMESPACE
        }
    }

    if ((Get-LocalConfigValue "swaw-kit-git.managed") -cne "true") { return $null }
    $access = Get-LocalConfigValue "swaw-kit-git.access"
    $match = [regex]::Match($access, '^https\.(?<provider>github|gitlab):(?<host>[^/\s]+)/(?<user>[^/\s]+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }

    $provider = $match.Groups["provider"].Value.ToLowerInvariant()
    $hostName = $match.Groups["host"].Value
    $accountUser = $match.Groups["user"].Value
    $credentialUser = if ($provider -eq "gitlab") { "oauth2" } else { $accountUser }
    $entryCommand = Get-LocalConfigValue "swaw-kit-git.entry"
    $namespaceComponents = @($entryCommand, $provider, $hostName, $accountUser)
    if ([string]::IsNullOrWhiteSpace($entryCommand) -or
        @($namespaceComponents | Where-Object { $_.Contains("@") }).Count -gt 0) {
        return $null
    }

    $namespace = "swaw-kit-git.v2@$entryCommand@$provider@$hostName@$accountUser"
    $providerKey = "credential.https://$hostName.provider"
    $usernameKey = "credential.https://$hostName.username"
    $requiredValues = @(
        [pscustomobject]@{ Key = "credential.namespace"; Value = $namespace; IgnoreCase = $false }
        [pscustomobject]@{ Key = "swaw-kit-git.credential-namespace"; Value = $namespace; IgnoreCase = $false }
        [pscustomobject]@{ Key = "credential.credentialStore"; Value = "wincredman"; IgnoreCase = $false }
        [pscustomobject]@{ Key = "swaw-kit-git.credential-store"; Value = "wincredman"; IgnoreCase = $false }
        [pscustomobject]@{ Key = "credential.interactive"; Value = "false"; IgnoreCase = $true }
        [pscustomobject]@{ Key = "swaw-kit-git.credential-interactive"; Value = "false"; IgnoreCase = $true }
        [pscustomobject]@{ Key = $providerKey; Value = $provider; IgnoreCase = $true }
        [pscustomobject]@{ Key = "swaw-kit-git.https-provider"; Value = $provider; IgnoreCase = $true }
        [pscustomobject]@{ Key = "swaw-kit-git.https-provider-config-key"; Value = $providerKey; IgnoreCase = $false }
        [pscustomobject]@{ Key = $usernameKey; Value = $credentialUser; IgnoreCase = $true }
        [pscustomobject]@{ Key = "swaw-kit-git.https-username"; Value = $credentialUser; IgnoreCase = $true }
        [pscustomobject]@{ Key = "swaw-kit-git.https-username-config-key"; Value = $usernameKey; IgnoreCase = $false }
    )
    foreach ($required in $requiredValues) {
        $actual = Get-LocalConfigValue $required.Key
        $comparison = if ($required.IgnoreCase) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals($actual, $required.Value, $comparison)) {
            return $null
        }
    }

    return [pscustomobject]@{
        Provider       = $provider
        HostName       = $hostName
        AccountUser    = $accountUser
        CredentialUser = $credentialUser
        EntryCommand   = $entryCommand
        Namespace      = $namespace
    }
}

function Set-GuardCredentialEnvironment {
    param([pscustomobject]$Identity)

    Remove-Item "Env:GIT_CONFIG_COUNT" -ErrorAction SilentlyContinue
    Remove-Item "Env:GIT_CONFIG_PARAMETERS" -ErrorAction SilentlyContinue
    $env:GCM_NAMESPACE = $Identity.Namespace
    $env:GCM_CREDENTIAL_STORE = "wincredman"
    $env:GCM_PROVIDER = $Identity.Provider
    $env:GCM_INTERACTIVE = "false"
    $env:GCM_TRACE_SECRETS = "false"
    $env:GIT_TRACE_REDACT = "1"
    $env:GIT_TERMINAL_PROMPT = "0"
}

function Get-HttpsCredentialRejection {
    param(
        [hashtable]$Fields,
        [pscustomobject]$Identity
    )

    if ($null -eq $Identity) {
        return "HTTPS credential guard could not resolve the bound Git identity."
    }

    $providerLabel = if ($Identity.Provider -eq "github") { "GitHub" } else { "GitLab" }
    $entryLabel = if ([string]::IsNullOrWhiteSpace($Identity.EntryCommand)) { "this Git identity" } else { $Identity.EntryCommand }
    $protocol = [string]$Fields["protocol"]
    $hostName = [string]$Fields["host"]
    $credentialUser = [string]$Fields["username"]

    if ($protocol -ine "https") {
        return "HTTPS credential request uses protocol '$protocol', but $entryLabel only permits HTTPS credentials."
    }
    if ($hostName -ine $Identity.HostName) {
        return "HTTPS credential request requests host '$hostName', but $entryLabel is bound to $providerLabel host '$($Identity.HostName)'."
    }
    if ([string]::IsNullOrWhiteSpace($credentialUser)) {
        return "HTTPS credential request for '$hostName' has no account, but $entryLabel is bound to $providerLabel account '$($Identity.AccountUser)'."
    }
    if ($credentialUser -ine $Identity.CredentialUser) {
        if ($Identity.Provider -eq "gitlab") {
            return "HTTPS credential request for '$hostName' requests credential username '$credentialUser', but $entryLabel is bound to GitLab account '$($Identity.AccountUser)' and requires credential username '$($Identity.CredentialUser)'. Remove the username from the remote URL."
        }
        return "HTTPS credential request for '$hostName' requests account '$credentialUser', but $entryLabel is bound to GitHub account '$($Identity.AccountUser)'. Remove the username from the remote URL."
    }

    return $null
}

function Stop-CredentialRequest {
    param(
        [string]$Message,
        [string]$CurrentOperation
    )

    [Console]::Error.WriteLine("[ERROR] $Message")
    if ($CurrentOperation -eq "get") {
        [Console]::Out.WriteLine("quit=true")
        [Console]::Out.WriteLine()
    }
    exit 0
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $request = [Console]::In.ReadToEnd()
        $fields = ConvertFrom-CredentialRequest $request
        $identity = Get-HttpsIdentityContext
        $rejection = Get-HttpsCredentialRejection $fields $identity
        if ($rejection) {
            Stop-CredentialRequest $rejection $Operation
        }

        Set-GuardCredentialEnvironment $identity
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $request | & git credential-manager $Operation
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        exit $exitCode
    } catch {
        Stop-CredentialRequest "HTTPS credential guard failed: $($_.Exception.Message)" $Operation
    }
}
