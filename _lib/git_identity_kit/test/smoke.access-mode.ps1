[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryTemplate = Join-Path $repoRoot "git1.cmd"
$tempBase = Join-Path $repoRoot "temp_workspace"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Captured {
    param([string]$File, [string[]]$Arguments, [int]$ExpectedExitCode, [string]$Label)

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = (& $File @Arguments 2>&1 | Out-String -Width 4096)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "$Label failed: expected exit code $ExpectedExitCode, got $exitCode.`n$output"
    }
    return $output
}

function New-AccessEntry {
    param(
        [string]$Access,
        [string]$EntryRoot
    )

    $name = "git.access-smoke-" + [guid]::NewGuid().ToString("N")
    New-Item -ItemType Directory -Path $EntryRoot -Force | Out-Null
    $path = Join-Path $EntryRoot "$name.cmd"
    $content = [IO.File]::ReadAllText($entryTemplate)
    $pattern = '(?m)^set "GIT_ID_ACCESS=.*"\r?$'
    Assert-True ($content -match $pattern) "entry template should declare GIT_ID_ACCESS."
    $content = [regex]::Replace($content, $pattern, ('set "GIT_ID_ACCESS=' + $Access + '"'))
    $kitPath = Join-Path $repoRoot "_lib\git_identity_kit\kit.cmd"
    $content = [regex]::Replace($content, '(?m)^set "GIT_ID_KIT=.*"\r?$', [Text.RegularExpressions.MatchEvaluator]{ param($match) 'set "GIT_ID_KIT=' + $kitPath + '"' })
    $content = $content -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
    return $path
}

function Assert-InjectedConfigPair {
    param([string]$Output, [string]$Key, [string]$Value, [string]$Message)

    $keyPattern = '(?m)^GIT_CONFIG_KEY_(\d+)=' + [regex]::Escape($Key) + '\r?$'
    foreach ($match in [regex]::Matches($Output, $keyPattern)) {
        $index = $match.Groups[1].Value
        if ($Output -match ('(?m)^GIT_CONFIG_VALUE_' + $index + '=' + [regex]::Escape($Value) + '\r?$')) {
            return
        }
    }
    throw $Message
}

function Set-EntryAccess {
    param([string]$EntryPath, [string]$Access)

    $content = [IO.File]::ReadAllText($EntryPath)
    $content = [regex]::Replace($content, '(?m)^set "GIT_ID_ACCESS=.*"\r?$', ('set "GIT_ID_ACCESS=' + $Access + '"'))
    $content = $content -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($EntryPath, $content, [Text.UTF8Encoding]::new($false))
}

function Get-LocalValues {
    param([string]$RepoPath, [string]$Key)

    Push-Location $RepoPath
    try {
        $values = @(& git config --local --get-all $Key 2>$null)
        if ($LASTEXITCODE -ne 0) { return @() }
        return $values
    } finally {
        Pop-Location
    }
}

function Test-HttpsModeRejectsSshTransport {
    param([string]$EntryPath)

    $output = Invoke-Captured $EntryPath @("ls-remote", "ssh://git@example.invalid/acme/widget.git") 128 "HTTPS mode SSH rejection"
    Assert-True ($output.Contains("configured for HTTPS access; SSH access is disabled")) "HTTPS mode should fail through its explicit SSH blocker."
}

function Test-SshModeRejectsHttpsCredentials {
    param([string]$EntryPath, [string]$TempRoot)

    $binDir = Join-Path $TempRoot "ssh-mode-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGit = @'
@echo off
if /i "%~1"=="config" if /i "%~2"=="--list" exit /b 0
if /i "%~1"=="config" if /i "%~2"=="--get-regexp" exit /b 1
echo ASKPASS:%GIT_ASKPASS%
echo CONFIG:%GIT_CONFIG_PARAMETERS%
set GIT_CONFIG_KEY_
set GIT_CONFIG_VALUE_
echo GCM_NAMESPACE:%GCM_NAMESPACE%
echo GCM_STORE:%GCM_CREDENTIAL_STORE%
echo EXEC_PATH:%GIT_EXEC_PATH%
echo SSL_CERT:%GIT_SSL_CERT%
'@ -replace "`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path $binDir "git.cmd"), $fakeGit, [Text.UTF8Encoding]::new($false))
    $oldAskPass = $env:GIT_ASKPASS
    $oldPath = $env:PATH
    $oldNamespace = $env:GCM_NAMESPACE
    $oldStore = $env:GCM_CREDENTIAL_STORE
    $oldExecPath = $env:GIT_EXEC_PATH
    $oldSslCert = $env:GIT_SSL_CERT
    try {
        $env:GIT_ASKPASS = "C:\tmp\inherited-askpass.cmd"
        $env:GCM_NAMESPACE = "inherited-namespace"
        $env:GCM_CREDENTIAL_STORE = "plaintext"
        $env:GIT_EXEC_PATH = "C:\tmp\inherited-git-exec"
        $env:GIT_SSL_CERT = "C:\tmp\inherited-client-identity.p12"
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @("status") 0 "SSH credential boundary"
        Assert-True ($output.Contains("deny-credential-prompt.cmd")) "SSH mode should install its explicit credential blocker."
        Assert-True (-not $output.Contains("inherited-askpass")) "SSH mode should not inherit an external GIT_ASKPASS."
        Assert-True ($output.Contains("CONFIG:'credential.helper'=''")) "SSH mode should reset inherited credential helpers."
        Assert-InjectedConfigPair $output "transfer.credentialsInUrl" "die" "SSH mode should reject credentials embedded in HTTPS URLs."
        Assert-True (-not $output.Contains("https-credential-guard.cmd")) "SSH mode should not enable the HTTPS credential guard."
        Assert-True ($output -match '(?m)^GCM_NAMESPACE:\r?$') "SSH mode should clear an inherited GCM namespace."
        Assert-True ($output -match '(?m)^GCM_STORE:\r?$') "SSH mode should clear an inherited GCM credential store."
        Assert-True ($output -match '(?m)^EXEC_PATH:\r?$') "entry should clear an inherited Git executable search path."
        Assert-True ($output -match '(?m)^SSL_CERT:\r?$') "entry should clear an inherited HTTPS client certificate identity."

        $login = Invoke-Captured $EntryPath @(".https", "login") 1 "SSH mode HTTPS login rejection"
        Assert-True ($login.Contains("requires HTTPS access")) ".https login should reject an SSH access entry clearly."
    } finally {
        $env:GIT_ASKPASS = $oldAskPass
        $env:PATH = $oldPath
        $env:GCM_NAMESPACE = $oldNamespace
        $env:GCM_CREDENTIAL_STORE = $oldStore
        $env:GIT_EXEC_PATH = $oldExecPath
        $env:GIT_SSL_CERT = $oldSslCert
    }
}

function Test-EntryPreservesLiteralArguments {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = Join-Path $TempRoot "argument-repo"
    New-Item -ItemType Directory -Path $repoPath | Out-Null
    & git -C $repoPath init --quiet
    Assert-True ($LASTEXITCODE -eq 0) "argument forwarding repository should initialize."

    $literal = '100%PATH% !bang! ^caret & (括号) 中文.txt'
    [IO.File]::WriteAllText((Join-Path $repoPath $literal), "argument fixture", [Text.UTF8Encoding]::new($false))
    $callerPath = Join-Path $TempRoot "argument-caller.cmd"
    $entryCommand = '"' + $EntryPath + '" hash-object -- "100%%PATH%% !bang! ^caret & (括号) 中文.txt"'
    $caller = "@echo off & chcp 65001 >nul <nul & setlocal DisableDelayedExpansion`r`n$entryCommand`r`n"
    [IO.File]::WriteAllText($callerPath, $caller, [Text.UTF8Encoding]::new($false))
    Push-Location $repoPath
    try {
        $output = Invoke-Captured $callerPath @() 0 "literal argument forwarding"
    } finally {
        Pop-Location
    }
    Assert-True ($output.Trim() -match '^[0-9a-f]{40,64}$') "Git should receive the exact single filename argument, including percent, bang, caret, ampersand, parentheses, spaces, and Unicode. Output: $output"
}

function Test-HiddenHttpsAuthorizationIsRejected {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = Join-Path $TempRoot "authorization-boundary-repo"
    New-Item -ItemType Directory -Path $repoPath | Out-Null
    & git -C $repoPath init --quiet
    Assert-True ($LASTEXITCODE -eq 0) "authorization boundary repository should initialize."

    & git -C $repoPath config --local http.extraHeader "Authorization: Bearer generic-hidden-token"
    Assert-True ($LASTEXITCODE -eq 0) "generic authorization header fixture should be configured."
    Push-Location $repoPath
    try {
        $output = Invoke-Captured $EntryPath @("status") 1 "generic Authorization extraHeader rejection"
    } finally {
        Pop-Location
    }
    Assert-True ($output.Contains("hidden HTTPS authorization")) "entry should reject a generic Authorization extraHeader before Git dispatch."
    Assert-True (-not $output.Contains("generic-hidden-token")) "authorization boundary diagnostics should not expose generic header secrets."

    & git -C $repoPath config --local --unset-all http.extraHeader
    & git -C $repoPath config --local http.https://github.example.com/.extraHeader "Authorization: Bearer scoped-hidden-token"
    Push-Location $repoPath
    try {
        $output = Invoke-Captured $EntryPath @("status") 1 "URL-scoped Authorization extraHeader rejection"
    } finally {
        Pop-Location
    }
    Assert-True ($output.Contains("hidden HTTPS authorization")) "entry should also reject a URL-scoped Authorization extraHeader."
    Assert-True (-not $output.Contains("scoped-hidden-token")) "authorization boundary diagnostics should not expose URL-scoped header secrets."

    & git -C $repoPath config --local --unset-all http.https://github.example.com/.extraHeader
    & git -C $repoPath config --local http.extraHeader "PRIVATE-TOKEN: alternate-hidden-token"
    Push-Location $repoPath
    try {
        $output = Invoke-Captured $EntryPath @("status") 1 "non-Authorization authentication header rejection"
    } finally {
        Pop-Location
    }
    Assert-True ($output.Contains("hidden HTTPS authorization")) "entry should reject arbitrary nonempty HTTP headers because providers may use non-Authorization token names."
    Assert-True (-not $output.Contains("alternate-hidden-token")) "HTTP header diagnostics should never expose header values."

    & git -C $repoPath config --local --unset-all http.extraHeader
    & git -C $repoPath config --local http.cookieFile "C:/secret/auth-cookie.txt"
    Push-Location $repoPath
    try {
        $output = Invoke-Captured $EntryPath @("status") 1 "HTTP authentication cookie rejection"
    } finally {
        Pop-Location
    }
    Assert-True ($output.Contains("hidden HTTPS authorization")) "entry should reject an HTTP cookie file that can authenticate outside the bound credential namespace."
    Assert-True (-not $output.Contains("auth-cookie")) "HTTP cookie diagnostics should not expose paths."

    & git -C $repoPath config --local --unset-all http.cookieFile
    & git -C $repoPath config --local credential.https://github.example.com/repo.helper "!evil-helper"
    Assert-True ($LASTEXITCODE -eq 0) "URL-scoped helper fixture should be configured."
    Push-Location $repoPath
    try {
        $output = Invoke-Captured $EntryPath @("status") 1 "URL-scoped credential helper rejection"
    } finally {
        Pop-Location
    }
    Assert-True ($output.Contains("URL-scoped credential helpers")) "entry should reject a helper that would outrank its guarded helper."
    Assert-True (-not $output.Contains("evil-helper")) "authorization boundary diagnostics should not expose helper commands."
}

function Test-CredentialsEmbeddedInUrlAreRejected {
    param([string]$EntryPath)

    $output = Invoke-Captured $EntryPath @("ls-remote", "https://alice:secret@github.example.com/acme/repo.git") 128 "credential-bearing URL rejection"
    Assert-True ($output.Contains("uses plaintext credentials")) "entry should reject a URL containing a password before network access."
    Assert-True (-not $output.Contains("alice:secret")) "Git should redact credentials in the rejection message."
}

function Test-GitGlobalBoundaryOverridesAreRejected {
    param([string]$EntryPath, [string]$TempRoot)

    $repoA = Join-Path $TempRoot "global-option-repo-a"
    $repoB = Join-Path $TempRoot "global-option-repo-b"
    New-Item -ItemType Directory -Path $repoA, $repoB | Out-Null
    & git -C $repoA init --quiet
    & git -C $repoB init --quiet
    Assert-True ($LASTEXITCODE -eq 0) "global option boundary repositories should initialize."
    & git -C $repoB config --local http.extraHeader "Authorization: Bearer redirected-secret"
    Assert-True ($LASTEXITCODE -eq 0) "redirected repository authorization fixture should be configured."

    $gitDirB = Join-Path $repoB ".git"
    $cases = @(
        [pscustomobject]@{ Label = "-C repository redirect"; Arguments = @("-C", $repoB, "status") },
        [pscustomobject]@{ Label = "--git-dir repository redirect"; Arguments = @("--git-dir=$gitDirB", "--work-tree=$repoB", "status") },
        [pscustomobject]@{ Label = "-c config injection"; Arguments = @("-c", "http.extraHeader=Authorization: Bearer direct-secret", "status") },
        [pscustomobject]@{ Label = "--config-env injection"; Arguments = @("--config-env=http.extraHeader=SWAW_SMOKE_HEADER", "status") },
        [pscustomobject]@{ Label = "--exec-path override"; Arguments = @("--exec-path=$TempRoot", "status") },
        [pscustomobject]@{ Label = "value-bearing global option before redirect"; Arguments = @("--namespace=smoke", "-C", $repoB, "status") },
        [pscustomobject]@{ Label = "unknown value-bearing global option"; Arguments = @("--future-option=smoke", "-C", $repoB, "status") },
        [pscustomobject]@{ Label = "--bare repository reinterpretation"; Arguments = @("--bare", "status") }
    )
    foreach ($case in $cases) {
        $output = Invoke-Captured $EntryPath $case.Arguments 1 $case.Label
        Assert-True ($output.Contains("repository and config override options are not supported")) "$($case.Label) should fail at the identity boundary."
        Assert-True (-not $output.Contains("redirected-secret") -and -not $output.Contains("direct-secret")) "$($case.Label) diagnostics should not expose authorization values."
    }

    foreach ($cloneArguments in @(
        @("clone", "-c", "http.extraHeader=Authorization: Bearer clone-secret", "https://github.example.com/acme/repo.git"),
        @("clone", "--config=credential.https://github.example.com.helper=!evil-clone-helper", "https://github.example.com/acme/repo.git")
    )) {
        $cloneOutput = Invoke-Captured $EntryPath $cloneArguments 1 "clone config injection"
        Assert-True ($cloneOutput.Contains("clone -c/--config is disabled")) "clone-time config injection should fail before any network access."
        Assert-True (-not $cloneOutput.Contains("clone-secret") -and -not $cloneOutput.Contains("evil-clone-helper")) "clone config rejection must not echo injected authorization values."
    }

    [IO.File]::WriteAllText((Join-Path $repoA "sample.txt"), "needle`n", [Text.UTF8Encoding]::new($false))
    & git -C $repoA add sample.txt
    Assert-True ($LASTEXITCODE -eq 0) "git grep fixture should be staged."
    Push-Location $repoA
    try {
        $statusOutput = Invoke-Captured $EntryPath @("--no-pager", "status", "--short") 0 "safe value-free Git global option"
        $grepOutput = Invoke-Captured $EntryPath @("grep", "-c", "needle") 0 "subcommand -c passthrough"
    } finally {
        Pop-Location
    }
    Assert-True ($null -ne $statusOutput) "a known value-free Git global option should remain supported."
    Assert-True ($grepOutput.Contains("sample.txt:1")) "options after the Git subcommand should remain ordinary passthrough arguments."
}

function Test-EntryClearsInheritedRepositoryOverrides {
    param([string]$EntryPath, [string]$TempRoot)

    $repoA = Join-Path $TempRoot "repo-a"
    $repoB = Join-Path $TempRoot "repo-b"
    New-Item -ItemType Directory -Path $repoA, $repoB | Out-Null
    & git -C $repoA init --quiet
    & git -C $repoB init --quiet
    Assert-True ($LASTEXITCODE -eq 0) "repository override fixtures should initialize."

    $configOverride = Join-Path $TempRoot "foreign-gitconfig"
    [IO.File]::WriteAllText($configOverride, "[http]`n`textraHeader = Authorization: Bearer foreign`n", [Text.UTF8Encoding]::new($false))
    $names = @(
        "GIT_DIR", "GIT_EXEC_PATH", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_NAMESPACE", "GIT_CONFIG", "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"
    )
    $oldValues = @{}
    foreach ($name in $names) { $oldValues[$name] = [Environment]::GetEnvironmentVariable($name) }

    try {
        $env:GIT_DIR = Join-Path $repoB ".git"
        $env:GIT_EXEC_PATH = Join-Path $TempRoot "foreign-git-exec"
        $env:GIT_WORK_TREE = $repoB
        $env:GIT_COMMON_DIR = Join-Path $repoB ".git"
        $env:GIT_INDEX_FILE = Join-Path $repoB ".git\index"
        $env:GIT_OBJECT_DIRECTORY = Join-Path $repoB ".git\objects"
        $env:GIT_ALTERNATE_OBJECT_DIRECTORIES = Join-Path $repoB ".git\objects"
        $env:GIT_CEILING_DIRECTORIES = $repoA
        $env:GIT_DISCOVERY_ACROSS_FILESYSTEM = "1"
        $env:GIT_NAMESPACE = "foreign"
        $env:GIT_CONFIG = $configOverride
        $env:GIT_CONFIG_SYSTEM = $configOverride
        $env:GIT_CONFIG_GLOBAL = $configOverride
        $env:GIT_CONFIG_NOSYSTEM = "1"
        $env:GIT_CONFIG_PARAMETERS = "'http.extraHeader'='Authorization: Bearer foreign'"
        $env:GIT_CONFIG_COUNT = "1000000"
        $env:GIT_CONFIG_KEY_0 = "http.extraHeader"
        $env:GIT_CONFIG_VALUE_0 = "Authorization: Bearer foreign"

        Push-Location $repoA
        try {
            $output = Invoke-Captured $EntryPath @("rev-parse", "--show-toplevel") 0 "repository override reset"
        } finally {
            Pop-Location
        }
        $actual = [IO.Path]::GetFullPath($output.Trim())
        Assert-True ($actual -eq [IO.Path]::GetFullPath($repoA)) "entry should operate on the current repository, not an inherited GIT_DIR target."

    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $oldValues[$name]) }
    }
}

function Test-SyncReplacesHttpsModeWithSshMode {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = Join-Path $TempRoot "repo"
    New-Item -ItemType Directory -Path $repoPath | Out-Null
    Push-Location $repoPath
    try {
        git init -q
        $null = Invoke-Captured $EntryPath @(".sync") 0 "initial HTTPS sync"
    } finally {
        Pop-Location
    }

    Set-EntryAccess $EntryPath "ssh:ssh -F '$TempRoot\ssh-config'"
    Push-Location $repoPath
    try {
        $null = Invoke-Captured $EntryPath @(".sync") 0 "HTTPS to SSH sync"
    } finally {
        Pop-Location
    }

    Assert-True (@(Get-LocalValues $repoPath "credential.https://github.example.com.provider").Count -eq 0) "SSH sync should remove the stale HTTPS provider."
    Assert-True (@(Get-LocalValues $repoPath "credential.namespace").Count -eq 0) "SSH sync should remove the stale credential namespace."
    Assert-True (@(Get-LocalValues $repoPath "credential.credentialStore").Count -eq 0) "SSH sync should remove the stale credential store."
    $helpers = @(Get-LocalValues $repoPath "credential.helper")
    Assert-True ($helpers.Count -eq 1 -and $helpers[0] -eq "") "SSH sync should retain only the helper reset."
    Assert-True (@(Get-LocalValues $repoPath "core.sshCommand")[0].Contains("ssh-config")) "SSH sync should replace the deny command with the selected SSH command."
    Assert-True (@(Get-LocalValues $repoPath "swaw-kit-git.access")[0].StartsWith("ssh:")) "sync should record the selected SSH access mode."
}

$tempRoot = Join-Path $tempBase ("git-access-mode-smoke-" + [guid]::NewGuid().ToString("N"))
$httpsEntry = $null
$sshEntry = $null
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $entryRoot = Join-Path $tempRoot "entries"
    $httpsEntry = New-AccessEntry "https.github:github.example.com/github-smoke" $entryRoot
    $sshEntry = New-AccessEntry "ssh:ssh -o IdentitiesOnly=yes -i '$tempRoot\id_ed25519'" $entryRoot
    Test-HttpsModeRejectsSshTransport $httpsEntry
    Test-HiddenHttpsAuthorizationIsRejected $httpsEntry $tempRoot
    Test-CredentialsEmbeddedInUrlAreRejected $httpsEntry
    Test-GitGlobalBoundaryOverridesAreRejected $httpsEntry $tempRoot
    Test-SshModeRejectsHttpsCredentials $sshEntry $tempRoot
    Test-EntryPreservesLiteralArguments $sshEntry $tempRoot
    Test-EntryClearsInheritedRepositoryOverrides $sshEntry $tempRoot
    Test-SyncReplacesHttpsModeWithSshMode $httpsEntry $tempRoot
} finally {
    foreach ($entry in @($httpsEntry, $sshEntry)) {
        if ($entry) { Remove-Item -LiteralPath $entry -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
