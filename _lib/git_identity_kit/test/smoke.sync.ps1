[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
. (Join-Path $repoRoot "_lib\test_support\template-entry.ps1")
$entryTemplate = New-SwawKitTestTemplateEntry `
    -RepoRoot $repoRoot `
    -TemplateName "template.git1.cmd" `
    -EntryName "test.template.git1.cmd"
$tempBase = Join-Path $repoRoot "temp_workspace"
$syncScript = Join-Path $repoRoot "_lib\git_identity_kit\sync.ps1"
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ExitCode {
    param([int]$Actual, [int]$Expected, [string]$Label)
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

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = (& $File @CommandArgs 2>&1 | Out-String -Width 4096)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "$Label failed: expected exit code $ExpectedExitCode, got $exitCode.`n$output"
    }
    return $output
}

function Set-EntryLine {
    param([string]$Content, [string]$Name, [string]$Value)

    $pattern = '(?m)^(?::: )?set "' + [regex]::Escape($Name) + '=.*"\r?$'
    Assert-True ($Content -match $pattern) "entry template should declare $Name."
    $line = 'set "' + $Name + '=' + $Value + '"'
    return [regex]::Replace($Content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
}

function Set-EntryValue {
    param([string]$EntryPath, [string]$Name, [string]$Value)

    $content = [System.IO.File]::ReadAllText($EntryPath)
    $content = Set-EntryLine $content $Name $Value
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($EntryPath, $content, [System.Text.UTF8Encoding]::new($false))
}

function New-SyncEntry {
    param([string]$TempRoot)

    $path = Join-Path $TempRoot ("git.sync-smoke-" + [guid]::NewGuid().ToString("N") + ".cmd")
    $keyPath = Join-Path $TempRoot "sync id_ed25519"
    [System.IO.File]::WriteAllText($keyPath, "not a real private key`r`n", [System.Text.UTF8Encoding]::new($false))

    $content = [System.IO.File]::ReadAllText($entryTemplate)
    $content = Set-EntryLine $content "GIT_ID_NAME" "Sync Smoke User"
    $content = Set-EntryLine $content "GIT_ID_EMAIL" "sync-smoke@example.invalid"
    $content = Set-EntryLine $content "GIT_ID_ACCESS" "ssh:ssh -o IdentitiesOnly=yes -i '$keyPath'"
    $content = Set-EntryLine $content "GIT_ID_KIT" (Join-Path $repoRoot "_lib\git_identity_kit\kit.cmd")
    $content = $content.Replace("%~dp0_lib\editor_kit\entry-bootstrap.cmd", (Join-Path $repoRoot "_lib\editor_kit\entry-bootstrap.cmd"))
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function New-TempGitRepo {
    param([string]$TempRoot)

    $repoPath = Join-Path $TempRoot ("repo-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $repoPath | Out-Null
    git -C $repoPath init -q
    Assert-ExitCode $LASTEXITCODE 0 "git init"
    return $repoPath
}

function Invoke-InDirectory {
    param([string]$Directory, [scriptblock]$Script)
    Push-Location $Directory
    try { & $Script } finally { Pop-Location }
}

function Get-LocalValues {
    param([string]$RepoPath, [string]$Key)

    $values = @(& git -C $RepoPath config --local --get-all $Key 2>$null)
    if ($LASTEXITCODE -eq 1) { return @() }
    Assert-ExitCode $LASTEXITCODE 0 "read local Git config '$Key'"
    return $values
}

function Get-LocalValue {
    param([string]$RepoPath, [string]$Key)
    $values = @(Get-LocalValues $RepoPath $Key)
    if ($values.Count -eq 0) { return $null }
    return $values[0]
}

function Set-LocalValue {
    param([string]$RepoPath, [string]$Key, [string]$Value)
    git -C $RepoPath config --local $Key $Value
    Assert-ExitCode $LASTEXITCODE 0 "write local Git config '$Key'"
}

function Get-LocalSemanticState {
    param([string]$RepoPath)

    $keys = @(& git -C $RepoPath config --local --name-only --get-regexp '.*' 2>$null)
    if ($LASTEXITCODE -eq 1) { $keys = @() }
    else { Assert-ExitCode $LASTEXITCODE 0 "enumerate local Git config" }

    $state = foreach ($key in @($keys | Sort-Object -Unique)) {
        [ordered]@{ Key = $key; Values = @(Get-LocalValues $RepoPath $key) }
    }
    return (ConvertTo-Json @($state) -Depth 3 -Compress)
}

function Set-DirectSyncIdentity {
    param([ValidateSet("ssh", "https")][string]$Transport, [string]$TempRoot)

    $env:GIT_ID_NAME = "Sync Smoke User"
    $env:GIT_ID_EMAIL = "sync-smoke@example.invalid"
    Remove-Item Env:GIT_ID_SIGNING_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_ID_GPG_FORMAT -ErrorAction SilentlyContinue

    if ($Transport -eq "ssh") {
        $sshCommand = "ssh -o IdentitiesOnly=yes -i '$TempRoot\sync id_ed25519'"
        $env:GIT_ID_ACCESS = "ssh:$sshCommand"
        $env:GIT_ID_TRANSPORT = "ssh"
        $env:GIT_SSH_COMMAND = $sshCommand
        return
    }

    $env:GIT_ID_ACCESS = "https.github:host=github.example.com;account=sync-smoke"
    $env:GIT_ID_TRANSPORT = "https"
    $env:GIT_ID_HTTPS_HOST = "github.example.com"
    $env:GIT_ID_HTTPS_ACCOUNT = "sync-smoke"
    $env:GIT_ID_HTTPS_CREDENTIAL_HELPER = "test-credential-helper"
    $env:GIT_ID_CREDENTIAL_NAMESPACE = "sync-smoke.namespace"
    $env:GIT_ID_HTTPS_PROVIDER = "github"
    $env:GIT_ID_HTTPS_CREDENTIAL_USER = "sync-smoke"
    $env:GIT_SSH_COMMAND = "cmd /d /c exit 1"
}

function Invoke-DirectSync {
    param(
        [string]$RepoPath,
        [string]$EntryPath,
        [ValidateSet("write", "clear")][string]$Mode,
        [int]$FailAt = 0,
        [int]$ExpectedExitCode = -1
    )

    $commandArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $syncScript,
        "-Mode", $Mode,
        "-EntryCommand", [System.IO.Path]::GetFileNameWithoutExtension($EntryPath),
        "-EntryFile", $EntryPath
    )
    if ($FailAt -gt 0) {
        $commandArgs += @("-TestFailConfigMutationAt", $FailAt)
    }
    if ($ExpectedExitCode -lt 0) {
        $ExpectedExitCode = if ($FailAt -gt 0) { 1 } else { 0 }
    }

    return Invoke-InDirectory $RepoPath {
        Invoke-Captured $windowsPowerShell $commandArgs $ExpectedExitCode "direct sync $Mode (failure $FailAt)"
    }
}

function Assert-InjectedMutationWasRolledBack {
    param([string]$Output, [string]$Before, [string]$RepoPath, [string]$Label)

    Assert-True ($Output.Contains("was rolled back")) "$Label should report a successful rollback."
    Assert-True ((Get-LocalSemanticState $RepoPath) -ceq $Before) "$Label should restore every local config value in order."
}

function Test-SyncDryRunAndRepositoryBoundary {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--dry-run") 0 ".sync dry-run"
        Assert-True ($output.Contains("DRY RUN")) "sync --dry-run should announce that it will not write."
        Assert-True ($output.Contains("swaw-kit-git.managed")) "sync --dry-run should show the managed marker."
        Assert-True ($output.Contains("core.sshCommand = <redacted>")) "sync --dry-run should identify sensitive config keys without printing their commands."
        Assert-True (-not $output.Contains("IdentitiesOnly")) "sync --dry-run must not copy a free-form SSH command into terminal logs."
    }
    Assert-True ($null -eq (Get-LocalValue $repoPath "user.name")) "sync --dry-run should not write local config."

    # A child of temp_workspace is still inside the source repository. Use a
    # short-lived sibling solely for the real "outside any repository" case.
    $nonRepoPath = Join-Path (Split-Path $repoRoot -Parent) ("swaw-kit-non-repo-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $nonRepoPath | Out-Null
    try {
        Invoke-InDirectory $nonRepoPath {
            $output = Invoke-Captured $EntryPath @(".sync", "--dry-run") 1 ".sync outside repository"
            Assert-True ($output.Trim() -eq "[ERROR] sync must be run inside a Git repository.") "sync outside a repository should show a clean error."
        }
    } finally {
        Remove-Item -LiteralPath $nonRepoPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-SyncWritesAndClearsOwnedValues {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync") 0 ".sync"
    }

    $commandName = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    Assert-True ((Get-LocalValue $repoPath "user.name") -eq "Sync Smoke User") "sync should write user.name."
    Assert-True ((Get-LocalValue $repoPath "swaw-kit-git.entry") -eq $commandName) "sync should record its entry command."
    Assert-True ((Get-LocalValue $repoPath "swaw-kit-git.entry-file") -eq $EntryPath) "sync should record its exact entry file."
    Assert-True ((Get-LocalValue $repoPath "transfer.credentialsInUrl") -eq "die") "sync should persist the credential-in-URL boundary."
    Assert-True ((Get-LocalValue $repoPath "commit.gpgSign") -eq "false") "sync should explicitly disable automatic commit signing when signing is off."
    Assert-True ((Get-LocalValue $repoPath "tag.gpgSign") -eq "false") "sync should explicitly disable automatic tag signing."

    Invoke-InDirectory $repoPath {
        $null = Invoke-Captured $EntryPath @(".sync", "--clear") 0 ".sync clear"
    }
    Assert-True ($null -eq (Get-LocalValue $repoPath "user.name")) "sync --clear should remove unchanged managed values."
    Assert-True ($null -eq (Get-LocalValue $repoPath "commit.gpgSign")) "sync --clear should remove the managed commit signing switch."
    Assert-True ($null -eq (Get-LocalValue $repoPath "tag.gpgSign")) "sync --clear should remove the managed tag signing switch."
    Assert-True ($null -eq (Get-LocalValue $repoPath "swaw-kit-git.managed")) "sync --clear should remove the marker section."
}

function Test-FirstSyncRefusesExistingLocalConflicts {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    Set-LocalValue $repoPath "user.name" "Existing User"
    Set-LocalValue $repoPath "user.email" "existing@example.invalid"

    Invoke-InDirectory $repoPath {
        $dryRunOutput = Invoke-Captured $EntryPath @(".sync", "--dry-run") 1 ".sync dry-run existing conflict"
        Assert-True ($dryRunOutput.Contains("Refusing to overwrite existing local Git config")) "dry-run should apply the same conflict decision as write."
        $output = Invoke-Captured $EntryPath @(".sync") 1 ".sync existing conflict"
        Assert-True ($output.Contains("Refusing to overwrite existing local Git config")) "first sync should explain the ownership conflict."
        Assert-True ($output.Contains("user.name")) "first sync should list each conflicting key."
        Assert-True ($output.Contains("Existing User")) "first sync should show the existing value."
        Assert-True ($output.Contains("Sync Smoke User")) "first sync should show the requested value."
    }

    Assert-True ((Get-LocalValue $repoPath "user.name") -eq "Existing User") "a refused first sync must preserve local values."
    Assert-True ($null -eq (Get-LocalValue $repoPath "swaw-kit-git.managed")) "a refused first sync must not create a marker."
}

function Test-ManagedSyncAllowsIntentionalIdentitySwitch {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "initial managed sync" }
    try {
        Set-EntryValue $EntryPath "GIT_ID_NAME" "Switched Sync User"
        Set-EntryValue $EntryPath "GIT_ID_EMAIL" "switched@example.invalid"
        Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "managed identity switch" }
        Assert-True ((Get-LocalValue $repoPath "user.name") -eq "Switched Sync User") "a managed repository should allow an intentional identity switch."
        Assert-True ((Get-LocalValue $repoPath "swaw-kit-git.user-name") -eq "Switched Sync User") "identity switch should update the value marker with the value."
    } finally {
        Set-EntryValue $EntryPath "GIT_ID_NAME" "Sync Smoke User"
        Set-EntryValue $EntryPath "GIT_ID_EMAIL" "sync-smoke@example.invalid"
    }
}

function Test-SyncClearRequiresExactOwner {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "sync before ownership checks" }

    Set-LocalValue $repoPath "swaw-kit-git.entry" "another-entry"
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "clear wrong entry"
        Assert-True ($output.Contains("synced by 'another-entry'")) "clear should reject a different owning entry command."
    }
    Assert-True ((Get-LocalValue $repoPath "user.name") -eq "Sync Smoke User") "entry ownership rejection must preserve config."

    Set-LocalValue $repoPath "swaw-kit-git.entry" ([System.IO.Path]::GetFileNameWithoutExtension($EntryPath))
    Set-LocalValue $repoPath "swaw-kit-git.entry-file" (Join-Path $TempRoot "different-entry.cmd")
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "clear wrong entry file"
        Assert-True ($output.Contains("different '")) "clear should reject a different owning entry file."
        Assert-True ($output.Contains("synced:")) "entry-file rejection should show the recorded owner."
    }

    git -C $repoPath config --local --unset-all swaw-kit-git.entry-file
    Assert-ExitCode $LASTEXITCODE 0 "remove entry-file marker"
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "clear missing entry file"
        Assert-True ($output.Contains("no owning entry file")) "clear should reject an incomplete ownership marker."
    }
}

function Test-SyncClearRefusesChangedValues {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "sync before changed clear" }
    Set-LocalValue $repoPath "user.email" "manual@example.invalid"
    Invoke-InDirectory $repoPath {
        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "clear changed value"
        Assert-True ($output.Contains("Refusing to clear")) "clear should reject a changed managed value."
    }
    Assert-True ((Get-LocalValue $repoPath "user.email") -eq "manual@example.invalid") "clear refusal should preserve the changed value."
    Assert-True ((Get-LocalValue $repoPath "swaw-kit-git.managed") -eq "true") "clear refusal should preserve its marker."
}

function Test-SyncDiagnosticsRedactSensitiveCommands {
    param([string]$EntryPath, [string]$TempRoot)

    $conflictRepo = New-TempGitRepo $TempRoot
    Set-LocalValue $conflictRepo "core.sshCommand" "ssh -o ProxyCommand=proxy-with-existing-secret"
    Invoke-InDirectory $conflictRepo {
        $output = Invoke-Captured $EntryPath @(".sync", "--dry-run") 1 "sensitive first-sync conflict"
        Assert-True ($output.Contains("core.sshCommand")) "a sensitive conflict should still identify the affected key."
        Assert-True ($output.Contains("<redacted>")) "a sensitive conflict should explicitly redact its values."
        Assert-True (-not $output.Contains("existing-secret") -and -not $output.Contains("IdentitiesOnly")) "a sensitive conflict must not print existing or requested SSH commands."
    }

    $clearRepo = New-TempGitRepo $TempRoot
    Invoke-InDirectory $clearRepo { $null = Invoke-Captured $EntryPath @(".sync") 0 "sync before sensitive clear conflict" }
    Set-LocalValue $clearRepo "core.sshCommand" "ssh -o ProxyCommand=proxy-with-current-secret"
    Invoke-InDirectory $clearRepo {
        $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "sensitive clear conflict"
        Assert-True ($output.Contains("core.sshCommand")) "a sensitive clear conflict should identify the affected key."
        Assert-True ($output.Contains("<redacted>")) "a sensitive clear conflict should redact synced and current values."
        Assert-True (-not $output.Contains("current-secret") -and -not $output.Contains("IdentitiesOnly")) "clear diagnostics must not print either SSH command."
    }
}

function Test-SyncIgnoresRepositoryRedirectEnvironment {
    param([string]$EntryPath, [string]$TempRoot)

    $repoA = New-TempGitRepo $TempRoot
    $repoB = New-TempGitRepo $TempRoot
    $oldGitDir = $env:GIT_DIR
    try {
        $env:GIT_DIR = Join-Path $repoB ".git"
        Invoke-InDirectory $repoA { $null = Invoke-Captured $EntryPath @(".sync") 0 "sync with redirected GIT_DIR" }
        $env:GIT_DIR = $oldGitDir
        Assert-True ((Get-LocalValue $repoA "user.name") -eq "Sync Smoke User") "sync should stay anchored to the current repository."
        Assert-True ($null -eq (Get-LocalValue $repoB "user.name")) "GIT_DIR must not redirect sync into another repository."

        $env:GIT_DIR = Join-Path $repoB ".git"
        Invoke-InDirectory $repoA { $null = Invoke-Captured $EntryPath @(".sync", "--clear") 0 "clear with redirected GIT_DIR" }
        $env:GIT_DIR = $oldGitDir
        Assert-True ($null -eq (Get-LocalValue $repoA "user.name")) "clear should stay anchored to the current repository."
        Assert-True ($null -eq (Get-LocalValue $repoB "swaw-kit-git.managed")) "redirected repository must remain untouched."
    } finally {
        $env:GIT_DIR = $oldGitDir
    }
}

function Test-ClearRejectsIncompleteHttpsMarkerSchema {
    param([string]$EntryPath, [string]$TempRoot)

    $repoPath = New-TempGitRepo $TempRoot
    try {
        Set-EntryValue $EntryPath "GIT_ID_ACCESS" "https.github:host=github.example.com;account=sync-smoke"
        Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "HTTPS sync before marker damage" }
        git -C $repoPath config --local --unset-all swaw-kit-git.https-username
        Assert-ExitCode $LASTEXITCODE 0 "damage HTTPS username marker"

        Invoke-InDirectory $repoPath {
            $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "clear incomplete HTTPS marker"
            Assert-True ($output.Contains("incomplete")) "clear should report an incomplete managed marker."
        }
        Assert-True ((Get-LocalValue $repoPath "credential.https://github.example.com.username") -eq "sync-smoke") "clear must not orphan a managed HTTPS config value."
        Assert-True ((Get-LocalValue $repoPath "swaw-kit-git.managed") -eq "true") "incomplete marker rejection must retain ownership evidence."
    } finally {
        Set-EntryValue $EntryPath "GIT_ID_ACCESS" "ssh:ssh -o IdentitiesOnly=yes -i '$TempRoot\sync id_ed25519'"
    }
}

function Test-GitConfigFailuresCannotReportSuccess {
    param([string]$EntryPath, [string]$TempRoot)

    $readFailureRepo = New-TempGitRepo $TempRoot
    [System.IO.File]::AppendAllText((Join-Path $readFailureRepo ".git\config"), "`n[broken", [System.Text.UTF8Encoding]::new($false))
    Invoke-InDirectory $readFailureRepo {
        $output = Invoke-Captured $EntryPath @(".sync") 1 "sync malformed config"
        Assert-True ($output.Contains("[ERROR]")) "a config read failure should be reported as an error."
        Assert-True (-not $output.Contains("sync wrote local config")) "a config read failure must not report success."
    }

    $writeFailureRepo = New-TempGitRepo $TempRoot
    [System.IO.File]::WriteAllText((Join-Path $writeFailureRepo ".git\config.lock"), "busy", [System.Text.UTF8Encoding]::new($false))
    try {
        Invoke-InDirectory $writeFailureRepo {
            $output = Invoke-Captured $EntryPath @(".sync") 1 "sync locked config"
            Assert-True ($output.Contains("[ERROR]")) "a config write failure should be reported as an error."
            Assert-True (-not $output.Contains("sync wrote local config")) "a config write failure must not report success."
        }
        Assert-True ($null -eq (Get-LocalValue $writeFailureRepo "swaw-kit-git.managed")) "a failed first write should not claim ownership."
    } finally {
        Remove-Item -LiteralPath (Join-Path $writeFailureRepo ".git\config.lock") -Force -ErrorAction SilentlyContinue
    }

    $clearFailureRepo = New-TempGitRepo $TempRoot
    Invoke-InDirectory $clearFailureRepo { $null = Invoke-Captured $EntryPath @(".sync") 0 "sync before locked clear" }
    [System.IO.File]::WriteAllText((Join-Path $clearFailureRepo ".git\config.lock"), "busy", [System.Text.UTF8Encoding]::new($false))
    try {
        Invoke-InDirectory $clearFailureRepo {
            $output = Invoke-Captured $EntryPath @(".sync", "--clear") 1 "clear locked config"
            Assert-True ($output.Contains("[ERROR]")) "a clear write failure should be reported as an error."
            Assert-True (-not $output.Contains("were cleared")) "a failed clear must not report success."
        }
        Assert-True ((Get-LocalValue $clearFailureRepo "swaw-kit-git.managed") -eq "true") "a failed clear should retain its ownership marker."
    } finally {
        Remove-Item -LiteralPath (Join-Path $clearFailureRepo ".git\config.lock") -Force -ErrorAction SilentlyContinue
    }
}

function Test-SyncSigningState {
    param([string]$EntryPath, [string]$TempRoot)

    $isolatedHome = Join-Path $TempRoot "signing-home"
    New-Item -ItemType Directory -Path $isolatedHome -Force | Out-Null
    $globalConfig = @"
[user]
    signingkey = external-signing-key
[gpg]
    format = ssh
[commit]
    gpgSign = true
[tag]
    gpgSign = true
"@
    [IO.File]::WriteAllText((Join-Path $isolatedHome ".gitconfig"), $globalConfig, [Text.UTF8Encoding]::new($false))

    $oldHome = [Environment]::GetEnvironmentVariable("HOME", "Process")
    try {
        [Environment]::SetEnvironmentVariable("HOME", $isolatedHome, "Process")
        $repoPath = New-TempGitRepo $TempRoot
        Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "off signing sync over inherited signing" }
        Assert-True ((Get-LocalValue $repoPath "commit.gpgSign") -eq "false") "signing-off sync should override inherited automatic commit signing."
        Assert-True ((Get-LocalValue $repoPath "tag.gpgSign") -eq "false") "signing-off sync should override inherited automatic tag signing."
        Assert-True ($null -eq (Get-LocalValue $repoPath "user.signingkey")) "signing-off sync should not claim an inherited signing key."
        Assert-True ($null -eq (Get-LocalValue $repoPath "gpg.format")) "signing-off sync should not claim an inherited signing format."
    } finally {
        [Environment]::SetEnvironmentVariable("HOME", $oldHome, "Process")
    }

    $repoPath = New-TempGitRepo $TempRoot
    try {
        Set-EntryValue $EntryPath "GIT_ID_SIGNING_KEY" "test-signing-key"
        Set-EntryValue $EntryPath "GIT_ID_GPG_FORMAT" "SSH"
        Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "signing-on sync" }
        Assert-True ((Get-LocalValue $repoPath "user.signingkey") -eq "test-signing-key") "signing-on sync should persist the bound key."
        Assert-True ((Get-LocalValue $repoPath "gpg.format") -eq "ssh") "signing-on sync should persist the normalized format."
        Assert-True ((Get-LocalValue $repoPath "commit.gpgSign") -eq "true") "signing-on sync should enable automatic commit signing."
        Assert-True ((Get-LocalValue $repoPath "tag.gpgSign") -eq "false") "commit signing should not implicitly enable tag signing."

        Set-EntryValue $EntryPath "GIT_ID_SIGNING_KEY" ""
        Set-EntryValue $EntryPath "GIT_ID_GPG_FORMAT" ""
        Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync") 0 "signing on-to-off sync" }
        Assert-True ($null -eq (Get-LocalValue $repoPath "user.signingkey")) "switching signing off should remove the old managed key."
        Assert-True ($null -eq (Get-LocalValue $repoPath "gpg.format")) "switching signing off should remove the old managed format."
        Assert-True ($null -eq (Get-LocalValue $repoPath "swaw-kit-git.signing-key")) "switching signing off should remove the old key marker."
        Assert-True ($null -eq (Get-LocalValue $repoPath "swaw-kit-git.gpg-format")) "switching signing off should remove the old format marker."
        Assert-True ((Get-LocalValue $repoPath "commit.gpgSign") -eq "false") "switching signing off should persist the disabled commit state."

        Invoke-InDirectory $repoPath { $null = Invoke-Captured $EntryPath @(".sync", "--clear") 0 "clear signing-off sync" }
        Assert-True ($null -eq (Get-LocalValue $repoPath "commit.gpgSign")) "clear should remove the signing state written by sync."
        Assert-True ($null -eq (Get-LocalValue $repoPath "swaw-kit-git.commit-gpg-sign")) "clear should remove the signing marker."
    } finally {
        Set-EntryValue $EntryPath "GIT_ID_SIGNING_KEY" ""
        Set-EntryValue $EntryPath "GIT_ID_GPG_FORMAT" ""
    }

    Set-DirectSyncIdentity "ssh" $TempRoot
    try {
        $invalidRepo = New-TempGitRepo $TempRoot
        $before = Get-LocalSemanticState $invalidRepo
        $env:GIT_ID_SIGNING_KEY = "partial-signing-key"
        Remove-Item Env:GIT_ID_GPG_FORMAT -ErrorAction SilentlyContinue
        $output = Invoke-DirectSync $invalidRepo $EntryPath "write" 0 1
        Assert-True ($output.Contains("must be configured together")) "direct sync should defensively reject a partial signing configuration."
        Assert-True ((Get-LocalSemanticState $invalidRepo) -ceq $before) "partial signing validation must not mutate local config."

        $env:GIT_ID_GPG_FORMAT = "invalid-format"
        $output = Invoke-DirectSync $invalidRepo $EntryPath "write" 0 1
        Assert-True ($output.Contains("Invalid GIT_ID_GPG_FORMAT")) "direct sync should defensively reject an invalid signing format."
        Assert-True ((Get-LocalSemanticState $invalidRepo) -ceq $before) "invalid signing validation must not mutate local config."

        $rollbackRepo = New-TempGitRepo $TempRoot
        $env:GIT_ID_SIGNING_KEY = "rollback-signing-key"
        $env:GIT_ID_GPG_FORMAT = "ssh"
        $before = Get-LocalSemanticState $rollbackRepo
        $output = Invoke-DirectSync $rollbackRepo $EntryPath "write" 16
        Assert-InjectedMutationWasRolledBack $output $before $rollbackRepo "signing-key write failure"
    } finally {
        Remove-Item Env:GIT_ID_SIGNING_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_ID_GPG_FORMAT -ErrorAction SilentlyContinue
    }
}

function Test-SyncMutationRollback {
    param([string]$EntryPath, [string]$TempRoot)

    $identityEnvironmentNames = @(
        "GIT_ID_NAME", "GIT_ID_EMAIL", "GIT_ID_ACCESS", "GIT_ID_TRANSPORT",
        "GIT_ID_HTTPS_HOST", "GIT_ID_HTTPS_ACCOUNT", "GIT_ID_HTTPS_CREDENTIAL_HELPER", "GIT_ID_CREDENTIAL_NAMESPACE",
        "GIT_ID_HTTPS_PROVIDER", "GIT_ID_HTTPS_CREDENTIAL_USER", "GIT_SSH_COMMAND",
        "GIT_ID_SIGNING_KEY", "GIT_ID_GPG_FORMAT"
    )
    $savedEnvironment = @{}
    foreach ($name in $identityEnvironmentNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        Set-DirectSyncIdentity "ssh" $TempRoot
        foreach ($failAt in @(2, 13, 28)) {
            $repoPath = New-TempGitRepo $TempRoot
            $before = Get-LocalSemanticState $repoPath
            $output = Invoke-DirectSync $repoPath $EntryPath "write" $failAt
            Assert-InjectedMutationWasRolledBack $output $before $repoPath "first sync failure at operation $failAt"
        }

        foreach ($failAt in @(2, 24, 55)) {
            $repoPath = New-TempGitRepo $TempRoot
            Set-DirectSyncIdentity "ssh" $TempRoot
            $null = Invoke-DirectSync $repoPath $EntryPath "write"
            $before = Get-LocalSemanticState $repoPath
            Set-DirectSyncIdentity "https" $TempRoot
            $output = Invoke-DirectSync $repoPath $EntryPath "write" $failAt
            Assert-InjectedMutationWasRolledBack $output $before $repoPath "SSH-to-HTTPS failure at operation $failAt"
        }

        foreach ($failAt in @(2, 7, 11)) {
            $repoPath = New-TempGitRepo $TempRoot
            Set-DirectSyncIdentity "https" $TempRoot
            $null = Invoke-DirectSync $repoPath $EntryPath "write"
            git -C $repoPath config --local --add swaw-kit-git.rollback-order first
            Assert-ExitCode $LASTEXITCODE 0 "write first unknown marker value"
            git -C $repoPath config --local --add swaw-kit-git.rollback-order second
            Assert-ExitCode $LASTEXITCODE 0 "write second unknown marker value"
            $before = Get-LocalSemanticState $repoPath
            $output = Invoke-DirectSync $repoPath $EntryPath "clear" $failAt
            Assert-InjectedMutationWasRolledBack $output $before $repoPath "clear failure at operation $failAt"
        }
    } finally {
        foreach ($name in $identityEnvironmentNames) {
            $value = $savedEnvironment[$name]
            if ($null -eq $value) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $value, "Process")
            }
        }
    }
}

$tempRoot = Join-Path $tempBase ("git-sync-smoke-" + [guid]::NewGuid().ToString("N"))
$entryPath = $null
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $entryPath = New-SyncEntry $tempRoot
    Test-SyncDryRunAndRepositoryBoundary $entryPath $tempRoot
    Test-SyncWritesAndClearsOwnedValues $entryPath $tempRoot
    Test-FirstSyncRefusesExistingLocalConflicts $entryPath $tempRoot
    Test-ManagedSyncAllowsIntentionalIdentitySwitch $entryPath $tempRoot
    Test-SyncClearRequiresExactOwner $entryPath $tempRoot
    Test-SyncClearRefusesChangedValues $entryPath $tempRoot
    Test-SyncDiagnosticsRedactSensitiveCommands $entryPath $tempRoot
    Test-SyncIgnoresRepositoryRedirectEnvironment $entryPath $tempRoot
    Test-ClearRejectsIncompleteHttpsMarkerSchema $entryPath $tempRoot
    Test-GitConfigFailuresCannotReportSuccess $entryPath $tempRoot
    Test-SyncSigningState $entryPath $tempRoot
    Test-SyncMutationRollback $entryPath $tempRoot
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-SwawKitTestTemplateEntry -RepoRoot $repoRoot -EntryPath $entryTemplate
}
