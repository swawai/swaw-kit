[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$kitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $kitRoot "..\.."))
$authScript = Join-Path $kitRoot "https-auth.ps1"
$tempBase = Join-Path $repoRoot "temp_workspace"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Script,
        [string]$MessagePattern,
        [string]$Label
    )

    try {
        & $Script
    } catch {
        $message = $_.Exception.Message
        if ($message -notmatch $MessagePattern) {
            throw "$Label failed with an unexpected message: $message"
        }
        return $message
    }
    throw "$Label should have failed."
}

function New-FakeGcm {
    param([string]$TempRoot)

    $binDir = Join-Path $TempRoot "gcm-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGit = Join-Path $binDir "git.cmd"
    $fakeGitScript = Join-Path $binDir "fake-git.ps1"

    $cmd = @'
@echo off
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-git.ps1" %*
exit /b %ERRORLEVEL%
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakeGit, $cmd, [System.Text.UTF8Encoding]::new($false))

    $script = @'
$ErrorActionPreference = "Stop"
$commandLine = $args -join " "
$logLine = "ARGS=$commandLine|NAMESPACE=$env:GCM_NAMESPACE|INTERACTIVE=$env:GCM_INTERACTIVE|STORE=$env:GCM_CREDENTIAL_STORE|PROVIDER=$env:GCM_PROVIDER|GH_MODES=$env:GCM_GITHUB_AUTHMODES|GL_MODES=$env:GCM_GITLAB_AUTHMODES|TRACE_SECRETS=$env:GCM_TRACE_SECRETS|TERMINAL_PROMPT=$env:GIT_TERMINAL_PROMPT"
Add-Content -LiteralPath $env:FAKE_GCM_LOG -Value $logLine -Encoding UTF8

if ($args.Count -ge 2 -and $args[0] -eq "credential-manager" -and $args[1] -eq "--version") {
    Write-Output "2.6.1"
    exit 0
}
if ($args.Count -ge 3 -and $args[0] -eq "credential-manager" -and $args[1] -eq "github" -and $args[2] -eq "list") {
    if (Test-Path -LiteralPath $env:FAKE_GCM_STATE) {
        Get-Content -LiteralPath $env:FAKE_GCM_STATE
    }
    exit 0
}
if ($args.Count -ge 4 -and $args[0] -eq "credential-manager" -and $args[1] -eq "github" -and $args[2] -eq "logout") {
    Remove-Item -LiteralPath $env:FAKE_GCM_STATE -Force -ErrorAction SilentlyContinue
    exit 0
}
if ($args.Count -ge 3 -and $args[0] -eq "credential-manager" -and $args[1] -eq "github" -and $args[2] -eq "login") {
    if ($env:FAKE_GITHUB_LOGIN_EXIT -eq "1") {
        Write-Error "Browser login was cancelled."
        exit 1
    }
    Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value $env:FAKE_GITHUB_LOGIN_ACCOUNT -Encoding UTF8
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "credential-manager" -and $args[1] -eq "erase") {
    $null = $input | Out-String
    Remove-Item -LiteralPath $env:FAKE_GCM_STATE -Force -ErrorAction SilentlyContinue
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "credential-manager" -and $args[1] -eq "get") {
    $null = $input | Out-String
    if (Test-Path -LiteralPath $env:FAKE_GCM_STATE) {
        $password = (Get-Content -LiteralPath $env:FAKE_GCM_STATE -Raw).Trim()
    } elseif ($env:FAKE_GCM_GET_EXIT -eq "1" -or $env:GCM_INTERACTIVE -eq "false") {
        Write-Error "No credential available."
        exit 1
    } else {
        $password = $env:FAKE_GITLAB_PASSWORD
        Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value $password -Encoding UTF8
    }
    Write-Output "username=oauth2"
    Write-Output "password=$password"
    Write-Output ""
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "credential-manager" -and $args[1] -eq "store") {
    $request = $input | Out-String
    $passwordLine = @($request -split "`r?`n" | Where-Object { $_ -like "password=*" }) | Select-Object -First 1
    if (-not $passwordLine) {
        Write-Error "Stored credential has no password."
        exit 1
    }
    Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value $passwordLine.Substring(9) -Encoding UTF8
    exit 0
}

Write-Error "Unexpected fake git call: $commandLine"
exit 1
'@
    [System.IO.File]::WriteAllText($fakeGitScript, $script, [System.Text.UTF8Encoding]::new($false))
    return $binDir
}

function Invoke-WithFakeGcm {
    param(
        [string]$TempRoot,
        [scriptblock]$Script
    )

    $binDir = New-FakeGcm $TempRoot
    $oldPath = $env:PATH
    $oldValues = @{}
    foreach ($name in @("FAKE_GCM_LOG", "FAKE_GCM_STATE", "FAKE_GCM_GET_EXIT", "FAKE_GITHUB_LOGIN_ACCOUNT", "FAKE_GITHUB_LOGIN_EXIT", "FAKE_GITLAB_PASSWORD", "GCM_NAMESPACE", "GCM_INTERACTIVE", "GCM_CREDENTIAL_STORE", "GCM_PROVIDER", "GCM_GITHUB_AUTHMODES", "GCM_GITLAB_AUTHMODES", "GCM_TRACE", "GCM_TRACE_SECRETS", "GIT_TERMINAL_PROMPT")) {
        $oldValues[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
        $env:PATH = "$binDir;$oldPath"
        $env:FAKE_GCM_LOG = Join-Path $TempRoot "gcm.log"
        $env:FAKE_GCM_STATE = Join-Path $TempRoot "gcm.state"
        $env:FAKE_GCM_GET_EXIT = ""
        $env:FAKE_GITHUB_LOGIN_EXIT = ""
        $env:FAKE_GITLAB_PASSWORD = "fixture-credential-value"
        $env:GCM_NAMESPACE = "inherited-namespace"
        $env:GCM_INTERACTIVE = "false"
        $env:GCM_CREDENTIAL_STORE = "plaintext"
        $env:GCM_PROVIDER = "bitbucket"
        $env:GCM_GITHUB_AUTHMODES = "pat"
        $env:GCM_GITLAB_AUTHMODES = "basic"
        $env:GCM_TRACE = "1"
        $env:GCM_TRACE_SECRETS = "true"
        $env:GIT_TERMINAL_PROMPT = "1"
        & $Script
    } finally {
        $env:PATH = $oldPath
        foreach ($name in $oldValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldValues[$name])
        }
    }
}

. $authScript

function Test-LoginRequiresDeclaredAccount {
    Assert-Throws { Invoke-HttpsLogin -Provider github -AccountHost "github.example.com" -ExpectedUser "" -Namespace "swaw-kit-git.test" } "GIT_ID_ACCESS" "missing HTTPS account" | Out-Null
}

function Test-GitHubLoginAcceptsOnlyExactAccount {
    param([string]$TempRoot)

    Invoke-WithFakeGcm $TempRoot {
        $env:FAKE_GITHUB_LOGIN_ACCOUNT = "github-smoke"
        $output = @(Invoke-HttpsLogin -Provider github -AccountHost "github.example.com" -ExpectedUser "github-smoke" -Namespace "swaw-kit-git.git1" 6>&1) -join "`n"
        Assert-True ($output -eq "[OK] GitHub HTTPS authorization ready: github.example.com/github-smoke") "GitHub login should return one concise success status."
        Assert-True ((Get-Content -LiteralPath $env:FAKE_GCM_STATE -Raw).Trim() -eq "github-smoke") "GitHub login should retain the exact expected account."
        $log = Get-Content -LiteralPath $env:FAKE_GCM_LOG -Raw
        Assert-True ($log.Contains("NAMESPACE=swaw-kit-git.git1")) "GitHub login should override the credential namespace."
        Assert-True ($log.Contains("INTERACTIVE=true")) "explicit GitHub login should enable GCM interaction."
        Assert-True ($log.Contains("STORE=wincredman")) "GitHub login should force Windows Credential Manager."
        Assert-True ($log.Contains("PROVIDER=github")) "GitHub login should force the GitHub provider."
        Assert-True ($log.Contains("GH_MODES=browser")) "GitHub login should force browser authentication."
        Assert-True ($log.Contains("TRACE_SECRETS=false")) "GitHub login should disable secret tracing."
        Assert-True ($log.Contains("--url https://github.example.com")) "GitHub login should scope GCM to the configured host."

        $env:FAKE_GITHUB_LOGIN_ACCOUNT = "wrong-account"
        $message = Assert-Throws { Invoke-HttpsLogin -Provider github -AccountHost "github.example.com" -ExpectedUser "github-smoke" -Namespace "swaw-kit-git.git1" } "authorized 'wrong-account'.*expected 'github-smoke'" "GitHub account mismatch"
        Assert-True (-not (Test-Path -LiteralPath $env:FAKE_GCM_STATE)) "GitHub mismatch should clear the rejected account."
        Assert-True (-not $message.Contains($env:FAKE_GITLAB_PASSWORD)) "GitHub mismatch diagnostics should not contain credentials."

        Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value "github-smoke" -Encoding UTF8
        $env:FAKE_GITHUB_LOGIN_EXIT = "1"
        Assert-Throws { Invoke-HttpsLogin -Provider github -AccountHost "github.example.com" -ExpectedUser "github-smoke" -Namespace "swaw-kit-git.git1" 2>$null } "failed with exit code" "cancelled GitHub login" | Out-Null
        Assert-True ((Get-Content -LiteralPath $env:FAKE_GCM_STATE -Raw).Trim() -eq "github-smoke") "cancelled GitHub login should preserve the previous account."
    }
}

function Test-GitLabLoginVerifiesTokenOwnerAndCleansMismatch {
    param([string]$TempRoot)

    Invoke-WithFakeGcm $TempRoot {
        $successRequest = {
            param([uri]$Uri, [hashtable]$Headers)
            Assert-True ($Uri.Host -eq "gitlab.example.com") "GitLab verification should use the configured host."
            Assert-True ($Uri.AbsolutePath -eq "/api/v4/user") "GitLab verification should query the authenticated current-user endpoint."
            Assert-True ($Headers.Authorization -eq "Bearer fixture-credential-value") "current-user lookup should receive the OAuth credential only in the authorization header."
            return [pscustomobject]@{ id = 42; username = "gitlab-smoke" }
        }
        $output = @(Invoke-HttpsLogin -Provider gitlab -AccountHost "gitlab.example.com" -ExpectedUser "gitlab-smoke" -Namespace "swaw-kit-git.git1" -RestInvoker $successRequest 6>&1) -join "`n"
        Assert-True ($output -eq "[OK] GitLab HTTPS authorization ready: gitlab.example.com/gitlab-smoke") "GitLab login should return one concise success status."
        Assert-True ((Get-Content -LiteralPath $env:FAKE_GCM_STATE -Raw).Trim() -eq "fixture-credential-value") "verified GitLab login should retain the OAuth credential."

        $mismatchRequest = {
            param([uri]$Uri, [hashtable]$Headers)
            return [pscustomobject]@{ id = 99; username = "wrong-account" }
        }
        $message = Assert-Throws { Invoke-HttpsLogin -Provider gitlab -AccountHost "gitlab.example.com" -ExpectedUser "gitlab-smoke" -Namespace "swaw-kit-git.git1" -RestInvoker $mismatchRequest } "does not belong to 'gitlab-smoke'" "GitLab account mismatch"
        Assert-True ((Get-Content -LiteralPath $env:FAKE_GCM_STATE -Raw).Trim() -eq "fixture-credential-value") "GitLab mismatch should restore the previous credential after rejecting the new login."
        Assert-True (-not $message.Contains($env:FAKE_GITLAB_PASSWORD)) "GitLab mismatch diagnostics should not contain the OAuth credential."
        $log = Get-Content -LiteralPath $env:FAKE_GCM_LOG -Raw
        Assert-True ($log.Contains("ARGS=credential-manager erase")) "GitLab mismatch should delegate credential cleanup to GCM."
        Assert-True ($log.Contains("ARGS=credential-manager store")) "GitLab mismatch should restore the previous credential through GCM."
        Assert-True ($log.Contains("PROVIDER=gitlab")) "GitLab login should force the GitLab provider."
        Assert-True ($log.Contains("GL_MODES=browser")) "GitLab login should force browser authentication."
    }
}

function Test-GitHubStatusReportsReadyAndMismatchWithoutInteraction {
    param([string]$TempRoot)

    Invoke-WithFakeGcm $TempRoot {
        Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value "github-smoke" -Encoding UTF8
        $status = Invoke-HttpsStatus -Provider github -AccountHost "github.example.com" -ExpectedUser "github-smoke" -Namespace "swaw-kit-git.git1" -CommandName "git1"
        Assert-True ($status -eq "  GitHub (github.example.com): stored (github-smoke)") "GitHub status should distinguish a stored account from a live-verified credential."

        Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value "wrong-account" -Encoding UTF8
        $status = Invoke-HttpsStatus -Provider github -AccountHost "github.example.com" -ExpectedUser "github-smoke" -Namespace "swaw-kit-git.git1" -CommandName "git1"
        Assert-True ($status.Contains("GitHub (github.example.com): mismatch")) "GitHub status should report an account mismatch."
        Assert-True ($status.Contains("stored: wrong-account; expected: github-smoke")) "GitHub mismatch should identify the stored and expected accounts."

        $log = Get-Content -LiteralPath $env:FAKE_GCM_LOG -Raw
        Assert-True ($log.Contains("INTERACTIVE=false")) "status checks should disable GCM interaction."
        Assert-True ($log.Contains("TRACE_SECRETS=false")) "status checks should disable secret tracing."
        Assert-True ($log.Contains("TERMINAL_PROMPT=0")) "status checks should disable Git terminal prompts."
        Assert-True (-not $log.Contains("github login")) "GitHub status should never start a login."
    }
}

function Test-GitLabStatusVerifiesOwnerWithoutExposingCredential {
    param([string]$TempRoot)

    Invoke-WithFakeGcm $TempRoot {
        Set-Content -LiteralPath $env:FAKE_GCM_STATE -Value "fixture-credential-value" -Encoding UTF8
        $successRequest = {
            param([uri]$Uri, [hashtable]$Headers)
            Assert-True ($Uri.Host -eq "gitlab.example.com") "GitLab status should use the configured host."
            Assert-True ($Uri.AbsolutePath -eq "/api/v4/user") "GitLab status should query the authenticated current-user endpoint."
            Assert-True ($Headers.Authorization -eq "Bearer fixture-credential-value") "status should use the OAuth credential only for owner verification."
            return [pscustomobject]@{ id = 42; username = "gitlab-smoke" }
        }

        $status = Invoke-HttpsStatus -Provider gitlab -AccountHost "gitlab.example.com" -ExpectedUser "gitlab-smoke" -Namespace "swaw-kit-git.git1" -CommandName "git1" -RestInvoker $successRequest
        Assert-True ($status -eq "  GitLab (gitlab.example.com): ready (gitlab-smoke)") "GitLab status should report a credential verified for the expected account."
        Assert-True (-not $status.Contains($env:FAKE_GITLAB_PASSWORD)) "GitLab status should never expose the OAuth credential."

        $mismatchRequest = {
            param([uri]$Uri, [hashtable]$Headers)
            return [pscustomobject]@{ id = 99; username = "wrong-account" }
        }
        $status = Invoke-HttpsStatus -Provider gitlab -AccountHost "gitlab.example.com" -ExpectedUser "gitlab-smoke" -Namespace "swaw-kit-git.git1" -CommandName "git1" -RestInvoker $mismatchRequest
        Assert-True ($status.Contains("GitLab (gitlab.example.com): mismatch")) "GitLab status should report a credential owned by another account."
        Assert-True (-not $status.Contains($env:FAKE_GITLAB_PASSWORD)) "GitLab mismatch diagnostics should never expose the OAuth credential."

        Remove-Item -LiteralPath $env:FAKE_GCM_STATE -Force
        $env:FAKE_GCM_GET_EXIT = "1"
        $status = Invoke-HttpsStatus -Provider gitlab -AccountHost "gitlab.example.com" -ExpectedUser "gitlab-smoke" -Namespace "swaw-kit-git.git1" -CommandName "git1" -RestInvoker $successRequest
        Assert-True ($status.Contains('GitLab (gitlab.example.com): not ready (run "git1 .https login")')) "GitLab status should show the single explicit recovery command when no credential is available."
        Assert-True (-not $status.Contains($env:FAKE_GITLAB_PASSWORD)) "missing-credential diagnostics should never expose the OAuth credential."

        $log = Get-Content -LiteralPath $env:FAKE_GCM_LOG -Raw
        Assert-True (-not $log.Contains("ARGS=credential-manager erase")) "status checks should never erase credentials."
    }
}

$tempRoot = Join-Path $tempBase ("git-id-https-login-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Test-LoginRequiresDeclaredAccount
    Test-GitHubLoginAcceptsOnlyExactAccount (Join-Path $tempRoot "github")
    Test-GitLabLoginVerifiesTokenOwnerAndCleansMismatch (Join-Path $tempRoot "gitlab")
    Test-GitHubStatusReportsReadyAndMismatchWithoutInteraction (Join-Path $tempRoot "github-status")
    Test-GitLabStatusVerifiesOwnerWithoutExposingCredential (Join-Path $tempRoot "gitlab-status")
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
