[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$guard = Join-Path $repoRoot "_lib\git_identity_kit\https-credential-guard.cmd"
$guardScript = Join-Path $repoRoot "_lib\git_identity_kit\https-credential-guard.ps1"
$entryTemplate = Join-Path $repoRoot "git1.cmd"
$tempBase = Join-Path $repoRoot "temp_workspace"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Identity {
    param(
        [string]$Provider,
        [string]$HostName,
        [string]$Account,
        [string]$CredentialUser
    )

    return [pscustomobject]@{
        Provider       = $Provider
        HostName       = $HostName
        Account        = $Account
        CredentialUser = $CredentialUser
        EntryCommand   = "git1"
        Namespace      = "swaw-kit-git.v2@git1@$Provider@$HostName@$Account"
    }
}

function Get-Rejection {
    param([pscustomobject]$Identity, [string]$Request)
    return Get-HttpsCredentialRejection (ConvertFrom-CredentialRequest $Request) $Identity
}

function New-HttpsEntry {
    param([string]$TempRoot)

    $name = "git.credential-guard-smoke-" + [guid]::NewGuid().ToString("N")
    $entryRoot = Join-Path $TempRoot "entries"
    New-Item -ItemType Directory -Path $entryRoot -Force | Out-Null
    $path = Join-Path $entryRoot "$name.cmd"
    $content = [IO.File]::ReadAllText($entryTemplate)
    $content = [regex]::Replace($content, '(?m)^set "GIT_ID_ACCESS=.*"\r?$', 'set "GIT_ID_ACCESS=https.github:host=github.com;account=alice"')
    $kitPath = Join-Path $repoRoot "_lib\git_identity_kit\kit.cmd"
    $content = [regex]::Replace($content, '(?m)^set "GIT_ID_KIT=.*"\r?$', [Text.RegularExpressions.MatchEvaluator]{ param($match) 'set "GIT_ID_KIT=' + $kitPath + '"' })
    $content = $content.Replace("%~dp0_lib\editor_kit\entry-bootstrap.cmd", (Join-Path $repoRoot "_lib\editor_kit\entry-bootstrap.cmd"))
    $content = $content -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-CredentialFill {
    param(
        [string]$GitCommand,
        [string]$Request,
        [string]$WorkingDirectory = $repoRoot
    )

    if (-not (Test-Path -LiteralPath $tempBase -PathType Container)) {
        New-Item -ItemType Directory -Path $tempBase | Out-Null
    }
    $requestPath = Join-Path $tempBase ("credential-request-" + [guid]::NewGuid().ToString("N") + ".txt")
    $requestBody = $Request -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($requestPath, $requestBody, [Text.UTF8Encoding]::new($false))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
    $startInfo.Arguments = '/d /s /c ""{0}" credential fill < "{1}""' -f $GitCommand, $requestPath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout + $stderr }
    } finally {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GuardGet {
    param([string]$Request)

    $requestPath = Join-Path $tempBase ("guard-request-" + [guid]::NewGuid().ToString("N") + ".txt")
    $requestBody = $Request -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($requestPath, $requestBody, [Text.UTF8Encoding]::new($false))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
    $startInfo.Arguments = '/d /s /c ""{0}" get < "{1}""' -f $guard, $requestPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout + $stderr }
    } finally {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-GitHubCredentialMatchPassesThrough {
    $identity = New-Identity "github" "github.com" "alice" "alice"
    $rejection = Get-Rejection $identity "protocol=https`nhost=github.com`nusername=alice`n`n"
    Assert-True ($null -eq $rejection) "matching GitHub credentials should pass through."
}

function Test-GitHubCredentialUserMismatchQuits {
    $identity = New-Identity "github" "github.com" "alice" "alice"
    $rejection = Get-Rejection $identity "protocol=https`nhost=github.com`nusername=bob`n`n"
    Assert-True ($rejection.Contains("requests account 'bob'")) "the mismatch should identify the URL account."
    Assert-True ($rejection.Contains("bound to GitHub account 'alice'")) "the mismatch should identify the entry account."
}

function Test-HttpsHostMismatchQuits {
    $identity = New-Identity "github" "github.com" "alice" "alice"
    $rejection = Get-Rejection $identity "protocol=https`nhost=git.example.com`nusername=alice`n`n"
    Assert-True ($rejection.Contains("requests host 'git.example.com'")) "the mismatch should identify the requested host."
    Assert-True ($rejection.Contains("bound to GitHub host 'github.com'")) "the mismatch should identify the configured host."
}

function Test-GitLabRequiresOAuthCredentialUser {
    $identity = New-Identity "gitlab" "gitlab.com" "alice" "oauth2"
    $match = Get-Rejection $identity "protocol=https`nhost=gitlab.com`nusername=oauth2`n`n"
    Assert-True ($null -eq $match) "GitLab oauth2 credentials should pass through."

    $mismatch = Get-Rejection $identity "protocol=https`nhost=gitlab.com`nusername=alice`n`n"
    Assert-True ($mismatch.Contains("requires credential username 'oauth2'")) "the GitLab error should explain its credential username."
}

function Test-MatchingRequestDelegatesToCredentialManager {
    $binDir = Join-Path $tempBase ("credential-manager-bin-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGit = Join-Path $binDir "git.cmd"
    $fakeGitContent = @'
@echo off
if /i not "%~1"=="credential-manager" exit /b 41
if /i not "%~2"=="get" exit /b 42
echo namespace=%GCM_NAMESPACE% 1>&2
if defined GIT_CONFIG_COUNT (echo config-count=%GIT_CONFIG_COUNT% 1>&2) else (echo config-count= 1>&2)
echo username=alice
echo password=fake-token
echo.
'@ -replace "`n", "`r`n"
    [IO.File]::WriteAllText($fakeGit, $fakeGitContent, [Text.UTF8Encoding]::new($false))

    $names = @("GIT_ID_HTTPS_PROVIDER", "GIT_ID_HTTPS_HOST", "GIT_ID_HTTPS_ACCOUNT", "GIT_ID_HTTPS_CREDENTIAL_USER", "GIT_ID_ENTRY_COMMAND", "GIT_ID_CREDENTIAL_NAMESPACE", "GIT_CONFIG_COUNT")
    $oldValues = @{}
    foreach ($name in $names) { $oldValues[$name] = [Environment]::GetEnvironmentVariable($name) }
    $oldPath = $env:PATH

    try {
        $env:PATH = "$binDir;$oldPath"
        $env:GIT_ID_HTTPS_PROVIDER = "github"
        $env:GIT_ID_HTTPS_HOST = "github.com"
        $env:GIT_ID_HTTPS_ACCOUNT = "alice"
        $env:GIT_ID_HTTPS_CREDENTIAL_USER = "alice"
        $env:GIT_ID_ENTRY_COMMAND = "git1"
        $env:GIT_ID_CREDENTIAL_NAMESPACE = "swaw-kit-git.v2@git1@github@github.com@alice"
        $env:GIT_CONFIG_COUNT = "1"

        $result = Invoke-GuardGet "protocol=https`nhost=github.com`nusername=alice`n`n"
        Assert-True ($result.ExitCode -eq 0) "a matching credential request should reach GCM. Output: $($result.Output)"
        Assert-True ($result.Output.Contains("username=alice")) "the guard should return GCM's matching account."
        Assert-True ($result.Output.Contains("password=fake-token")) "the guard should pass GCM's credential response through unchanged."
        Assert-True ($result.Output.Contains("namespace=swaw-kit-git.v2@git1@github@github.com@alice")) "the guard should force the identity namespace for GCM."
        Assert-True ($result.Output -match '(?m)^config-count=\s*$') "the guard should clear injected Git config before invoking GCM. Output: $($result.Output)"
    } finally {
        $env:PATH = $oldPath
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $oldValues[$name]) }
        Remove-Item -LiteralPath $binDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-EntryStopsCredentialHelperChain {
    param([string]$EntryPath)

    $result = Invoke-CredentialFill $EntryPath "protocol=https`nhost=github.com`nusername=bob`n`n"
    Assert-True ($result.ExitCode -ne 0) "git credential fill should fail for a mismatched URL account."
    Assert-True ($result.Output.Contains("requests account 'bob'")) "the entry should surface the guard's account mismatch. Output: $($result.Output)"
    Assert-True ($result.Output.Contains("bound to GitHub account 'alice'")) "the entry should surface its bound account. Output: $($result.Output)"
}

function Test-SyncedRepositoryStopsCredentialHelperChain {
    param([string]$EntryPath)

    $repoPath = Join-Path $tempBase ("credential-guard-repo-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $repoPath | Out-Null
    try {
        & git -C $repoPath init --quiet
        Assert-True ($LASTEXITCODE -eq 0) "temporary Git repository should initialize."

        Push-Location $repoPath
        try {
            $syncOutput = @(& $EntryPath .sync 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
            $syncExitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        Assert-True ($syncExitCode -eq 0) ".sync should persist the guarded HTTPS identity. Output: $syncOutput"

        $result = Invoke-CredentialFill "git" "protocol=https`nhost=github.com`nusername=bob`n`n" $repoPath
        Assert-True ($result.ExitCode -ne 0) "external Git should fail for an account that conflicts with the synced identity."
        Assert-True ($result.Output.Contains("requests account 'bob'")) "the synced guard should identify the conflicting URL account. Output: $($result.Output)"
        Assert-True ($result.Output.Contains("bound to GitHub account 'alice'")) "the synced guard should identify the repository-bound account. Output: $($result.Output)"

        & git -C $repoPath config --local credential.namespace "swaw-kit-git.v2@other@github@github.com@alice"
        Assert-True ($LASTEXITCODE -eq 0) "namespace tamper fixture should be configured."
        $tampered = Invoke-CredentialFill "git" "protocol=https`nhost=github.com`nusername=alice`n`n" $repoPath
        Assert-True ($tampered.ExitCode -ne 0) "a synced repository with a drifted credential namespace must fail closed."
        Assert-True ($tampered.Output.Contains("could not resolve the bound Git identity")) "namespace drift should be reported as an invalid synced identity context. Output: $($tampered.Output)"
    } finally {
        Remove-Item -LiteralPath $repoPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-SyncedRepositoryDelegatesMatchingRequestToCredentialManager {
    param([string]$EntryPath)

    $repoPath = Join-Path $tempBase ("credential-guard-success-repo-" + [guid]::NewGuid().ToString("N"))
    $binDir = Join-Path $tempBase ("credential-manager-success-bin-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $repoPath, $binDir | Out-Null

    $environmentNames = @(
        "GIT_EXEC_PATH",
        "GIT_ID_ACCESS",
        "GIT_ID_TRANSPORT",
        "GIT_ID_HTTPS_PROVIDER",
        "GIT_ID_HTTPS_HOST",
        "GIT_ID_HTTPS_ACCOUNT",
        "GIT_ID_HTTPS_CREDENTIAL_USER",
        "GIT_ID_ENTRY_COMMAND",
        "GIT_ID_CREDENTIAL_NAMESPACE",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS"
    )
    $oldEnvironment = @{}
    foreach ($name in $environmentNames) {
        $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
        & git -C $repoPath init --quiet
        Assert-True ($LASTEXITCODE -eq 0) "temporary Git repository should initialize."

        Push-Location $repoPath
        try {
            $syncOutput = @(& $EntryPath .sync 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
            $syncExitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        Assert-True ($syncExitCode -eq 0) ".sync should persist the guarded HTTPS identity. Output: $syncOutput"
        $syncedHelpers = @(& git -C $repoPath config --local --get-all credential.helper)
        Assert-True ($syncedHelpers.Count -eq 2 -and $syncedHelpers[0] -eq "" -and $syncedHelpers[1].Contains("https-credential-guard.cmd")) ".sync should persist only the helper reset and guarded HTTPS helper."

        $fakeCredentialManager = Join-Path $binDir "git-credential-manager.exe"
        $typeName = "GitCredentialManagerSmoke" + [guid]::NewGuid().ToString("N")
        $fakeCredentialManagerSource = @'
using System;

public static class __TYPE_NAME__
{
    public static int Main(string[] args)
    {
        if (args.Length != 1 || !string.Equals(args[0], "get", StringComparison.OrdinalIgnoreCase))
        {
            return 42;
        }

        Console.In.ReadToEnd();
        Console.Error.WriteLine("namespace=" + Environment.GetEnvironmentVariable("GCM_NAMESPACE"));
        Console.Error.WriteLine("provider=" + Environment.GetEnvironmentVariable("GCM_PROVIDER"));
        Console.Error.WriteLine("identity-account=" + Environment.GetEnvironmentVariable("GIT_ID_HTTPS_ACCOUNT"));
        Console.Error.WriteLine("config-count=" + Environment.GetEnvironmentVariable("GIT_CONFIG_COUNT"));
        Console.WriteLine("username=alice");
        Console.WriteLine("password=fake-token");
        Console.WriteLine();
        return 0;
    }
}
'@ -replace '__TYPE_NAME__', $typeName
        Add-Type -TypeDefinition $fakeCredentialManagerSource -Language CSharp -OutputAssembly $fakeCredentialManager -OutputType ConsoleApplication

        foreach ($name in $environmentNames | Where-Object { $_ -ne "GIT_EXEC_PATH" }) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $env:GIT_EXEC_PATH = $binDir

        $entryCommand = [IO.Path]::GetFileNameWithoutExtension($EntryPath)
        $expectedNamespace = "swaw-kit-git.v2@$entryCommand@github@github.com@alice"
        $result = Invoke-CredentialFill "git" "protocol=https`nhost=github.com`nusername=alice`n`n" $repoPath

        Assert-True ($result.ExitCode -eq 0) "external Git should resolve a matching synced HTTPS credential. Output: $($result.Output)"
        Assert-True ($result.Output.Contains("username=alice")) "the synced helper should return GCM's matching account."
        Assert-True ($result.Output.Contains("password=fake-token")) "the synced helper should pass GCM's credential through."
        Assert-True ($result.Output.Contains("namespace=$expectedNamespace")) "the synced helper should reconstruct the entry-bound namespace from local config."
        Assert-True ($result.Output.Contains("provider=github")) "the synced helper should reconstruct the provider from local config."
        Assert-True ($result.Output -match '(?m)^identity-account=\s*$') "the synced helper must not depend on inherited GIT_ID_HTTPS_ACCOUNT."
        Assert-True ($result.Output -match '(?m)^config-count=\s*$') "the synced helper should clear injected Git config before delegating to GCM."
    } finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name])
        }
        Remove-Item -LiteralPath $repoPath, $binDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-True (Test-Path -LiteralPath $guard -PathType Leaf) "HTTPS credential guard is missing."
Assert-True (Test-Path -LiteralPath $guardScript -PathType Leaf) "HTTPS credential guard script is missing."
. $guardScript
Test-GitHubCredentialMatchPassesThrough
Test-GitHubCredentialUserMismatchQuits
Test-HttpsHostMismatchQuits
Test-GitLabRequiresOAuthCredentialUser
Test-MatchingRequestDelegatesToCredentialManager

$entry = $null
$tempRoot = Join-Path $tempBase ("credential-guard-smoke-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $entry = New-HttpsEntry $tempRoot
    Test-EntryStopsCredentialHelperChain $entry
    Test-SyncedRepositoryDelegatesMatchingRequestToCredentialManager $entry
    Test-SyncedRepositoryStopsCredentialHelperChain $entry
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
