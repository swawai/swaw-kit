[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryFile = Join-Path $repoRoot "git1.cmd"
$tempBase = Join-Path $repoRoot "temp_workspace"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExitCode {
    param(
        [int]$Actual,
        [int]$Expected,
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label failed: expected exit code $Expected, got $Actual."
    }
}

function Invoke-Captured {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [int]$ExpectedExitCode = 0,
        [string]$Label = $File
    )

    $output = (& $File @CommandArgs 2>&1 | Out-String -Width 4096)
    Assert-ExitCode $LASTEXITCODE $ExpectedExitCode $Label
    return $output
}

function Set-EntryLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )

    $pattern = '(?m)^(?::: )?set "' + [regex]::Escape($Name) + '=.*"\r?$'
    Assert-True ($Content -match $pattern) "entry template should declare $Name."
    $line = 'set "' + $Name + '=' + $Value + '"'
    return [regex]::Replace($Content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
}

function New-HttpsSmokeEntry {
    param([string]$TempRoot)

    $entryName = "git.https-smoke-" + [guid]::NewGuid().ToString("N")
    $entryRoot = Join-Path $TempRoot "entries"
    New-Item -ItemType Directory -Path $entryRoot -Force | Out-Null
    $path = Join-Path $entryRoot "$entryName.cmd"
    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "GIT_ID_NAME" "HTTPS Smoke User"
    $content = Set-EntryLine $content "GIT_ID_EMAIL" "https-smoke@example.invalid"
    $content = Set-EntryLine $content "GIT_ID_ACCESS" "https.github:host=github.example.com;account=github-smoke"
    $content = Set-EntryLine $content "GIT_ID_KIT" (Join-Path $repoRoot "_lib\git_identity_kit\kit.cmd")
    $content = $content.Replace("%~dp0_lib\editor_kit\entry-bootstrap.cmd", (Join-Path $repoRoot "_lib\editor_kit\entry-bootstrap.cmd"))
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-ExpectedCredentialNamespace {
    param(
        [string]$EntryCommand,
        [string]$Provider,
        [string]$HostName,
        [string]$Account
    )

    foreach ($component in @($EntryCommand, $Provider, $HostName, $Account)) {
        Assert-True (-not $component.Contains("@")) "namespace fixture components must not contain '@'."
    }
    return "swaw-kit-git.v2@$EntryCommand@$Provider@$HostName@$Account"
}

function Test-CredentialNamespaceIsUnambiguous {
    $first = Get-ExpectedCredentialNamespace "git" "gitlab" "h.com" "x.gitlab.h.com.b"
    $second = Get-ExpectedCredentialNamespace "git.gitlab.h.com.x" "gitlab" "h.com" "b"
    Assert-True ($first -ne $second) "namespace field boundaries should remain unambiguous when components contain dots."
}

function Set-HttpsSmokeAccess {
    param([string]$EntryPath, [string]$Account)

    $content = [System.IO.File]::ReadAllText($EntryPath)
    $content = Set-EntryLine $content "GIT_ID_ACCESS" $Account
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($EntryPath, $content, [System.Text.UTF8Encoding]::new($false))
}

function New-TempGitRepo {
    param([string]$TempRoot)

    $repoPath = Join-Path $TempRoot ("repo-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $repoPath | Out-Null
    Push-Location $repoPath
    try {
        git init -q
        Assert-ExitCode $LASTEXITCODE 0 "git init"
        git remote add origin "https://github.com/example/example.git"
        Assert-ExitCode $LASTEXITCODE 0 "git remote add origin"
    } finally {
        Pop-Location
    }
    return $repoPath
}

function Invoke-InDirectory {
    param(
        [string]$Directory,
        [scriptblock]$Script
    )

    Push-Location $Directory
    try {
        & $Script
    } finally {
        Pop-Location
    }
}

function Get-LocalGitConfigValues {
    param(
        [string]$RepoPath,
        [string]$Key
    )

    Push-Location $RepoPath
    try {
        $values = @(& git config --local --get-all $Key 2>$null | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
        return $values
    } finally {
        Pop-Location
    }
}

function Get-LocalGitConfig {
    param(
        [string]$RepoPath,
        [string]$Key
    )

    $values = @(Get-LocalGitConfigValues $RepoPath $Key)
    if ($values.Count -eq 0) {
        return $null
    }
    return $values[0]
}

function Assert-InjectedConfigPair {
    param(
        [string]$Output,
        [string]$Key,
        [string]$Value,
        [string]$Message
    )

    $keyPattern = '(?m)^GIT_CONFIG_KEY_(\d+)=' + [regex]::Escape($Key) + '\r?$'
    foreach ($match in [regex]::Matches($Output, $keyPattern)) {
        $index = $match.Groups[1].Value
        $valuePattern = '(?m)^GIT_CONFIG_VALUE_' + $index + '=' + [regex]::Escape($Value) + '\r?$'
        if ($Output -match $valuePattern) {
            return
        }
    }

    throw $Message
}

function Test-EntryTemplateDeclaresOneAccessDescriptor {
    $content = [System.IO.File]::ReadAllText($entryFile)
    Assert-True ($content.Contains('set "GIT_ID_ACCESS=')) "entry template should declare GIT_ID_ACCESS."
    Assert-True ($content -match '(?m)^:: set "GIT_ID_ACCESS=https\.github:host=[^;"]+;account=[^"]+"\r?$') "entry template should document an explicit GitHub HTTPS descriptor."
    Assert-True ($content -match '(?m)^:: set "GIT_ID_ACCESS=https\.gitlab:host=[^;"]+;account=[^"]+"\r?$') "entry template should document an explicit GitLab HTTPS descriptor."
    Assert-True (-not $content.Contains('set "GIT_SSH_VARIANT=')) "entry template should not expose the internally fixed OpenSSH variant."
}

function Test-EntryInjectsAuthoritativeHttpsIdentity {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "identity-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGit = Join-Path $binDir "git.cmd"
    $fakeGitContent = @'
@echo off
if /i "%~1"=="config" if /i "%~2"=="--list" exit /b 0
if /i "%~1"=="config" if /i "%~2"=="--get-regexp" exit /b 1
echo GIT_ARGS:%*
echo GCM_NAMESPACE:%GCM_NAMESPACE%
echo GCM_INTERACTIVE:%GCM_INTERACTIVE%
echo GCM_CREDENTIAL_STORE:%GCM_CREDENTIAL_STORE%
echo GCM_PROVIDER:%GCM_PROVIDER%
echo GCM_GITHUB_AUTHMODES:%GCM_GITHUB_AUTHMODES%
echo GCM_GITLAB_AUTHMODES:%GCM_GITLAB_AUTHMODES%
echo GIT_TERMINAL_PROMPT:%GIT_TERMINAL_PROMPT%
echo GIT_SSH_COMMAND:%GIT_SSH_COMMAND%
echo GIT_SSH_VARIANT:%GIT_SSH_VARIANT%
echo ACCESS:%GIT_ID_ACCESS%
echo TRANSPORT:%GIT_ID_TRANSPORT%
echo HTTPS_PROVIDER:%GIT_ID_HTTPS_PROVIDER%
echo HTTPS_HOST:%GIT_ID_HTTPS_HOST%
echo HTTPS_ACCOUNT:%GIT_ID_HTTPS_ACCOUNT%
echo GIT_CONFIG_PARAMETERS:%GIT_CONFIG_PARAMETERS%
set GIT_CONFIG_KEY_
set GIT_CONFIG_VALUE_
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakeGit, $fakeGitContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    $oldValues = @{}
    foreach ($name in @("GCM_NAMESPACE", "GCM_INTERACTIVE", "GCM_CREDENTIAL_STORE", "GCM_PROVIDER", "GCM_GITHUB_AUTHMODES", "GCM_GITLAB_AUTHMODES", "GIT_TERMINAL_PROMPT", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT")) {
        $oldValues[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
        $env:PATH = "$binDir;$oldPath"
        $env:GCM_NAMESPACE = "inherited-namespace"
        $env:GCM_INTERACTIVE = "true"
        $env:GCM_CREDENTIAL_STORE = "plaintext"
        $env:GCM_PROVIDER = "bitbucket"
        $env:GCM_GITHUB_AUTHMODES = "pat"
        $env:GCM_GITLAB_AUTHMODES = "basic"
        $env:GIT_TERMINAL_PROMPT = "1"
        $env:GIT_SSH_COMMAND = "ssh -F C:\tmp\inherited-ssh-config"
        $env:GIT_SSH_VARIANT = "plink"

        $output = Invoke-Captured $EntryPath @("status") 0 "HTTPS identity injection"
        $entryCommand = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
        $expectedNamespace = Get-ExpectedCredentialNamespace $entryCommand "github" "github.example.com" "github-smoke"

        Assert-True ($output.Contains("GCM_NAMESPACE:$expectedNamespace")) "entry should bind the GCM namespace to the entry and exact HTTPS account."
        Assert-True ($output.Contains("GCM_INTERACTIVE:false")) "ordinary commands should disable implicit GCM interaction."
        Assert-True ($output.Contains("GCM_CREDENTIAL_STORE:wincredman")) "entry should force Windows Credential Manager."
        Assert-True ($output -match '(?m)^GCM_PROVIDER:\r?$') "entry should clear an inherited provider override."
        Assert-True ($output -match '(?m)^GCM_GITHUB_AUTHMODES:\r?$') "entry should clear inherited GitHub auth modes."
        Assert-True ($output -match '(?m)^GCM_GITLAB_AUTHMODES:\r?$') "entry should clear inherited GitLab auth modes."
        Assert-True ($output.Contains("GIT_TERMINAL_PROMPT:0")) "ordinary commands should disable terminal credential prompts."
        Assert-True ($output.Contains("deny-ssh.cmd")) "HTTPS mode should explicitly block inherited SSH access."
        Assert-True (-not $output.Contains("inherited-ssh-config")) "HTTPS mode should not inherit an external SSH command."
        Assert-True ($output.Contains("GIT_SSH_VARIANT:ssh")) "the kit should force OpenSSH semantics instead of inheriting an external variant."
        Assert-True ($output.Contains("ACCESS:https.github:host=github.example.com;account=github-smoke")) "entry should retain the canonical explicit HTTPS descriptor."
        Assert-True ($output.Contains("TRANSPORT:https")) "entry should expose HTTPS as the parsed transport."
        Assert-True ($output.Contains("HTTPS_PROVIDER:github")) "entry should parse the HTTPS provider."
        Assert-True ($output.Contains("HTTPS_HOST:github.example.com")) "entry should parse the HTTPS host."
        Assert-True ($output.Contains("HTTPS_ACCOUNT:github-smoke")) "entry should parse the HTTPS account separately from the credential username."

        $expectedGuard = (Join-Path $repoRoot "_lib\git_identity_kit\https-credential-guard.cmd") -replace '\\', '/'
        $expectedHelper = '!"{0}"' -f $expectedGuard
        Assert-True ($output.Contains("GIT_CONFIG_PARAMETERS:'credential.helper'='' 'credential.helper'='$expectedHelper'")) "entry should reset inherited helpers, then select its guard using shell-safe quoting."
        Assert-InjectedConfigPair $output "transfer.credentialsInUrl" "die" "entry should reject credentials embedded in remote URLs."
        Assert-InjectedConfigPair $output "credential.namespace" $expectedNamespace "entry should inject its account-bound GCM namespace into Git config."
        Assert-InjectedConfigPair $output "credential.credentialStore" "wincredman" "entry should inject the secure Windows credential store."
        Assert-InjectedConfigPair $output "credential.interactive" "false" "entry should make ordinary Git credential access non-interactive."
        Assert-InjectedConfigPair $output "credential.https://github.example.com.provider" "github" "entry should force the provider only for the configured host."
        Assert-InjectedConfigPair $output "credential.https://github.example.com.username" "github-smoke" "entry should bind the single declared HTTPS account."
        Assert-True (-not $output.Contains("credential.https://gitlab.com")) "entry should not inject an unrelated GitLab account."
    } finally {
        $env:PATH = $oldPath
        foreach ($name in $oldValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldValues[$name])
        }
    }
}

function Test-EntryBuildsEffectiveHelperChain {
    param([string]$EntryPath)

    $output = Invoke-Captured $EntryPath @("config", "--get-all", "credential.helper") 0 "effective credential helper chain"
    $lines = @($output.TrimEnd("`r", "`n") -split "`r?`n")
    Assert-True ($lines.Count -ge 2) "effective credential helper chain should contain the reset and guarded GCM proxy entries."
    Assert-True ($lines[$lines.Count - 2] -eq "") "the first managed helper entry should reset inherited helpers."
    Assert-True ($lines[$lines.Count - 1].Contains("https-credential-guard.cmd")) "the guarded GCM proxy should be the only selected helper."
}

function Test-InfoShowsHttpsIdentity {
    param([string]$EntryPath)

    $output = Invoke-Captured $EntryPath @(".info") 0 ".info HTTPS identity"
    $entryCommand = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    $expectedNamespace = Get-ExpectedCredentialNamespace $entryCommand "github" "github.example.com" "github-smoke"
    Assert-True ($output -match '(?m)^Config:\r?$') ".info should start the configured identity section."
    Assert-True ($output -match '(?m)^  Access:[ ]+https\.github\r?$') ".info should show the canonical GitHub HTTPS access tag."
    Assert-True ($output -match '(?m)^  HTTPS authorization:[ ]+GitHub \(github\.example\.com\): not ready') ".info should keep the HTTPS status on one aligned row."
    Assert-True ($output.Contains("$entryCommand .https login")) ".info should show the single explicit HTTPS login command."
    Assert-True (-not $output.Contains("GitLab:")) ".info should not report an unconfigured second provider."
    Assert-True ($output -match "(?m)^  Credential namespace:[ ]+$([regex]::Escape($expectedNamespace))\r?$") ".info should show the exact account-bound credential namespace."
    Assert-True ($output -match '(?m)^Git sees:\r?\n  Name:[ ]+HTTPS Smoke User\r?\n  Email:[ ]+https-smoke@example\.invalid\r?$') "Git diagnostics should retain the aligned name and email labels."
}

function Test-SyncDryRunShowsHttpsBindingWithoutWriting {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--dry-run") 0 "HTTPS .sync dry-run"
        Assert-True ($output.Contains("credential.namespace")) "sync dry-run should show the credential namespace."
        Assert-True ($output.Contains("credential.helper")) "sync dry-run should show the credential helper chain."
        Assert-True ($output.Contains("credential.https://github.example.com.username")) "sync dry-run should show the configured host account binding."
        Assert-True ($output.Contains("swaw-kit-git.access = https.github:host=github.example.com;account=github-smoke")) "sync dry-run should show the single access marker."
        Assert-True (-not $output.Contains("credential.https://gitlab.com")) "sync dry-run should not write an unrelated provider."
    }

    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "credential.namespace")) "sync dry-run should not write the credential namespace."
    Assert-True (@(Get-LocalGitConfigValues $repoPath "credential.helper").Count -eq 0) "sync dry-run should not write credential helpers."
}

function Test-SyncWritesAndClearsHttpsBindingWithoutChangingOrigin {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    $entryCommand = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    $expectedNamespace = Get-ExpectedCredentialNamespace $entryCommand "github" "github.example.com" "github-smoke"
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 "HTTPS .sync"
    }

    $helpers = @(Get-LocalGitConfigValues $repoPath "credential.helper")
    Assert-True ($helpers.Count -eq 2) "sync should write exactly the helper reset and guarded GCM proxy entries."
    Assert-True ($helpers[0] -eq "") "sync should reset lower-priority credential helpers."
    Assert-True ($helpers[1].Contains("https-credential-guard.cmd")) "sync should persist the HTTPS credential guard."
    Assert-True ((Get-LocalGitConfig $repoPath "credential.namespace") -eq $expectedNamespace) "sync should persist the account-bound entry namespace."
    Assert-True ((Get-LocalGitConfig $repoPath "credential.credentialStore") -eq "wincredman") "sync should persist Windows Credential Manager."
    Assert-True ((Get-LocalGitConfig $repoPath "credential.interactive") -eq "false") "sync should prevent implicit browser login in external tools."
    Assert-True ((Get-LocalGitConfig $repoPath "credential.https://github.example.com.provider") -eq "github") "sync should persist the configured provider."
    Assert-True ((Get-LocalGitConfig $repoPath "credential.https://github.example.com.username") -eq "github-smoke") "sync should persist the configured account user."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "credential.https://gitlab.com.provider")) "sync should not persist an unrelated provider."
    Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.access") -eq "https.github:host=github.example.com;account=github-smoke") "sync should record the single access descriptor."
    Assert-True ((Get-LocalGitConfig $repoPath "core.sshCommand").Contains("deny-ssh.cmd")) "HTTPS sync should make SSH remotes fail closed."
    Assert-True ((Get-LocalGitConfig $repoPath "remote.origin.url") -eq "https://github.com/example/example.git") "sync should never modify origin."

    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync", "--clear") 0 "HTTPS .sync clear"
    }

    Assert-True (@(Get-LocalGitConfigValues $repoPath "credential.helper").Count -eq 0) "sync clear should remove the unchanged helper chain."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "credential.namespace")) "sync clear should remove the unchanged namespace."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "credential.https://github.example.com.username")) "sync clear should remove the unchanged HTTPS account."
    Assert-True ((Get-LocalGitConfig $repoPath "remote.origin.url") -eq "https://github.com/example/example.git") "sync clear should not modify origin."
}

function Test-SyncClearRefusesChangedHelperChain {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 "HTTPS .sync before helper change"
        git config --local --unset-all credential.helper
        git config --local --add credential.helper "manager-core"
        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "HTTPS .sync clear changed helper"
        Assert-True ($output.Contains("Refusing to clear")) "sync clear should refuse a changed credential helper chain."
    }

    Assert-True ((Get-LocalGitConfig $repoPath "credential.helper") -eq "manager-core") "refused clear should preserve the changed helper."
    Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.managed") -eq "true") "refused clear should preserve the sync marker."
}

function Test-SyncReplacesChangedHttpsHostWithoutLeavingStaleBindings {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    $entryCommand = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    try {
        Invoke-InDirectory $repoPath {
            $null = Invoke-Captured $EntryPath @(".sync") 0 "initial HTTPS host sync"
        }

        Set-HttpsSmokeAccess $EntryPath "https.gitlab:host=gitlab.example.com;account=gitlab-smoke"
        Invoke-InDirectory $repoPath {
            $null = Invoke-Captured $EntryPath @(".sync") 0 "changed HTTPS host sync"
        }

        Assert-True ($null -eq (Get-LocalGitConfig $repoPath "credential.https://github.example.com.provider")) "sync should remove the stale provider key for the old host."
        Assert-True ($null -eq (Get-LocalGitConfig $repoPath "credential.https://github.example.com.username")) "sync should remove the stale username key for the old host."
        Assert-True ((Get-LocalGitConfig $repoPath "credential.https://gitlab.example.com.provider") -eq "gitlab") "sync should write the new host provider."
        Assert-True ((Get-LocalGitConfig $repoPath "credential.https://gitlab.example.com.username") -eq "oauth2") "GitLab OAuth should persist its credential protocol username."
        $expectedNamespace = Get-ExpectedCredentialNamespace $entryCommand "gitlab" "gitlab.example.com" "gitlab-smoke"
        Assert-True ((Get-LocalGitConfig $repoPath "credential.namespace") -eq $expectedNamespace) "changing the account should move external tools to a new credential namespace."
        Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.access") -eq "https.gitlab:host=gitlab.example.com;account=gitlab-smoke") "sync should replace the access marker."
    } finally {
        Set-HttpsSmokeAccess $EntryPath "https.github:host=github.example.com;account=github-smoke"
    }
}

function Test-InvalidHttpsDescriptorFailsBeforeGitDispatch {
    param([string]$EntryPath)

    foreach ($invalidAccess in @(
        "github:host=github.example.com;account=github-smoke",
        "gitlab:host=gitlab.example.com;account=gitlab-smoke",
        "https:host=github.example.com;account=github-smoke",
        "https.bitbucket:host=bitbucket.example.com;account=bitbucket-smoke",
        "https.github:github.example.com/github-smoke",
        "https.github:host=github.example.com/account=github-smoke",
        "https.github:account=github-smoke;host=github.example.com",
        "https.github:host=;account=github-smoke",
        "https.github:host=github.example.com;account=",
        "https.github:host=github.example.com;user=github-smoke",
        "https.github:host=github.example.com;;account=github-smoke",
        "https.github:host=github.example.com;account=github-smoke;",
        "https.github:host=github.example.com;account=github-smoke;extra=value"
    )) {
        try {
            Set-HttpsSmokeAccess $EntryPath $invalidAccess
            $output = Invoke-Captured $EntryPath @("status") 1 "invalid HTTPS descriptor rejection"
            Assert-True ($output.Contains("https.github:host=HOST;account=ACCOUNT")) "invalid access diagnostics should show the canonical explicit HTTPS formats."
        } finally {
            Set-HttpsSmokeAccess $EntryPath "https.github:host=github.example.com;account=github-smoke"
        }
    }

    try {
        Set-HttpsSmokeAccess $EntryPath "host=github.example.com;account=github-smoke"
        $output = Invoke-Captured $EntryPath @("status") 1 "invalid HTTPS account descriptor"
        Assert-True ($output.Contains("GIT_ID_ACCESS")) "invalid access diagnostics should name the entry setting."
        Assert-True ($output.Contains("ssh:command")) "invalid access diagnostics should show all supported formats."
    } finally {
        Set-HttpsSmokeAccess $EntryPath "https.github:host=github.example.com;account=github-smoke"
    }

    try {
        Set-HttpsSmokeAccess $EntryPath ""
        $output = Invoke-Captured $EntryPath @(".https", "login") 1 "missing HTTPS account login"
        Assert-True ($output.Contains("Set GIT_ID_ACCESS")) "missing access diagnostics should identify the required setting."
    } finally {
        Set-HttpsSmokeAccess $EntryPath "https.github:host=github.example.com;account=github-smoke"
    }
}

function Test-HttpsLoginCommandDispatchesParsedAccount {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "login-dispatch-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakePowerShell = Join-Path $binDir "PowerShell.cmd"
    $fakePowerShellContent = @'
@echo off
echo POWERSHELL_ARGS:%*
echo LOGIN_NAMESPACE:%GIT_ID_CREDENTIAL_NAMESPACE%
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakePowerShell, $fakePowerShellContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $entryCommand = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
        $expectedNamespace = Get-ExpectedCredentialNamespace $entryCommand "github" "github.example.com" "github-smoke"

        $loginOutput = Invoke-Captured $EntryPath @(".https", "login") 0 ".https login dispatch"
        Assert-True ($loginOutput.Contains("https-auth.ps1")) ".https login should dispatch to https-auth.ps1."
        Assert-True ($loginOutput -match '-Provider\s+"?github"?') ".https login should pass the parsed provider."
        Assert-True ($loginOutput -match '-AccountHost\s+"?github\.example\.com"?') ".https login should pass the parsed host."
        Assert-True ($loginOutput -match '-ExpectedAccount\s+"?github-smoke"?') ".https login should pass the parsed platform account."
        Assert-True ($loginOutput -match ('-Namespace\s+"?' + [regex]::Escape($expectedNamespace) + '"?')) ".https login should pass the exact account-bound namespace."

        $invalidOutput = Invoke-Captured $EntryPath @(".https", "login", "extra") 1 ".https login extra argument"
        Assert-True (-not $invalidOutput.Contains("POWERSHELL_ARGS")) "invalid login arguments should be rejected before PowerShell dispatch."
    } finally {
        $env:PATH = $oldPath
    }
}

function Test-HelpDocumentsOriginUrlRewriteCommands {
    $zhHelp = [System.IO.File]::ReadAllText((Join-Path $repoRoot "_lib\git_identity_kit\help\zh-CN.txt"))
    $enHelp = [System.IO.File]::ReadAllText((Join-Path $repoRoot "_lib\git_identity_kit\help\en.txt"))

    foreach ($help in @($zhHelp, $enHelp)) {
        Assert-True ($help.Contains("{{COMMAND}} .https login")) "help should document the single explicit HTTPS login command."
        Assert-True ($help.Contains("{{COMMAND}} .origin ssh")) "help should document the provider-independent SSH URL rewrite command."
        Assert-True ($help.Contains("{{COMMAND}} .origin https")) "help should document the provider-independent HTTPS URL rewrite command."
        Assert-True ($help.Contains("SSH/HTTPS")) "help should state that .sync persists remote access routing for external Git tools."
    }
    Assert-True ($zhHelp.Contains("{{COMMAND}} .origin ssh")) "Chinese help should document SSH conversion."
    Assert-True ($zhHelp.Contains("{{COMMAND}} .origin https")) "Chinese help should document HTTPS conversion."
    Assert-True ($enHelp.Contains("Rewrite the origin URL as git@host:path.git.")) "English help should describe SSH as URL-only rewriting."
    Assert-True ($enHelp.Contains("Rewrite the origin URL as https://host/path.git.")) "English help should describe HTTPS as URL-only rewriting."
    Assert-True ($enHelp.Contains("identity and credentials are unchanged")) "English help should state that .origin does not change identity or credentials."
}

$tempRoot = Join-Path $tempBase ("git-id-https-smoke-" + [guid]::NewGuid().ToString("N"))
$smokeEntry = $null
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Test-EntryTemplateDeclaresOneAccessDescriptor
    Test-CredentialNamespaceIsUnambiguous
    $smokeEntry = New-HttpsSmokeEntry $tempRoot
    Test-EntryInjectsAuthoritativeHttpsIdentity $smokeEntry $tempRoot
    Test-EntryBuildsEffectiveHelperChain $smokeEntry
    Test-InfoShowsHttpsIdentity $smokeEntry
    Test-SyncDryRunShowsHttpsBindingWithoutWriting $smokeEntry $tempRoot
    Test-SyncWritesAndClearsHttpsBindingWithoutChangingOrigin $smokeEntry $tempRoot
    Test-SyncClearRefusesChangedHelperChain $smokeEntry $tempRoot
    Test-SyncReplacesChangedHttpsHostWithoutLeavingStaleBindings $smokeEntry $tempRoot
    Test-InvalidHttpsDescriptorFailsBeforeGitDispatch $smokeEntry
    Test-HttpsLoginCommandDispatchesParsedAccount $smokeEntry $tempRoot
    Test-HelpDocumentsOriginUrlRewriteCommands
} finally {
    if ($smokeEntry -and (Test-Path -LiteralPath $smokeEntry)) {
        Remove-Item -LiteralPath $smokeEntry -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
