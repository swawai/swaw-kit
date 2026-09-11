[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $repoRoot '_lib\test_support\template-entry.ps1')
$entryPath = New-SwawKitTestTemplateEntry `
    -RepoRoot $repoRoot `
    -TemplateName 'template.gh1.cmd' `
    -EntryName 'test.template.gh1.cmd'
$tempRoot = Join-Path (Join-Path $repoRoot 'temp_workspace') ("gh-kit-$([Guid]::NewGuid().ToString('N'))")
$originalPath = $env:PATH
$tokenNames = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')
$savedTokens = @{}
$automationNames = @(
    'GH_PROMPT_DISABLED',
    'GH_PAGER',
    'GH_SPINNER_DISABLED',
    'GH_NO_UPDATE_NOTIFIER',
    'GH_NO_EXTENSION_UPDATE_NOTIFIER',
    'NO_COLOR',
    'GH_FORCE_TTY',
    'CLICOLOR_FORCE',
    'GIT_TERMINAL_PROMPT',
    'GCM_INTERACTIVE'
)
$savedAutomationEnvironment = @{}
$selectionLogName = 'SWAW_GH_TEST_SELECTION_LOG'
$savedSelectionLog = [Environment]::GetEnvironmentVariable($selectionLogName)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)
    Assert-True ($Text.Contains($Expected)) "$Message`nExpected: $Expected`nOutput:`n$Text"
}

function Set-EntryLine {
    param([string]$Content, [string]$Name, [string]$Value)
    $pattern = '(?m)^set "' + [regex]::Escape($Name) + '=.*"\r?$'
    Assert-True ($Content -match $pattern) "Entry template should declare $Name."
    $line = 'set "' + $Name + '=' + $Value + '"'
    return [regex]::Replace($Content, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match) $line
    })
}

function Invoke-Entry {
    param(
        [string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )
    $output = (& cmd.exe /d /c $entryPath @Arguments 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $ExpectedExitCode) {
        throw "Entry returned $exitCode; expected $ExpectedExitCode.`n$output"
    }
    return $output
}

function Test-Crlf {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) {
            Assert-True ($i -gt 0 -and $bytes[$i - 1] -eq 13) "$Path must use CRLF line endings."
        }
    }
}

try {
    foreach ($name in $tokenNames) {
        $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    foreach ($name in $automationNames) {
        $savedAutomationEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $fakeBin = Join-Path $tempRoot 'fake-bin'
    $profileDir = Join-Path $tempRoot 'profile'
    $selectionLog = Join-Path $tempRoot 'account-selection.log'
    [void][IO.Directory]::CreateDirectory($fakeBin)
    [Environment]::SetEnvironmentVariable($selectionLogName, $selectionLog)

    $content = [IO.File]::ReadAllText($entryPath)
    Assert-Contains $content 'set "GH_HOST=' 'Template should expose GH_HOST.'
    Assert-Contains $content 'set "GH_ID_ACCOUNT=' 'Template should expose GH_ID_ACCOUNT.'
    Assert-Contains $content 'set "GH_CONFIG_DIR=' 'Template should expose GH_CONFIG_DIR.'
    Assert-Contains $content 'set "GH_ID_GIT_PROTOCOL=https"' 'Template should expose the default Git protocol.'
    Assert-Contains $content 'set "GH_ID_KIT_PROTOCOL=2"' 'Template should use the current entry protocol.'
    Assert-True (-not $content.Contains('set "GH_REPO=')) 'Account entry must not bind a repository.'
    Assert-True (-not $content.Contains('set "GH_TOKEN=')) 'Entry must not contain a token setting.'
    Assert-True (-not $content.Contains('GH_VERSION')) 'Entry must not own the runtime version.'
    $content = Set-EntryLine $content 'GH_ID_ACCOUNT' 'smoke-user'
    $content = Set-EntryLine $content 'GH_CONFIG_DIR' $profileDir
    $content = $content -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($entryPath, $content, [Text.UTF8Encoding]::new($false))

    $fakeGh = Join-Path $fakeBin 'gh.cmd'
    $fakeContent = @'
@echo off
if /i "%~1"=="api" (
  echo smoke-user
  exit /b 0
)
if /i "%~1"=="auth" if /i "%~2"=="switch" (
  echo %*>>"%SWAW_GH_TEST_SELECTION_LOG%"
  exit /b 0
)
if /i "%~1"=="--version" (
  echo gh version 9.9.9 ^(fake^)
  exit /b 0
)
echo ARGS:%*
echo HOST:%GH_HOST%
echo ACCOUNT:%GH_ID_ACCOUNT%
echo CONFIG:%GH_CONFIG_DIR%
echo PROMPT:^<%GH_PROMPT_DISABLED%^>
echo PAGER:^<%GH_PAGER%^>
echo SPINNER:^<%GH_SPINNER_DISABLED%^>
echo GH_UPDATE:^<%GH_NO_UPDATE_NOTIFIER%^>
echo EXT_UPDATE:^<%GH_NO_EXTENSION_UPDATE_NOTIFIER%^>
echo NO_COLOR:^<%NO_COLOR%^>
echo FORCE_TTY:^<%GH_FORCE_TTY%^>
echo COLOR_FORCE:^<%CLICOLOR_FORCE%^>
echo GIT_PROMPT:^<%GIT_TERMINAL_PROMPT%^>
echo GCM_INTERACTIVE:^<%GCM_INTERACTIVE%^>
exit /b 0
'@ -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($fakeGh, $fakeContent, [Text.Encoding]::ASCII)
    $env:PATH = "$fakeBin;$originalPath"

    Test-Crlf (Join-Path $repoRoot 'Favorites\template.gh1.cmd')
    Test-Crlf (Join-Path $repoRoot '_lib\github_cli_kit\kit.cmd')

    $help = Invoke-Entry @('.help', 'en')
    Assert-Contains $help 'Non-dot commands are passed through to gh.' 'English help should render.'

    $passthrough = Invoke-Entry @('pr', 'list', '--limit', '5')
    Assert-Contains $passthrough 'ARGS:pr list --limit 5' 'Arguments should pass through unchanged.'
    Assert-Contains $passthrough 'HOST:github.com' 'GH_HOST should reach gh.'
    Assert-Contains $passthrough 'ACCOUNT:smoke-user' 'Expected account should reach kit subprocesses.'
    Assert-Contains $passthrough "CONFIG:$profileDir" 'GH_CONFIG_DIR should reach gh.'
    Assert-Contains $passthrough 'PROMPT:<1>' 'Direct gh commands should disable prompts.'
    Assert-Contains $passthrough 'PAGER:<cat>' 'Direct gh commands should disable paging.'
    Assert-Contains $passthrough 'SPINNER:<1>' 'Direct gh commands should disable animated spinners.'
    Assert-Contains $passthrough 'GH_UPDATE:<1>' 'Direct gh commands should disable update notices.'
    Assert-Contains $passthrough 'EXT_UPDATE:<1>' 'Direct gh commands should disable extension update notices.'
    Assert-Contains $passthrough 'NO_COLOR:<1>' 'Direct gh commands should disable color output.'
    Assert-Contains $passthrough 'FORCE_TTY:<>' 'Direct gh commands should clear forced TTY output.'
    Assert-Contains $passthrough 'COLOR_FORCE:<>' 'Direct gh commands should clear forced color output.'
    Assert-Contains $passthrough 'GIT_PROMPT:<0>' 'Direct gh commands should disable Git terminal prompts.'
    Assert-Contains $passthrough 'GCM_INTERACTIVE:<false>' 'Direct gh commands should disable GCM interaction.'

    [IO.File]::WriteAllText($selectionLog, '')
    $authToken = Invoke-Entry @('auth', 'token')
    Assert-Contains $authToken 'ARGS:auth token' 'Auth commands should pass through unchanged.'
    $accountSelection = [IO.File]::ReadAllText($selectionLog)
    Assert-Contains $accountSelection 'auth switch --hostname github.com --user smoke-user' 'Auth commands should select the entry account before execution.'

    $info = Invoke-Entry @('.info')
    Assert-Contains $info 'authenticated as smoke-user' '.info should verify the active account.'
    Assert-Contains $info 'system' '.info should identify the PATH runtime.'

    $doctor = Invoke-Entry @('.doctor')
    Assert-Contains $doctor 'GitHub CLI doctor: PASS' '.doctor should pass with the fake runtime and account.'

    $env:GH_PROMPT_DISABLED = 'inherited'
    $login = Invoke-Entry @('auth', 'login')
    $env:GH_PROMPT_DISABLED = $null
    Assert-Contains $login 'ARGS:auth login --hostname github.com --git-protocol https' 'Login should inject the bound host and Git protocol.'
    Assert-Contains $login 'PROMPT:<>' 'Login should remain interactive even when prompting was disabled in the parent environment.'
    Assert-Contains $login '[OK] Active GitHub account: smoke-user' 'Login should validate the resulting account.'

    $loginWithOptions = Invoke-Entry @('auth', 'login', '--web', '--scopes', 'repo,workflow')
    Assert-Contains $loginWithOptions 'ARGS:auth login --hostname github.com --git-protocol https --web --scopes repo,workflow' 'Login options should remain after bound options.'

    $longHostOverride = Invoke-Entry @('auth', 'login', '--hostname', 'other.example.com') 1
    Assert-Contains $longHostOverride 'Do not pass -h or --hostname' 'Long hostname overrides should be rejected.'

    $shortHostOverride = Invoke-Entry @('auth', 'login', '-hother.example.com') 1
    Assert-Contains $shortHostOverride 'Do not pass -h or --hostname' 'Short hostname overrides should be rejected.'

    $protocolOverride = Invoke-Entry @('auth', 'login', '--git-protocol', 'ssh') 1
    Assert-Contains $protocolOverride 'Do not pass -p or --git-protocol' 'Git protocol overrides should be rejected.'

    $keyPolicyOverride = Invoke-Entry @('auth', 'login', '--skip-ssh-key=false') 1
    Assert-Contains $keyPolicyOverride 'SSH key discovery/upload policy is managed' 'SSH key policy overrides should be rejected.'

    $content = [IO.File]::ReadAllText($entryPath)
    $content = Set-EntryLine $content 'GH_ID_GIT_PROTOCOL' 'ssh'
    $content = $content -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($entryPath, $content, [Text.UTF8Encoding]::new($false))
    $sshLogin = Invoke-Entry @('auth', 'login')
    Assert-Contains $sshLogin 'ARGS:auth login --hostname github.com --git-protocol ssh --skip-ssh-key' 'SSH login should suppress gh SSH key management.'

    $terminal = Invoke-Entry @('.cmd', '/d', '/c', 'gh', '--version')
    Assert-Contains $terminal 'gh version 9.9.9 (fake)' 'Identity terminal should expose the selected gh runtime.'

    $terminalEnvironment = Invoke-Entry @('.cmd', '/d', '/c', 'gh', 'environment-probe')
    Assert-Contains $terminalEnvironment 'PROMPT:<>' 'Identity terminals should preserve interactive gh behavior.'
    Assert-Contains $terminalEnvironment 'PAGER:<>' 'Identity terminals should not force the automation pager.'
    Assert-Contains $terminalEnvironment 'GIT_PROMPT:<>' 'Identity terminals should preserve interactive Git behavior.'
    Assert-Contains $terminalEnvironment 'GCM_INTERACTIVE:<>' 'Identity terminals should preserve interactive GCM behavior.'

    $unknown = Invoke-Entry @('.unknown') 1
    Assert-Contains $unknown 'Unknown GitHub CLI kit command' 'Unknown dot commands should not pass through.'

    $env:GH_TOKEN = 'must-not-be-used'
    $guarded = Invoke-Entry @('pr', 'list') 1
    Assert-Contains $guarded 'GH_TOKEN is already set' 'Inherited tokens should be rejected.'
    $env:GH_TOKEN = $null

    Write-Host 'github cli command smoke: PASS' -ForegroundColor Green
} finally {
    $env:PATH = $originalPath
    foreach ($name in $tokenNames) {
        [Environment]::SetEnvironmentVariable($name, $savedTokens[$name])
    }
    foreach ($name in $automationNames) {
        [Environment]::SetEnvironmentVariable($name, $savedAutomationEnvironment[$name])
    }
    [Environment]::SetEnvironmentVariable($selectionLogName, $savedSelectionLog)
    Remove-SwawKitTestTemplateEntry -RepoRoot $repoRoot -EntryPath $entryPath
    if ([IO.Directory]::Exists($tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
