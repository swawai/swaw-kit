[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
& (Join-Path ([Environment]::SystemDirectory) 'chcp.com') 65001 > $null

. (Join-Path $PSScriptRoot 'support.ps1')

$Entry = Join-Path $script:SshAccessTestRepoRoot 'sshaccess1.dev.cmd'

function Invoke-SshAccessHelpTestCommand {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode
    )

    $OldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = (& $Entry @Arguments 2>&1 | Out-String)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $OldErrorActionPreference
    }
    Assert-SshAccessTestEqual `
        $ExitCode `
        $ExpectedExitCode `
        "Unexpected exit code for: $($Arguments -join ' ')`n$Output"
    return $Output
}

foreach ($Arguments in @(
    [string[]]@(),
    [string[]]@('--help'),
    [string[]]@('-h'),
    [string[]]@('.h'),
    [string[]]@('.help')
)) {
    $Output = Invoke-SshAccessHelpTestCommand `
        -Arguments $Arguments `
        -ExpectedExitCode 0
    Assert-SshAccessTestContains $Output 'SSH Access' 'Help should identify the resource.'
    Assert-SshAccessTestContains `
        $Output `
        'sshaccess1.dev .global server install --uac' `
        'Help should use the actual entry command.'
    Assert-SshAccessTestTrue `
        (-not $Output.Contains('{{COMMAND}}')) `
        'Help placeholders should be replaced.'
    Assert-SshAccessTestTrue `
        (-not $Output.Contains('{{ENTRY_FILE}}')) `
        'The entry-file placeholder should be replaced.'
}

$PoisonedEnvironmentNames = @(
    'SystemRoot',
    'windir',
    'ComSpec',
    'PSModulePath',
    '__APPDIR__'
)
$SavedPoisonedEnvironment = Save-SshAccessTestEnvironment `
    -Names $PoisonedEnvironmentNames
$TrustedCommandProcessor = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
try {
    $env:SystemRoot = 'X:\untrusted-system-root'
    $env:windir = 'X:\untrusted-windir'
    $env:ComSpec = 'X:\untrusted-command-processor\cmd.exe'
    $env:PSModulePath = 'X:\untrusted-powershell-modules'
    $env:__APPDIR__ = 'X:\untrusted-app-directory\'
    $OldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $HelpCommandLine = '"' + $Entry + '" .help'
        $TrustedAdapterHelp = (
            & $TrustedCommandProcessor /d /c $HelpCommandLine 2>&1 |
                Out-String
        )
        $TrustedAdapterHelpExitCode = $LASTEXITCODE

        $StatusCommandLine = '"' + $Entry + '" .status'
        $TrustedAdapterStatus = (
            & $TrustedCommandProcessor /d /c $StatusCommandLine 2>&1 |
                Out-String
        )
        $TrustedAdapterStatusExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $OldErrorActionPreference
    }
} finally {
    Restore-SshAccessTestEnvironment -Saved $SavedPoisonedEnvironment
}
Assert-SshAccessTestEqual `
    $TrustedAdapterHelpExitCode `
    0 `
    "The trusted CMD adapter should start help under a poisoned environment.`n$TrustedAdapterHelp"
Assert-SshAccessTestContains `
    $TrustedAdapterHelp `
    'SSH Access' `
    'The CMD adapter should ignore poisoned Windows process environment values.'
Assert-SshAccessTestEqual `
    $TrustedAdapterStatusExitCode `
    0 `
    "The trusted CMD adapter should start status under a poisoned environment.`n$TrustedAdapterStatus"
Assert-SshAccessTestContains `
    $TrustedAdapterStatus `
    'SSH Access status:' `
    'The runtime should remain operational after replacing the poisoned process environment.'
Assert-SshAccessTestTrue `
    (-not $TrustedAdapterStatus.Contains(
        'Microsoft.PowerShell.LocalAccounts module is required'
    )) `
    'The runtime should replace a poisoned PSModulePath before module discovery.'

$English = Invoke-SshAccessHelpTestCommand `
    -Arguments @('.help', 'en') `
    -ExpectedExitCode 0
Assert-SshAccessTestContains $English '# Basic usage:' '.help en should render English help.'
Assert-SshAccessTestContains `
    $English `
    'sshaccess1.dev .private load --uac' `
    'English help should document explicit agent elevation.'
Assert-SshAccessTestContains `
    $English `
    'with .status it explicitly requests elevation' `
    'English help should distinguish status elevation from mutation consent.'
Assert-SshAccessTestContains `
    $English `
    "Version 1 mutates an ordinary user's profile only when that user runs the entry" `
    'English help should document the ordinary-user mutation boundary.'
Assert-SshAccessTestContains `
    $English `
    'an option-bound reference is never silently weakened into a plain grant' `
    'English help should document option-bound grant safety.'

$Chinese = Invoke-SshAccessHelpTestCommand `
    -Arguments @('.help', 'zh') `
    -ExpectedExitCode 0
$ChineseHeading = '# ' + (-join ([char[]]@(
    0x57fa,
    0x672c,
    0x7528,
    0x6cd5
))) + ':'
Assert-SshAccessTestContains `
    $Chinese `
    $ChineseHeading `
    '.help zh should render Chinese help.'
Assert-SshAccessTestContains `
    $Chinese `
    'sshaccess1.dev .private load --uac' `
    'Chinese help should document explicit agent elevation.'
Assert-SshAccessTestContains `
    $Chinese `
    'sshaccess1.dev.cmd' `
    'Chinese help should show the real entry file name including its extension.'
Assert-SshAccessTestContains `
    $Chinese `
    ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        'djEg5Y+q5YWB6K645pmu6YCa55So5oi35pys5Lq66L+Q6KGM5YWl5Y+j5bm25L+u5pS56Ieq5bex55qEIHByb2ZpbGU='
    ))) `
    'Chinese help should document the ordinary-user mutation boundary.'
Assert-SshAccessTestContains `
    $Chinese `
    ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        '5bey5pyJIG9wdGlvbi1ib3VuZCDlvJXnlKjml7bkuI3kvJrpnZnpu5jov73liqDmm7Tlrr3mnb7nmoQgcGxhaW4g5o6I5p2D'
    ))) `
    'Chinese help should document option-bound grant safety.'

foreach ($Required in @(
    '.status key',
    '.status private',
    '.status public',
    '.status ssh',
    '.status --uac',
    '.key gen',
    '.key fp',
    '.key delete --yes',
    '.private status',
    '.private load --uac',
    '.private unload',
    '.private unload --uac',
    '.public grant --uac',
    '.public revoke --uac',
    '.global client install --uac',
    '.global server install --uac',
    '.global server uninstall --yes --uac',
    '.global server shell powershell --uac'
)) {
    Assert-SshAccessTestContains $Chinese $Required "Chinese help should contain $Required"
    Assert-SshAccessTestContains $English $Required "English help should contain $Required"
}

Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('sshaccess1.dev .key generate')) `
    'Help should present the preferred short generation spelling.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('sshaccess1.dev .key fingerprint')) `
    'Help should present the preferred short fingerprint spelling.'
Assert-SshAccessTestTrue `
    (-not $English.Contains('sshaccess1.dev .key generate')) `
    'English help should present the preferred short generation spelling.'
Assert-SshAccessTestTrue `
    (-not $English.Contains('sshaccess1.dev .key fingerprint')) `
    'English help should present the preferred short fingerprint spelling.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('sshaccess1.dev .key fing')) `
    'Help should not retain the replaced fing spelling.'
Assert-SshAccessTestTrue `
    (-not $English.Contains('sshaccess1.dev .key fing')) `
    'English help should not retain the replaced fing spelling.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('.agent ')) `
    'Help should not expose ssh-agent as a top-level namespace.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('sshaccess1.dev .grant')) `
    'Help should not expose the old top-level grant command.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('sshaccess1.dev /?')) `
    'Help should not advertise the unsupported legacy alias.'

$SlashQuestion = Invoke-SshAccessHelpTestCommand `
    -Arguments @('/?') `
    -ExpectedExitCode 1
Assert-SshAccessTestContains `
    $SlashQuestion `
    "Unknown SSH Access command '/?'" `
    'The legacy alias should fail as an unknown command.'

$Unknown = Invoke-SshAccessHelpTestCommand `
    -Arguments @('.unknown') `
    -ExpectedExitCode 1
Assert-SshAccessTestContains `
    $Unknown `
    "Unknown SSH Access command '.unknown'" `
    'Unknown commands should fail explicitly.'

$AliasExtra = Invoke-SshAccessHelpTestCommand `
    -Arguments @('--help', 'en') `
    -ExpectedExitCode 1
Assert-SshAccessTestContains `
    $AliasExtra `
    'does not accept additional arguments' `
    'Help aliases should reject language arguments.'

$InvalidLanguage = Invoke-SshAccessHelpTestCommand `
    -Arguments @('.help', 'fr') `
    -ExpectedExitCode 1
Assert-SshAccessTestContains `
    $InvalidLanguage `
    "Unsupported help language 'fr'" `
    'Canonical help should reject unknown languages.'

$TooManyLanguages = Invoke-SshAccessHelpTestCommand `
    -Arguments @('.help', 'en', 'zh') `
    -ExpectedExitCode 1
Assert-SshAccessTestContains `
    $TooManyLanguages `
    'at most one language' `
    'Canonical help should reject extra arguments.'

Write-Host 'ssh access help tests: PASS' -ForegroundColor Green
