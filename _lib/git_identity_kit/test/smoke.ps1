[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryFile = Join-Path $repoRoot "git1.cmd"

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

    $output = (& $File @CommandArgs 2>&1 | Out-String)
    Assert-ExitCode $LASTEXITCODE $ExpectedExitCode $Label
    return $output
}

function Set-EntryLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )

    $pattern = '(?m)^set "' + [regex]::Escape($Name) + '=.*"\r?$'
    Assert-True ($Content -match $pattern) "entry template should declare $Name."

    $line = 'set "' + $Name + '=' + $Value + '"'
    return [regex]::Replace($Content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
}

function New-GitSmokeEntryFile {
    param([string]$TempRoot)

    $entryName = "git.smoke-" + [guid]::NewGuid().ToString("N")
    $path = Join-Path $repoRoot "$entryName.cmd"
    $keyPath = Join-Path $TempRoot "smoke id_ed25519"
    [System.IO.File]::WriteAllText($keyPath, "not a real private key`r`n", [System.Text.UTF8Encoding]::new($false))

    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "GIT_IDENTITY_NAME" "Smoke User"
    $content = Set-EntryLine $content "GIT_IDENTITY_EMAIL" "smoke@example.invalid"
    $content = Set-EntryLine $content "GIT_IDENTITY_SSH_KEY" $keyPath
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Set-GitSmokeEntryValue {
    param(
        [string]$EntryPath,
        [string]$Name,
        [string]$Value
    )

    $content = [System.IO.File]::ReadAllText($EntryPath)
    $content = Set-EntryLine $content $Name $Value
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

function Get-LocalGitConfig {
    param(
        [string]$RepoPath,
        [string]$Key
    )

    Push-Location $RepoPath
    try {
        $value = (& git config --local --get $Key 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        return $value
    } finally {
        Pop-Location
    }
}

function Test-EntryTemplateShape {
    $content = [System.IO.File]::ReadAllText($entryFile)
    Assert-True ($content.Contains("GIT_IDENTITY_NAME")) "entry template should expose GIT_IDENTITY_NAME."
    Assert-True ($content.Contains("GIT_IDENTITY_EMAIL")) "entry template should expose GIT_IDENTITY_EMAIL."
    Assert-True ($content.Contains("GIT_IDENTITY_SSH_KEY")) "entry template should expose GIT_IDENTITY_SSH_KEY."
    Assert-True ($content.Contains("GIT_SSH_COMMAND")) "entry template should expose advanced GIT_SSH_COMMAND override."
    Assert-True ($content.Contains("_lib\git_identity_kit\kit.cmd")) "entry template should dispatch to git_identity_kit."
}

function Test-CommandLineEndings {
    foreach ($path in @($entryFile, (Join-Path $repoRoot "_lib\git_identity_kit\kit.cmd"))) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $lfCount = 0
        $crlfCount = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -ne 10) {
                continue
            }

            $lfCount += 1
            if ($i -gt 0 -and $bytes[$i - 1] -eq 13) {
                $crlfCount += 1
            }
        }

        Assert-True ($lfCount -eq $crlfCount) "$path should use CRLF line endings for cmd.exe."
    }
}

function Test-HelpUsesWrapperHelp {
    param([string]$EntryPath)

    $commandName = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    $oldLanguage = $env:GIT_IDENTITY_HELP_LANG
    try {
        $env:GIT_IDENTITY_HELP_LANG = "en"
        $output = Invoke-Captured $EntryPath @("--help") 0 "wrapper help"
        Assert-True ($output.Contains("Git identity")) "help should describe the wrapper instead of raw git help."
        Assert-True ($output.Contains($commandName)) "help should use the entry command name."
        Assert-True ($output.Contains(".info")) "help should document the identity diagnostic command."
        Assert-True ($output.Contains(".sync --dry-run")) "help should document sync dry-run."
        Assert-True ($output.Contains(".sync --clear")) "help should document conservative sync clear."
        Assert-True ($output.Contains(".code")) "help should document editor launchers."
        Assert-True (-not $output.Contains(" whoami")) "help should not advertise bare custom commands."
        Assert-True ($output.Contains("# Git passthrough:")) "help should have a dedicated passthrough section."

        $launcherIndex = $output.IndexOf("# Editor and shell launchers:")
        $passthroughIndex = $output.IndexOf("# Git passthrough:")
        Assert-True ($launcherIndex -ge 0) "help should include the launcher section."
        Assert-True ($passthroughIndex -gt $launcherIndex) "help should explain passthrough after custom dot commands."

        $env:GIT_IDENTITY_HELP_LANG = "zh-CN"
        $enOutput = Invoke-Captured $EntryPath @(".help", "en") 0 ".help en"
        Assert-True ($enOutput.Contains("Git identity wrapper")) ".help en should force English help."
    } finally {
        $env:GIT_IDENTITY_HELP_LANG = $oldLanguage
    }
}

function Test-GitCommandsUseBoundIdentity {
    param([string]$EntryPath)

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("git-id-work-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $workDir | Out-Null
    try {
        $name = (Invoke-Captured $EntryPath @("-C", $workDir, "config", "--get", "user.name") 0 "git config user.name").Trim()
        $email = (Invoke-Captured $EntryPath @("-C", $workDir, "config", "--get", "user.email") 0 "git config user.email").Trim()
        $ident = Invoke-Captured $EntryPath @("-C", $workDir, "var", "GIT_AUTHOR_IDENT") 0 "git author ident"

        Assert-True ($name -eq "Smoke User") "git config should see the bound user.name."
        Assert-True ($email -eq "smoke@example.invalid") "git config should see the bound user.email."
        Assert-True ($ident.Contains("Smoke User <smoke@example.invalid>")) "git var should see the bound author identity."
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-GitSshCommandOverrideWins {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "git-ssh-override-bin"
    $oldGitSshCommand = $env:GIT_SSH_COMMAND
    $oldPath = $env:PATH
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGitContent = @'
@echo off
echo SSH:%GIT_SSH_COMMAND%
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $binDir "git.cmd"), $fakeGitContent, [System.Text.UTF8Encoding]::new($false))
    try {
        $env:GIT_SSH_COMMAND = "ssh -F C:\tmp\custom-ssh-config"
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @("status") 0 "git ssh command override"

        Assert-True ($output.Contains("SSH:$($env:GIT_SSH_COMMAND)")) "explicit GIT_SSH_COMMAND should override assembled SSH key command."
        Assert-True (-not $output.Contains("IdentitiesOnly=yes")) "explicit GIT_SSH_COMMAND should not append default identity options."
    } finally {
        $env:GIT_SSH_COMMAND = $oldGitSshCommand
        $env:PATH = $oldPath
    }
}

function Test-InfoShowsIdentityStatus {
    param([string]$EntryPath, [string]$TempRoot)
    $output = Invoke-Captured $EntryPath @(".info") 0 ".info"
    Assert-True ($output.Contains("Entry: $EntryPath")) ".info should show the entry file."
    Assert-True ($output.Contains("Name: Smoke User")) ".info should show the configured name."
    Assert-True ($output.Contains("Email: smoke@example.invalid")) ".info should show the configured email."
    Assert-True ($output.Contains("SSH Key:")) ".info should show the configured SSH key."
    Assert-True ($output.Contains("Git sees: OK")) ".info should report OK when Git sees the configured identity."
    Assert-True (-not $output.Contains("Command:")) "default .info should omit wrapper internals."
    Assert-True (-not $output.Contains("Smoke User <smoke@example.invalid>")) "default .info should hide raw Git author ident."

    $verbose = Invoke-Captured $EntryPath @(".info", "--verbose") 0 ".info verbose"
    Assert-True ($verbose.Contains("Git sees:")) ".info --verbose should include Git config diagnostics."
    Assert-True ($verbose.Contains("Smoke User")) ".info --verbose should include the Git-visible user.name."
    Assert-True ($verbose.Contains("smoke@example.invalid")) ".info --verbose should include the Git-visible user.email."
    Assert-True (-not $verbose.Contains("Command:")) ".info --verbose should omit the redundant command name."
    Assert-True (-not $verbose.Contains("Smoke User <smoke@example.invalid>")) ".info --verbose should omit raw Git author ident."
    $binDir = Join-Path $TempRoot "git-mismatch-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGitContent = @'
@echo off
if /i "%~1 %~2 %~3"=="config --get user.name" (echo Other User& exit /b 0)
if /i "%~1 %~2 %~3"=="config --get user.email" (echo other@example.invalid& exit /b 0)
if /i "%~1 %~2"=="var GIT_AUTHOR_IDENT" (echo Other User ^<other@example.invalid^> 0 +0000& exit /b 0)
echo unexpected git args:%*
exit /b 1
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $binDir "git.cmd"), $fakeGitContent, [System.Text.UTF8Encoding]::new($false))
    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $mismatch = Invoke-Captured $EntryPath @(".info") 0 ".info mismatch"
        Assert-True ($mismatch.Contains("Git sees: MISMATCH")) ".info should flag mismatched Git identity."
        Assert-True ($mismatch.Contains("Config: Smoke User")) ".info should show the configured name on mismatch."
        Assert-True ($mismatch.Contains("Git sees: Other User")) ".info should show the Git name on mismatch."
        Assert-True ($mismatch.Contains("Config: smoke@example.invalid")) ".info should show the configured email on mismatch."
        Assert-True ($mismatch.Contains("Git sees: other@example.invalid")) ".info should show the Git email on mismatch."
    } finally {
        $env:PATH = $oldPath
    }
}

function Test-BareCustomWordsPassThroughToGit {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "git-passthrough-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGitContent = @'
@echo off
echo GIT_ARGS:%*
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $binDir "git.cmd"), $fakeGitContent, [System.Text.UTF8Encoding]::new($false))
    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @("sync", "--dry-run") 0 "bare sync passthrough"
        Assert-True ($output.Contains("GIT_ARGS:sync --dry-run")) "bare sync should pass through to git."
        Assert-True (-not $output.Contains("DRY RUN")) "bare sync should not invoke wrapper sync."
    } finally {
        $env:PATH = $oldPath
    }
}

function Test-EditorLauncherInheritsBoundIdentity {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeCode = Join-Path $binDir "code.cmd"
    $fakeCodeContent = @'
@echo off
echo NAME:
git config --get user.name
echo EMAIL:
git config --get user.email
echo SSH:%GIT_SSH_COMMAND%
echo ARGS:%*
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakeCode, $fakeCodeContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @(".code", "--reuse-window", $TempRoot) 0 ".code launcher"

        Assert-True ($output.Contains("Smoke User")) "code launcher should inherit bound user.name."
        Assert-True ($output.Contains("smoke@example.invalid")) "code launcher should inherit bound user.email."
        Assert-True ($output.Contains("IdentitiesOnly=yes")) "code launcher should inherit GIT_SSH_COMMAND."
        Assert-True ($output.Contains("ARGS:--reuse-window")) "code launcher should forward editor args without the launcher verb."
    } finally {
        $env:PATH = $oldPath
    }
}

function Test-SyncDryRunDoesNotWriteLocalConfig {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--dry-run") 0 ".sync dry-run"
        Assert-True ($output.Contains("DRY RUN")) "sync --dry-run should announce that it will not write."
        Assert-True ($output.Contains("user.name")) "sync --dry-run should show user.name."
        Assert-True ($output.Contains("swaw-kit-git.managed")) "sync --dry-run should show the SWAW Kit Git marker."
    }

    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "user.name")) "sync --dry-run should not write user.name."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "swaw-kit-git.managed")) "sync --dry-run should not write the marker."
}

function Test-SyncWritesLocalConfigAndSwawMarker {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 ".sync"
    }

    $commandName = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    Assert-True ((Get-LocalGitConfig $repoPath "user.name") -eq "Smoke User") "sync should write local user.name."
    Assert-True ((Get-LocalGitConfig $repoPath "user.email") -eq "smoke@example.invalid") "sync should write local user.email."
    $sshCommand = Get-LocalGitConfig $repoPath "core.sshCommand"
    Assert-True ($sshCommand.Contains("IdentitiesOnly=yes")) "sync should write local core.sshCommand."
    Assert-True ($sshCommand.Contains("smoke id_ed25519")) "sync should preserve spaces in the configured SSH key path."
    Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.managed") -eq "true") "sync should write the SWAW Kit Git marker."
    Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.entry") -eq $commandName) "sync should record the entry command."
    Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.user-name") -eq "Smoke User") "sync should snapshot the managed user.name."
}

function Test-SyncClearRemovesUnchangedManagedValues {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 ".sync before clear"
        $null = Invoke-Captured $EntryPath @(".sync", "--clear") 0 ".sync clear"
    }

    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "user.name")) "sync --clear should remove managed user.name."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "user.email")) "sync --clear should remove managed user.email."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "core.sshCommand")) "sync --clear should remove managed core.sshCommand."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "swaw-kit-git.managed")) "sync --clear should remove the marker."
}

function Test-SyncClearRefusesChangedValues {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 ".sync before changed clear"
        git config --local user.email "manual@example.invalid"
        Assert-ExitCode $LASTEXITCODE 0 "manual local config change"

        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 ".sync clear changed value"
        Assert-True ($output.Contains("Refusing to clear")) "sync --clear should refuse when a managed value changed."
    }

    Assert-True ((Get-LocalGitConfig $repoPath "user.email") -eq "manual@example.invalid") "sync --clear should keep changed user.email."
    Assert-True ((Get-LocalGitConfig $repoPath "swaw-kit-git.managed") -eq "true") "sync --clear should keep the marker after refusing."
}

function Test-SyncRemovesStaleManagedOptionalValues {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 ".sync before removing key"
    }

    Assert-True ($null -ne (Get-LocalGitConfig $repoPath "core.sshCommand")) "first sync should write core.sshCommand."
    Set-GitSmokeEntryValue $EntryPath "GIT_IDENTITY_SSH_KEY" ""

    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 ".sync after removing key"
    }

    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "core.sshCommand")) "sync should remove stale managed core.sshCommand when the entry no longer configures a key."
    Assert-True ($null -eq (Get-LocalGitConfig $repoPath "swaw-kit-git.ssh-command")) "sync should remove the stale managed ssh marker."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("git-id-smoke-" + [guid]::NewGuid().ToString("N"))
$smokeEntry = $null
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Test-EntryTemplateShape
    Test-CommandLineEndings
    $smokeEntry = New-GitSmokeEntryFile $tempRoot
    Test-HelpUsesWrapperHelp $smokeEntry
    Test-GitCommandsUseBoundIdentity $smokeEntry
    Test-GitSshCommandOverrideWins $smokeEntry $tempRoot
    Test-InfoShowsIdentityStatus $smokeEntry $tempRoot
    Test-BareCustomWordsPassThroughToGit $smokeEntry $tempRoot
    Test-EditorLauncherInheritsBoundIdentity $smokeEntry $tempRoot
    Test-SyncDryRunDoesNotWriteLocalConfig $smokeEntry $tempRoot
    Test-SyncWritesLocalConfigAndSwawMarker $smokeEntry $tempRoot
    Test-SyncClearRemovesUnchangedManagedValues $smokeEntry $tempRoot
    Test-SyncClearRefusesChangedValues $smokeEntry $tempRoot
    Test-SyncRemovesStaleManagedOptionalValues $smokeEntry $tempRoot
} finally {
    if ($smokeEntry -and (Test-Path -LiteralPath $smokeEntry)) {
        Remove-Item -LiteralPath $smokeEntry -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
