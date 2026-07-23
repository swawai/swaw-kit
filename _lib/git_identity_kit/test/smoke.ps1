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

    $output = (& $File @CommandArgs 2>&1 | Out-String)
    if ($LASTEXITCODE -ne $ExpectedExitCode) {
        throw "$Label failed: expected exit code $ExpectedExitCode, got $LASTEXITCODE.`n$output"
    }
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

function New-GitSmokeEntryFile {
    param([string]$TempRoot)

    $entryName = "git.smoke-" + [guid]::NewGuid().ToString("N")
    $path = Join-Path $TempRoot "$entryName.cmd"
    $keyPath = Join-Path $TempRoot "smoke id_ed25519"
    [System.IO.File]::WriteAllText($keyPath, "not a real private key`r`n", [System.Text.UTF8Encoding]::new($false))

    $content = [System.IO.File]::ReadAllText($entryFile)
    $content = Set-EntryLine $content "GIT_ID_NAME" "Smoke User"
    $content = Set-EntryLine $content "GIT_ID_EMAIL" "smoke@example.invalid"
    $content = Set-EntryLine $content "GIT_ID_ACCESS" "ssh:ssh -o IdentitiesOnly=yes -i '$keyPath'"
    $content = Set-EntryLine $content "GIT_ID_KIT" (Join-Path $repoRoot "_lib\git_identity_kit\kit.cmd")
    $content = $content.Replace("%~dp0_lib\editor_kit\entry-bootstrap.cmd", (Join-Path $repoRoot "_lib\editor_kit\entry-bootstrap.cmd"))
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
    $bootstrapIndex = $content.IndexOf("_lib\editor_kit\entry-bootstrap.cmd", [StringComparison]::OrdinalIgnoreCase)
    $identityIndex = $content.IndexOf('set "GIT_ID_NAME=', [StringComparison]::OrdinalIgnoreCase)
    Assert-True ($bootstrapIndex -ge 0 -and $bootstrapIndex -lt $identityIndex) "entry bootstrap should run before the visible identity settings."
    Assert-True ($content.Contains("GIT_ID_NAME")) "entry template should expose GIT_ID_NAME."
    Assert-True ($content.Contains("GIT_ID_EMAIL")) "entry template should expose GIT_ID_EMAIL."
    Assert-True ($content.Contains("GIT_ID_ACCESS")) "entry template should expose one access descriptor."
    Assert-True ($content.Contains("GIT_ID_SIGNING_KEY")) "entry template should expose the signing key setting."
    Assert-True ($content.Contains("openpgp / ssh / x509")) "entry template should document the complete signing format set."
    Assert-True (-not $content.Contains('set "GIT_SSH_COMMAND=')) "entry template should derive native GIT_SSH_COMMAND internally."
    Assert-True (-not $content.Contains('set "GIT_SSH_VARIANT=')) "entry template should keep the OpenSSH variant internal."
    Assert-True ($content.Contains("GIT_ID_DEFAULT_TERMINAL")) "entry template should expose GIT_ID_DEFAULT_TERMINAL."
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

function Get-HelpCommandSignatures {
    param([string]$Template)

    $commands = foreach ($line in @($Template -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s+\{\{COMMAND\}\}(?<tail>.*)$')
        if (-not $match.Success) { continue }

        $tail = $match.Groups["tail"].Value
        if ($tail -match '^\s{2,}') {
            '<default>'
            continue
        }

        $signature = ($tail.TrimStart() -split '\s{2,}', 2)[0]
        # Argument labels are prose and may be localized; their position in
        # the command grammar is what must stay aligned across translations.
        $signature -replace '\[[^\]]+\]', '[ARG]'
    }
    return @($commands | Sort-Object)
}

function Test-HelpUsesWrapperHelp {
    param([string]$EntryPath)

    $commandName = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    try {
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_HELP_LANG" "en"
        $output = Invoke-Captured $EntryPath @("--help") 0 "wrapper help"
        Assert-True ($output.Contains("Git identity")) "help should describe the wrapper instead of raw git help."
        Assert-True ($output.Contains($commandName)) "help should use the entry command name."
        Assert-True ($output.Contains(".help zh")) "English help should document the Chinese help entry."
        Assert-True ($output.Contains(".help en")) "English help should document the English help entry."
        Assert-True ($output.IndexOf(".help zh") -lt $output.IndexOf(".help en")) "English help should list the non-current Chinese language first."
        $englishTemplate = [System.IO.File]::ReadAllText((Join-Path $repoRoot "_lib\git_identity_kit\help\en.txt"), [System.Text.Encoding]::UTF8)
        $chineseTemplate = [System.IO.File]::ReadAllText((Join-Path $repoRoot "_lib\git_identity_kit\help\zh-CN.txt"), [System.Text.Encoding]::UTF8)
        $signatureDiff = @(Compare-Object (Get-HelpCommandSignatures $englishTemplate) (Get-HelpCommandSignatures $chineseTemplate))
        Assert-True ($signatureDiff.Count -eq 0) "English and Chinese help should expose the same command signatures."
        Assert-True ($englishTemplate -match '(?m)^  \{\{COMMAND\}\} \.help zh\s+[^\x00-\x7F]+$') "the Chinese help switch should describe itself in Chinese."
        Assert-True ($chineseTemplate.Contains("{{COMMAND}} .help en             Show English help.")) "the English help switch should describe itself in English."
        Assert-True ($output.Contains(".info")) "help should document the identity diagnostic command."
        Assert-True ($output.Contains(".sync --dry-run")) "help should document sync dry-run."
        Assert-True ($output.Contains(".sync --clear")) "help should document conservative sync clear."
        Assert-True ($output.Contains(".origin ssh")) "help should document origin conversion to SSH."
        Assert-True ($output.Contains(".origin https")) "help should document origin conversion to HTTPS."
        Assert-True ($output.Contains("Rewrite the current repository's single origin URL (identity and credentials are unchanged):")) "English help should define .origin as URL-only rewriting."
        Assert-True ($output.Contains(".code")) "help should document editor launchers."
        Assert-True ($output.Contains(".powershell")) "help should document the canonical Windows PowerShell launcher."
        Assert-True ($output.Contains(".gitbash")) "help should document the Git Bash launcher."
        Assert-True (-not $output.Contains(" whoami")) "help should not advertise bare custom commands."
        Assert-True ($output.Contains("Persist the bound identity and remote access settings to the current repository (for other tools):")) "English help should mirror the Chinese sync section."
        Assert-True ($output.Contains("Editor and terminal launchers:")) "English help should mirror the Chinese launcher section."
        Assert-True ($output.Contains("Custom commands start with a dot.")) "English help should mirror the Chinese passthrough rule."
        Assert-True ($output.Contains("Create another identity command (using git2.cmd as an example):")) "English help should mirror the Chinese identity-creation section."
        Assert-True ($output.Contains("copy git1.cmd git2.cmd")) "English help should show the same identity-copy example as Chinese help."
        Assert-True (-not $output.Contains("This wrapper injects process-local Git config")) "English help should not add implementation details missing from Chinese help."
        Assert-True (-not $output.Contains("If an editor is already running")) "English help should not add editor caveats missing from Chinese help."
        Assert-True (-not $output.Contains("Then edit these lines")) "English help should not add identity setup details missing from Chinese help."

        $launcherIndex = $output.IndexOf("Editor and terminal launchers:")
        $passthroughIndex = $output.IndexOf("Custom commands start with a dot.")
        Assert-True ($launcherIndex -ge 0) "help should include the launcher section."
        Assert-True ($passthroughIndex -gt $launcherIndex) "help should explain passthrough after custom dot commands."

        Set-GitSmokeEntryValue $EntryPath "GIT_ID_HELP_LANG" "zh-CN"
        $zhOutput = Invoke-Captured $EntryPath @("--help") 0 "Chinese wrapper help"
        Assert-True ($zhOutput.Contains("Show English help.")) "the English help switch should describe itself in English."
        Assert-True ($zhOutput -match '\u91cd\u5199\u5f53\u524d\u4ed3\u5e93\u552f\u4e00\u7684 origin URL\uFF08\u4e0d\u4fee\u6539\u8eab\u4efd\u6216\u51ed\u636e\uFF09:') "Chinese help should define .origin as URL-only rewriting."
        Assert-True ($zhOutput.IndexOf(".help en") -lt $zhOutput.IndexOf(".help zh")) "Chinese help should list the non-current English language first."
        $enOutput = Invoke-Captured $EntryPath @(".help", "en") 0 ".help en"
        Assert-True ($enOutput.Contains("Help and status:")) ".help en should force English help."

        $invalidLanguage = Invoke-Captured $EntryPath @(".help", "invalid") 1 ".help invalid language"
        Assert-True ($invalidLanguage.Contains("Use")) "an invalid explicit help language should show the supported syntax."
        $extraArgument = Invoke-Captured $EntryPath @(".help", "en", "extra") 1 ".help extra argument"
        Assert-True ($extraArgument.Contains("Use")) "help should reject extra arguments."

        Set-GitSmokeEntryValue $EntryPath "GIT_ID_HELP_LANG" "invalid"
        $invalidConfiguredLanguage = Invoke-Captured $EntryPath @("--help") 1 "invalid configured help language"
        Assert-True ($invalidConfiguredLanguage.Contains("[ERROR] Unsupported help language")) "an invalid configured help language should fail clearly."
        foreach ($prefixCollision in @("english", "zhorse")) {
            Set-GitSmokeEntryValue $EntryPath "GIT_ID_HELP_LANG" $prefixCollision
            $prefixCollisionOutput = Invoke-Captured $EntryPath @("--help") 1 "invalid prefixed help language"
            Assert-True ($prefixCollisionOutput.Contains("[ERROR] Unsupported help language")) "help language matching must accept complete language tags, not arbitrary en/zh prefixes."
        }
    } finally {
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_HELP_LANG" ""
    }
}

function Test-GitCommandsUseBoundIdentity {
    param([string]$EntryPath)

    $workDir = Join-Path $tempBase ("git-id-work-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $workDir | Out-Null
    try {
        Push-Location $workDir
        try {
            $name = (Invoke-Captured $EntryPath @("config", "--get", "user.name") 0 "git config user.name").Trim()
            $email = (Invoke-Captured $EntryPath @("config", "--get", "user.email") 0 "git config user.email").Trim()
            $ident = Invoke-Captured $EntryPath @("var", "GIT_AUTHOR_IDENT") 0 "git author ident"
        } finally {
            Pop-Location
        }

        Assert-True ($name -eq "Smoke User") "git config should see the bound user.name."
        Assert-True ($email -eq "smoke@example.invalid") "git config should see the bound user.email."
        Assert-True ($ident.Contains("Smoke User <smoke@example.invalid>")) "git var should see the bound author identity."
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-SigningRuntimeBoundary {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $repoPath = New-TempGitRepo $TempRoot
    git -C $repoPath config --local commit.gpgSign true
    Assert-ExitCode $LASTEXITCODE 0 "set inherited commit signing"
    git -C $repoPath config --local tag.gpgSign true
    Assert-ExitCode $LASTEXITCODE 0 "set inherited tag signing"
    git -C $repoPath config --local user.signingkey "foreign-signing-key"
    Assert-ExitCode $LASTEXITCODE 0 "set inherited signing key"
    git -C $repoPath config --local gpg.format x509
    Assert-ExitCode $LASTEXITCODE 0 "set inherited signing format"

    try {
        $disabledCommit = Invoke-InDirectory $repoPath { (Invoke-Captured $EntryPath @("config", "--get", "commit.gpgSign") 0 "disabled commit signing").Trim() }
        $disabledTag = Invoke-InDirectory $repoPath { (Invoke-Captured $EntryPath @("config", "--get", "tag.gpgSign") 0 "disabled tag signing").Trim() }
        $disabledInfo = Invoke-InDirectory $repoPath { Invoke-Captured $EntryPath @(".info") 0 "disabled signing info" }
        Assert-True ($disabledCommit -eq "false") "empty signing settings should override inherited commit.gpgSign with false."
        Assert-True ($disabledTag -eq "false") "empty signing settings should override inherited tag.gpgSign with false."
        Assert-True ($disabledInfo -match '(?m)^  Commit signing:[ ]+disabled\r?$') ".info should report authoritative disabled commit signing."
        Assert-True (-not $disabledInfo.Contains("Signing key:")) ".info should not display an inherited signing key while signing is disabled."

        Set-GitSmokeEntryValue $EntryPath "GIT_ID_SIGNING_KEY" "smoke-signing-key"
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_GPG_FORMAT" ""
        $keyOnly = Invoke-InDirectory $repoPath { Invoke-Captured $EntryPath @("status") 1 "signing key without format" }
        Assert-True ($keyOnly.Contains("Incomplete commit signing configuration")) "a signing key without a format should fail before Git dispatch."

        Set-GitSmokeEntryValue $EntryPath "GIT_ID_SIGNING_KEY" ""
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_GPG_FORMAT" "ssh"
        $formatOnly = Invoke-InDirectory $repoPath { Invoke-Captured $EntryPath @("status") 1 "signing format without key" }
        Assert-True ($formatOnly.Contains("Incomplete commit signing configuration")) "a signing format without a key should fail before Git dispatch."

        Set-GitSmokeEntryValue $EntryPath "GIT_ID_SIGNING_KEY" "smoke-signing-key"
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_GPG_FORMAT" "invalid"
        $invalidFormat = Invoke-InDirectory $repoPath { Invoke-Captured $EntryPath @("status") 1 "invalid signing format" }
        Assert-True ($invalidFormat.Contains("Invalid GIT_ID_GPG_FORMAT")) "an unsupported signing format should fail before Git dispatch."

        foreach ($formatCase in @(
            [pscustomobject]@{ EntryValue = "openpgp"; EffectiveValue = "openpgp" },
            [pscustomobject]@{ EntryValue = "SSH"; EffectiveValue = "ssh" },
            [pscustomobject]@{ EntryValue = "x509"; EffectiveValue = "x509" }
        )) {
            Set-GitSmokeEntryValue $EntryPath "GIT_ID_SIGNING_KEY" "smoke-signing-key"
            Set-GitSmokeEntryValue $EntryPath "GIT_ID_GPG_FORMAT" $formatCase.EntryValue
            $effectiveKey = Invoke-InDirectory $repoPath { (Invoke-Captured $EntryPath @("config", "--get", "user.signingkey") 0 "enabled signing key").Trim() }
            $effectiveFormat = Invoke-InDirectory $repoPath { (Invoke-Captured $EntryPath @("config", "--get", "gpg.format") 0 "enabled signing format").Trim() }
            $enabledCommit = Invoke-InDirectory $repoPath { (Invoke-Captured $EntryPath @("config", "--get", "commit.gpgSign") 0 "enabled commit signing").Trim() }
            $enabledTag = Invoke-InDirectory $repoPath { (Invoke-Captured $EntryPath @("config", "--get", "tag.gpgSign") 0 "enabled tag signing").Trim() }
            Assert-True ($effectiveKey -eq "smoke-signing-key") "enabled signing should override an inherited signing key."
            Assert-True ($effectiveFormat -ceq $formatCase.EffectiveValue) "enabled signing should normalize and inject the selected format."
            Assert-True ($enabledCommit -eq "true") "enabled signing should force commit.gpgSign=true."
            Assert-True ($enabledTag -eq "false") "enabled signing should keep automatic tag signing disabled."
        }

        $enabledInfo = Invoke-InDirectory $repoPath { Invoke-Captured $EntryPath @(".info") 0 "enabled signing info" }
        Assert-True ($enabledInfo -match '(?m)^  Commit signing:[ ]+enabled \(x509\)\r?$') ".info should report the enabled signing format."
        Assert-True ($enabledInfo -match '(?m)^  Signing key:[ ]+smoke-signing-key\r?$') ".info should retain the configured signing key when enabled."
    } finally {
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_SIGNING_KEY" ""
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_GPG_FORMAT" ""
    }
}

function Test-EntryGitSshCommandWins {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "git-ssh-override-bin"
    $oldGitSshCommand = $env:GIT_SSH_COMMAND
    $oldGitSshVariant = $env:GIT_SSH_VARIANT
    $oldPath = $env:PATH
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakeGitContent = @'
@echo off
echo SSH:%GIT_SSH_COMMAND%
echo SSH_VARIANT:%GIT_SSH_VARIANT%
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $binDir "git.cmd"), $fakeGitContent, [System.Text.UTF8Encoding]::new($false))
    try {
        $env:GIT_SSH_COMMAND = "ssh -F C:\tmp\custom-ssh-config"
        $env:GIT_SSH_VARIANT = "plink"
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @("status") 0 "entry git ssh command"

        Assert-True ($output.Contains("SSH:ssh -o IdentitiesOnly=yes -i '$TempRoot\smoke id_ed25519'")) "the entry GIT_SSH_COMMAND should override an inherited value."
        Assert-True (-not $output.Contains("custom-ssh-config")) "the entry command should not inherit an external GIT_SSH_COMMAND."
        Assert-True ($output.Contains("SSH_VARIANT:ssh")) "the kit should force OpenSSH semantics instead of inheriting an external variant."
    } finally {
        $env:GIT_SSH_COMMAND = $oldGitSshCommand
        $env:GIT_SSH_VARIANT = $oldGitSshVariant
        $env:PATH = $oldPath
    }
}

function Test-InfoShowsIdentityStatus {
    param([string]$EntryPath, [string]$TempRoot)
    $output = Invoke-Captured $EntryPath @(".info") 0 ".info"
    Assert-True ($output -match '(?m)^Config:\r?$') ".info should start the configured identity section."
    Assert-True ($output -match "(?m)^  Entry:[ ]+$([regex]::Escape($EntryPath))\r?$") ".info should show the indented entry file row."
    Assert-True ($output -match '(?m)^  Name:[ ]+Smoke User\r?$') ".info should show the configured name row."
    Assert-True ($output -match '(?m)^  Email:[ ]+smoke@example\.invalid\r?$') ".info should show the configured email row."
    Assert-True ($output -match '(?m)^  Access:[ ]+ssh\r?$') ".info should show the canonical SSH access tag."
    Assert-True ($output -match '(?m)^  SSH command:[ ]+configured\r?$') ".info should confirm SSH command configuration without printing a free-form command that may contain secrets."
    Assert-True ($output -match '(?m)^  Commit signing:[ ]+disabled\r?$') ".info should show that empty signing settings authoritatively disable commit signing."
    Assert-True (-not $output.Contains("IdentitiesOnly=yes")) ".info should not copy SSH command arguments into terminal logs."
    Assert-True (-not $output.Contains("HTTPS authorization:")) ".info should not show HTTPS status for an SSH identity."
    Assert-True ($output -match '(?m)^Git sees:\r?\n  Name:[ ]+Smoke User\r?\n  Email:[ ]+smoke@example\.invalid\r?$') "Git diagnostics should retain the aligned name and email labels."
    $invalid = Invoke-Captured $EntryPath @(".info", "--unexpected") 1 ".info invalid option"
    Assert-True ($invalid.Contains("Unrecognized .info option: --unexpected")) ".info should reject unexpected options."
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

    $binDir = Join-Path $TempRoot "editor-dispatch-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakePowerShell = Join-Path $binDir "PowerShell.cmd"
    $fakePowerShellContent = @'
@echo off
echo POWERSHELL_ARGS:%*
echo AUTHOR:%GIT_AUTHOR_NAME%
echo SSH:%GIT_SSH_COMMAND%
echo BOOTSTRAP_FLAG:%WIN_RUN_EDITOR_BOOTSTRAP%
echo %* | findstr /i /c:"entry-bootstrap.ps1" >nul
if errorlevel 1 exit /b 0
if defined SMOKE_BOOTSTRAP_EXIT exit /b %SMOKE_BOOTSTRAP_EXIT%
exit /b 10
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakePowerShell, $fakePowerShellContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    $oldBootstrapExit = [Environment]::GetEnvironmentVariable("SMOKE_BOOTSTRAP_EXIT")
    try {
        $env:PATH = "$binDir;$oldPath"
        $codeOutput = Invoke-Captured $EntryPath @(".code", $TempRoot) 0 ".code dispatch"
        Assert-True ($codeOutput.Contains("editor-launch.ps1")) ".code should dispatch through the identity-aware editor launcher."
        Assert-True ($codeOutput.Contains("entry-bootstrap.ps1")) ".code should run the identity-free editor bootstrap before identity preparation."
        Assert-True ($codeOutput.Contains('-ForbiddenEnvironmentVariable "GIT_ID_ENTRY_FILE"')) "the Git entry should supply its environment guard to the shared bootstrap."
        Assert-True ($codeOutput -match '-Tool\s+"?code"?') ".code should select VS Code."
        Assert-True ($codeOutput.Contains("-ReuseBootstrapWindow")) ".code should reuse a clean window created by the entry bootstrap."
        $authorLines = @([regex]::Matches($codeOutput, '(?m)^AUTHOR:(?<value>.*)\r?$') | ForEach-Object { $_.Groups['value'].Value.Trim() })
        Assert-True ($authorLines.Count -eq 2 -and $authorLines[0] -eq "" -and $authorLines[1] -eq "Smoke User") "the bootstrap must run before the entry injects its author identity."
        Assert-True (-not $codeOutput.Contains("BOOTSTRAP_FLAG:code")) "the internal bootstrap result must be consumed before the editor process starts."
        Assert-True ($codeOutput.Contains("AUTHOR:Smoke User")) ".code should receive the bound author identity."
        Assert-True ($codeOutput.Contains("IdentitiesOnly=yes")) ".code should receive the bound SSH command."
        Assert-True ($codeOutput.Contains($TempRoot)) ".code should forward the target directory."

        $cursorOutput = Invoke-Captured $EntryPath @(".cursor", $TempRoot) 0 ".cursor dispatch"
        Assert-True ($cursorOutput.Contains("editor-launch.ps1")) ".cursor should use the same identity-aware editor launcher."
        Assert-True ($cursorOutput -match '-Tool\s+"?cursor"?') ".cursor should select Cursor."
        Assert-True ($cursorOutput.Contains("-ReuseBootstrapWindow")) ".cursor should reuse a clean window created by the entry bootstrap."

        $env:SMOKE_BOOTSTRAP_EXIT = "7"
        $failureOutput = Invoke-Captured $EntryPath @(".code", $TempRoot) 7 ".code bootstrap failure"
        Assert-True (-not $failureOutput.Contains("editor-launch.ps1")) "a bootstrap failure must stop before identity preparation and editor launch."
    } finally {
        [Environment]::SetEnvironmentVariable("SMOKE_BOOTSTRAP_EXIT", $oldBootstrapExit)
        $env:PATH = $oldPath
    }
}

function Test-GitBashLauncherDispatchesWithBoundIdentity {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "gitbash-dispatch-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakePowerShell = Join-Path $binDir "PowerShell.cmd"
    $fakePowerShellContent = @'
@echo off
echo POWERSHELL_ARGS:%*
echo AUTHOR:%GIT_AUTHOR_NAME%
echo SSH:%GIT_SSH_COMMAND%
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakePowerShell, $fakePowerShellContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @(".gitbash") 0 ".gitbash launcher"

        Assert-True ($output.Contains("launch.ps1")) ".gitbash should dispatch through the shared launcher."
        Assert-True ($output -match '-Tool\s+"?gitbash"?') ".gitbash should select the Git Bash launcher."
        Assert-True ($output.Contains("AUTHOR:Smoke User")) ".gitbash should inherit the bound author identity."
        Assert-True ($output.Contains("IdentitiesOnly=yes")) ".gitbash should inherit the bound SSH access command."
    } finally {
        $env:PATH = $oldPath
    }
}

function Test-EmptyArgsLaunchBoundCmd {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    $binDir = Join-Path $TempRoot "empty-args-powershell-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakePowerShell = Join-Path $binDir "PowerShell.cmd"
    $fakePowerShellContent = @'
@echo off
echo POWERSHELL_ARGS:%*
echo NAME:
git config --get user.name
echo EMAIL:
git config --get user.email
echo SSH:%GIT_SSH_COMMAND%
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakePowerShell, $fakePowerShellContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @() 0 "empty args launcher"

        Assert-True ($output.Contains("-File")) "empty args should dispatch to the launcher script instead of raw git help."
        Assert-True ($output.Contains("-Tool")) "empty args should pass the launcher tool option."
        Assert-True ($output.Contains("cmd")) "empty args should launch the cmd tool by default."
        Assert-True ($output.Contains("Smoke User")) "empty args cmd launcher should inherit bound user.name."
        Assert-True ($output.Contains("smoke@example.invalid")) "empty args cmd launcher should inherit bound user.email."
        Assert-True ($output.Contains("IdentitiesOnly=yes")) "empty args cmd launcher should inherit GIT_SSH_COMMAND."
    } finally {
        $env:PATH = $oldPath
    }
}

function Test-EmptyArgsLaunchConfiguredTerminal {
    param(
        [string]$EntryPath,
        [string]$TempRoot
    )

    Set-GitSmokeEntryValue $EntryPath "GIT_ID_DEFAULT_TERMINAL" "pwsh"

    $binDir = Join-Path $TempRoot "empty-args-configured-terminal-bin"
    New-Item -ItemType Directory -Path $binDir | Out-Null
    $fakePowerShell = Join-Path $binDir "PowerShell.cmd"
    $fakePowerShellContent = @'
@echo off
echo POWERSHELL_ARGS:%*
echo NAME:
git config --get user.name
echo EMAIL:
git config --get user.email
echo SSH:%GIT_SSH_COMMAND%
exit /b 0
'@ -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($fakePowerShell, $fakePowerShellContent, [System.Text.UTF8Encoding]::new($false))

    $oldPath = $env:PATH
    try {
        $env:PATH = "$binDir;$oldPath"
        $output = Invoke-Captured $EntryPath @() 0 "configured empty args launcher"

        Assert-True ($output.Contains("-Tool")) "configured empty args should pass the launcher tool option."
        Assert-True ($output.Contains("pwsh")) "configured empty args should launch the configured terminal."
        Assert-True (-not $output.Contains(" cmd ")) "configured empty args should not hard-code cmd."
        Assert-True ($output.Contains("Smoke User")) "configured empty args launcher should inherit bound user.name."
        Assert-True ($output.Contains("smoke@example.invalid")) "configured empty args launcher should inherit bound user.email."
        Assert-True ($output.Contains("IdentitiesOnly=yes")) "configured empty args launcher should inherit GIT_SSH_COMMAND."
    } finally {
        $env:PATH = $oldPath
        Set-GitSmokeEntryValue $EntryPath "GIT_ID_DEFAULT_TERMINAL" ""
    }
}

$tempRoot = Join-Path $tempBase ("git-id-smoke-" + [guid]::NewGuid().ToString("N"))
$smokeEntry = $null
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Test-EntryTemplateShape
    Test-CommandLineEndings
    $smokeEntry = New-GitSmokeEntryFile $tempRoot
    Test-HelpUsesWrapperHelp $smokeEntry
    Test-GitCommandsUseBoundIdentity $smokeEntry
    Test-SigningRuntimeBoundary $smokeEntry $tempRoot
    Test-EntryGitSshCommandWins $smokeEntry $tempRoot
    Test-InfoShowsIdentityStatus $smokeEntry $tempRoot
    Test-BareCustomWordsPassThroughToGit $smokeEntry $tempRoot
    Test-EditorLauncherInheritsBoundIdentity $smokeEntry $tempRoot
    Test-GitBashLauncherDispatchesWithBoundIdentity $smokeEntry $tempRoot
    Test-EmptyArgsLaunchBoundCmd $smokeEntry $tempRoot
    Test-EmptyArgsLaunchConfiguredTerminal $smokeEntry $tempRoot
} finally {
    if ($smokeEntry -and (Test-Path -LiteralPath $smokeEntry)) {
        Remove-Item -LiteralPath $smokeEntry -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
