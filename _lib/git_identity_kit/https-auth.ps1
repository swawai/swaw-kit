[CmdletBinding()]
param(
    [ValidateSet("login", "status")]
    [string]$Action = "login",
    [string]$Provider = "",
    [string]$AccountHost = "",
    [string]$ExpectedAccount = "",
    [string]$Namespace = "",
    [string]$CommandName = "git_identity"
)

$ErrorActionPreference = "Stop"

function Clear-InjectedGitConfigEnvironment {
    Remove-Item "Env:GIT_CONFIG_COUNT" -ErrorAction SilentlyContinue
    Remove-Item "Env:GIT_CONFIG_PARAMETERS" -ErrorAction SilentlyContinue
}

function Set-AuthoritativeGcmEnvironment {
    param(
        [string]$SelectedProvider,
        [string]$CredentialNamespace,
        [bool]$AllowInteraction
    )

    Clear-InjectedGitConfigEnvironment
    $env:GCM_NAMESPACE = $CredentialNamespace
    $env:GCM_INTERACTIVE = if ($AllowInteraction) { "true" } else { "false" }
    $env:GCM_CREDENTIAL_STORE = "wincredman"
    $env:GCM_PROVIDER = $SelectedProvider
    $env:GCM_GITHUB_AUTHMODES = if ($AllowInteraction -and $SelectedProvider -eq "github") { "browser" } else { "" }
    $env:GCM_GITLAB_AUTHMODES = if ($AllowInteraction -and $SelectedProvider -eq "gitlab") { "browser" } else { "" }
    $env:GCM_TRACE = ""
    $env:GCM_TRACE_SECRETS = "false"
    $env:GIT_TERMINAL_PROMPT = if ($AllowInteraction) { "1" } else { "0" }
}

function Invoke-Gcm {
    param(
        [string[]]$Arguments,
        [AllowNull()]
        [string]$InputText = $null,
        [switch]$SuppressErrorOutput
    )

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($null -eq $InputText -and $SuppressErrorOutput) {
            $output = @(& git @Arguments 2>$null | ForEach-Object { $_.ToString() })
        } elseif ($null -eq $InputText) {
            $output = @(& git @Arguments | ForEach-Object { $_.ToString() })
        } elseif ($SuppressErrorOutput) {
            $output = @($InputText | & git @Arguments 2>$null | ForEach-Object { $_.ToString() })
        } else {
            $output = @($InputText | & git @Arguments | ForEach-Object { $_.ToString() })
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "Git Credential Manager failed with exit code $exitCode."
    }
    return @($output)
}

function Assert-GcmAvailable {
    param([switch]$SuppressErrorOutput)

    $null = Invoke-Gcm -Arguments @("credential-manager", "--version") -SuppressErrorOutput:$SuppressErrorOutput
}

function Assert-LoginInput {
    param(
        [string]$LoginProvider,
        [string]$CredentialHost,
        [string]$Account,
        [string]$CredentialNamespace
    )

    if ($LoginProvider -notin @("github", "gitlab")) {
        throw "Unsupported HTTPS login provider: '$LoginProvider'."
    }
    if ([string]::IsNullOrWhiteSpace($CredentialNamespace)) {
        throw "Credential namespace is missing."
    }
    if ($CredentialHost -notmatch '^[A-Za-z0-9.-]+(?::[1-9][0-9]{0,4})?$') {
        throw "Invalid HTTPS account host: '$CredentialHost'."
    }
    if ([string]::IsNullOrWhiteSpace($Account)) {
        throw "Set GIT_ID_ACCESS to https.github:host=HOST;account=ACCOUNT or https.gitlab:host=HOST;account=ACCOUNT before HTTPS login."
    }

    $valid = if ($LoginProvider -eq "github") {
        $Account -match '^(?!-)(?!.*--)[A-Za-z0-9-]{1,39}(?<!-)$'
    } else {
        $Account -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$'
    }
    if (-not $valid) {
        throw "Invalid $LoginProvider account name: '$Account'."
    }
}

function Get-GitHubAccounts {
    param(
        [string]$CredentialHost,
        [switch]$SuppressErrorOutput
    )

    $lines = @(Invoke-Gcm -Arguments @("credential-manager", "github", "list", "--url", "https://$CredentialHost") -SuppressErrorOutput:$SuppressErrorOutput)
    return @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Remove-GitHubAccounts {
    param(
        [string]$CredentialHost,
        [string[]]$Accounts
    )

    foreach ($account in @($Accounts | Select-Object -Unique)) {
        $null = Invoke-Gcm @("credential-manager", "github", "logout", $account, "--url", "https://$CredentialHost")
    }
}

function Remove-NewGitHubAccounts {
    param(
        [string]$CredentialHost,
        [string[]]$AccountsBefore
    )

    $accountsAfter = @(Get-GitHubAccounts $CredentialHost -SuppressErrorOutput)
    $newAccounts = @($accountsAfter | Where-Object { $AccountsBefore -inotcontains $_ })
    if ($newAccounts.Count -gt 0) {
        Remove-GitHubAccounts $CredentialHost $newAccounts
    }
    return $accountsAfter
}

function Invoke-GitHubLogin {
    param(
        [string]$CredentialHost,
        [string]$Account
    )

    $accountsBefore = @(Get-GitHubAccounts $CredentialHost -SuppressErrorOutput)
    try {
        $null = Invoke-Gcm @("credential-manager", "github", "login", "--url", "https://$CredentialHost", "--username", $Account, "--browser", "--force")
    } catch {
        try {
            $null = Remove-NewGitHubAccounts $CredentialHost $accountsBefore
        } catch {
            # Keep the original login or verification error as the actionable failure.
        }
        throw
    }

    $accounts = @(Get-GitHubAccounts $CredentialHost)
    if ($accounts -inotcontains $Account) {
        $actual = if ($accounts.Count -eq 0) { "none" } else { $accounts -join ", " }
        $null = Remove-NewGitHubAccounts $CredentialHost $accountsBefore
        throw "GitHub authorized '$actual', but this entry expected '$Account'."
    }

    $otherAccounts = @($accounts | Where-Object { $_ -ine $Account })
    if ($otherAccounts.Count -gt 0) {
        Remove-GitHubAccounts $CredentialHost $otherAccounts
    }
    $verifiedAccounts = @(Get-GitHubAccounts $CredentialHost)
    if ($verifiedAccounts.Count -ne 1 -or $verifiedAccounts[0] -ine $Account) {
        throw "GitHub authorization could not be reduced to the single expected account '$Account'."
    }
}

function Get-CredentialProtocolValues {
    param([string[]]$Lines)

    $values = @{}
    foreach ($line in $Lines) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
    return $values
}

function Clear-GitLabCredential {
    param([string]$CredentialHost)

    $request = "protocol=https`nhost=$CredentialHost`nusername=oauth2`n`n"
    $null = Invoke-Gcm @("credential-manager", "erase") $request
}

function Store-GitLabCredential {
    param(
        [string]$CredentialHost,
        [hashtable]$Credential
    )

    $credentialUser = [string]$Credential["username"]
    $password = [string]$Credential["password"]
    if ([string]::IsNullOrWhiteSpace($credentialUser) -or [string]::IsNullOrWhiteSpace($password)) {
        return
    }

    $request = "protocol=https`nhost=$CredentialHost`nusername=$credentialUser`npassword=$password`n`n"
    try {
        $null = Invoke-Gcm @("credential-manager", "store") $request
    } finally {
        $password = $null
        $request = $null
    }
}

function Get-GitLabCredential {
    param(
        [string]$CredentialHost,
        [switch]$SuppressErrorOutput
    )

    $request = "protocol=https`nhost=$CredentialHost`nusername=oauth2`n`n"
    $lines = @(Invoke-Gcm -Arguments @("credential-manager", "get") -InputText $request -SuppressErrorOutput:$SuppressErrorOutput)
    return Get-CredentialProtocolValues $lines
}

function Assert-GitLabCredentialOwner {
    param(
        [string]$CredentialHost,
        [string]$Account,
        [hashtable]$Credential,
        [scriptblock]$RestInvoker
    )

    $accessToken = $Credential["password"]
    if ($Credential["username"] -ne "oauth2" -or [string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Git Credential Manager did not return a GitLab OAuth credential."
    }

    $headers = @{ Authorization = "Bearer $accessToken" }
    try {
        $currentUser = & $RestInvoker ([uri]"https://$CredentialHost/api/v4/user") $headers
        if ([string]::IsNullOrWhiteSpace([string]$currentUser.username) -or [string]$currentUser.username -ine $Account) {
            throw "GitLab OAuth credential does not belong to '$Account'."
        }
    } finally {
        $headers["Authorization"] = $null
        $accessToken = $null
    }
}

function Invoke-GitLabLogin {
    param(
        [string]$CredentialHost,
        [string]$Account,
        [scriptblock]$RestInvoker
    )

    $previousCredential = $null
    $credential = $null
    try {
        $env:GCM_INTERACTIVE = "false"
        try {
            $previousCredential = Get-GitLabCredential $CredentialHost -SuppressErrorOutput
        } catch {
            $previousCredential = $null
        }

        $env:GCM_INTERACTIVE = "true"
        Clear-GitLabCredential $CredentialHost
        $credential = Get-GitLabCredential $CredentialHost
        Assert-GitLabCredentialOwner $CredentialHost $Account $credential $RestInvoker
    } catch {
        $loginError = $_
        try {
            Clear-GitLabCredential $CredentialHost
            if ($null -ne $previousCredential) {
                Store-GitLabCredential $CredentialHost $previousCredential
            }
        } catch {
            throw "GitLab login failed and the previous credential could not be restored: $($loginError.Exception.Message)"
        }
        throw $loginError
    } finally {
        $env:GCM_INTERACTIVE = "true"
        if ($null -ne $credential) {
            $credential["password"] = $null
        }
        if ($null -ne $previousCredential) {
            $previousCredential["password"] = $null
        }
    }
}

function Invoke-HttpsLogin {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [string]$AccountHost,
        [string]$ExpectedAccount,
        [string]$Namespace,
        [scriptblock]$RestInvoker = {
            param([uri]$Uri, [hashtable]$Headers)
            Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
        }
    )

    Assert-LoginInput $Provider $AccountHost $ExpectedAccount $Namespace
    Set-AuthoritativeGcmEnvironment $Provider $Namespace $true
    Assert-GcmAvailable

    if ($Provider -eq "github") {
        Invoke-GitHubLogin $AccountHost $ExpectedAccount
    } else {
        Invoke-GitLabLogin $AccountHost $ExpectedAccount $RestInvoker
    }

    $providerLabel = if ($Provider -eq "github") { "GitHub" } else { "GitLab" }
    Write-Host "[OK] $providerLabel HTTPS authorization ready: $AccountHost / account $ExpectedAccount"
}

function Invoke-HttpsStatus {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [string]$AccountHost,
        [string]$ExpectedAccount,
        [string]$Namespace,
        [string]$CommandName = "git_identity",
        [scriptblock]$RestInvoker = {
            param([uri]$Uri, [hashtable]$Headers)
            Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
        }
    )

    $label = if ($Provider -eq "github") { "GitHub" } else { "GitLab" }
    $display = "$label ($AccountHost)"
    $loginCommand = "$CommandName .https login"
    if ([string]::IsNullOrWhiteSpace($ExpectedAccount)) {
        return "  Not configured (set GIT_ID_ACCESS to https.github:host=HOST;account=ACCOUNT or https.gitlab:host=HOST;account=ACCOUNT)"
    }

    try {
        Assert-LoginInput $Provider $AccountHost $ExpectedAccount $Namespace
    } catch {
        return "  ${display}: invalid configuration ($($_.Exception.Message))"
    }

    Set-AuthoritativeGcmEnvironment $Provider $Namespace $false
    try {
        Assert-GcmAvailable -SuppressErrorOutput
    } catch {
        return "  ${display}: unavailable (Git Credential Manager is not available)"
    }

    if ($Provider -eq "github") {
        try {
            $accounts = @(Get-GitHubAccounts $AccountHost -SuppressErrorOutput)
        } catch {
            return "  ${display}: unavailable (could not inspect credential storage)"
        }
        if ($accounts.Count -eq 0) {
            return "  ${display}: not ready (run `"$loginCommand`")"
        }
        if ($accounts.Count -eq 1 -and $accounts[0] -ieq $ExpectedAccount) {
            return "  ${display}: stored ($ExpectedAccount)"
        }

        return "  ${display}: mismatch (stored: $($accounts -join ', '); expected: $ExpectedAccount; run `"$loginCommand`")"
    }

    $credential = $null
    try {
        try {
            $credential = Get-GitLabCredential $AccountHost -SuppressErrorOutput
        } catch {
            return "  ${display}: not ready (run `"$loginCommand`")"
        }

        if ($credential["username"] -ne "oauth2" -or [string]::IsNullOrWhiteSpace($credential["password"])) {
            return "  ${display}: not ready (run `"$loginCommand`")"
        }

        try {
            Assert-GitLabCredentialOwner $AccountHost $ExpectedAccount $credential $RestInvoker
            return "  ${display}: ready ($ExpectedAccount)"
        } catch {
            if ($_.Exception.Message -like "GitLab OAuth credential does not belong to*") {
                return "  ${display}: mismatch (credential does not belong to $ExpectedAccount; run `"$loginCommand`")"
            }
            return "  ${display}: unavailable (credential found, but account ownership could not be verified)"
        }
    } finally {
        if ($null -ne $credential) {
            $credential["password"] = $null
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        if ($Action -eq "status") {
            Write-Output (Invoke-HttpsStatus -Provider $Provider -AccountHost $AccountHost -ExpectedAccount $ExpectedAccount -Namespace $Namespace -CommandName $CommandName)
        } else {
            Invoke-HttpsLogin -Provider $Provider -AccountHost $AccountHost -ExpectedAccount $ExpectedAccount -Namespace $Namespace
        }
        exit 0
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)"
        exit 1
    }
}
