[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
& (Join-Path ([Environment]::SystemDirectory) 'chcp.com') 65001 > $null

. (Join-Path $PSScriptRoot 'support.ps1')

$TemplateEntry = Join-Path $script:SshAccessTestRepoRoot 'Favorites\template.sshaccess1.cmd'
if (-not [IO.File]::Exists($TemplateEntry)) {
    throw "SSH Access entry template not found: $TemplateEntry"
}

$EntryFileName = '.sshaccess-test-' + [Guid]::NewGuid().ToString('N') + '.cmd'
$Entry = Join-Path $script:SshAccessTestRepoRoot $EntryFileName
$EntryCommand = [IO.Path]::GetFileNameWithoutExtension($Entry)

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

function Get-SshAccessHelpCommandSignatures {
    param([Parameter(Mandatory = $true)][string]$Text)

    $Commands = New-Object Collections.Generic.List[string]
    foreach ($Line in ($Text -split '\r?\n')) {
        if ($Line -match '^\s+\S+\s+(\..*?)\s{2,}\S') {
            $Commands.Add($Matches[1].Trim())
        }
    }
    return [string[]]$Commands.ToArray()
}

function Get-SshAccessInteractiveHelpCommandSignatures {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    $Commands = New-Object Collections.Generic.List[string]
    foreach ($Line in ($Text -split '\r?\n')) {
        if ($Line.Contains($Marker) -and
            $Line -match '^\s+\S+\s+(\..*?)\s{2,}\S') {
            $Commands.Add($Matches[1].Trim())
        }
    }
    return [string[]]$Commands.ToArray()
}

try {
    [IO.File]::Copy($TemplateEntry, $Entry)

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
    Assert-SshAccessTestContains `
        $Output `
        "$EntryCommand .status" `
        'Help should identify the actual entry command.'
    Assert-SshAccessTestContains `
        $Output `
        "$EntryCommand .global server install --uac" `
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
    "$EntryCommand .status" `
    'The CMD adapter should ignore poisoned Windows process environment values.'
Assert-SshAccessTestEqual `
    $TrustedAdapterStatusExitCode `
    0 `
    "The trusted CMD adapter should start status under a poisoned environment.`n$TrustedAdapterStatus"
Assert-SshAccessTestContains `
    $TrustedAdapterStatus `
    'SSH Access status:' `
    'The runtime should remain operational after replacing the poisoned process environment.'
$ExpectedTemplatePublicKeyPath = Join-Path `
    $env:USERPROFILE `
    ".ssh\id_$EntryCommand.pub"
Assert-SshAccessTestContains `
    $TrustedAdapterStatus `
    $ExpectedTemplatePublicKeyPath `
    'The copied template should derive its default public key path from the instance name.'
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
    "$EntryCommand .private load --uac" `
    'English help should document explicit agent elevation.'
Assert-SshAccessTestContains `
    $English `
    'May prompt for the private-key passphrase' `
    'English help should document private-key passphrase interaction.'
Assert-SshAccessTestContains `
    $English `
    $EntryFileName `
    'English help should show the real entry file name including its extension.'
Assert-SshAccessTestContains `
    $English `
    'authorizes only the current account' `
    'English help should document ordinary-user authorization scope.'
Assert-SshAccessTestContains `
    $English `
    'authorizes all administrator accounts' `
    'English help should document shared administrator authorization scope.'

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
    "$EntryCommand .private load --uac" `
    'Chinese help should document explicit agent elevation.'
Assert-SshAccessTestContains `
    $Chinese `
    $EntryFileName `
    'Chinese help should show the real entry file name including its extension.'

$ChineseCommands = Get-SshAccessHelpCommandSignatures -Text $Chinese
$EnglishCommands = Get-SshAccessHelpCommandSignatures -Text $English
Assert-SshAccessTestEqual `
    $EnglishCommands.Count `
    $ChineseCommands.Count `
    'English and Chinese help should document the same number of commands.'
for ($Index = 0; $Index -lt $ChineseCommands.Count; $Index++) {
    Assert-SshAccessTestEqual `
        $EnglishCommands[$Index] `
        $ChineseCommands[$Index] `
        "English command order should follow the Chinese source at index $Index."
}

$ChineseInteractiveMarker = -join ([char[]]@(
    0x6709,
    0x4ea4,
    0x4e92
))
$ChineseInteractiveCommands = Get-SshAccessInteractiveHelpCommandSignatures `
    -Text $Chinese `
    -Marker $ChineseInteractiveMarker
$EnglishInteractiveCommands = Get-SshAccessInteractiveHelpCommandSignatures `
    -Text $English `
    -Marker 'INTERACTIVE'
Assert-SshAccessTestEqual `
    $EnglishInteractiveCommands.Count `
    $ChineseInteractiveCommands.Count `
    'English and Chinese help should mark the same number of interactive commands.'
for ($Index = 0; $Index -lt $ChineseInteractiveCommands.Count; $Index++) {
    Assert-SshAccessTestEqual `
        $EnglishInteractiveCommands[$Index] `
        $ChineseInteractiveCommands[$Index] `
        "English interactive markers should follow the Chinese source at index $Index."
}

foreach ($Required in @(
    '.status key',
    '.status private',
    '.status public',
    '.status ssh',
    '.status --uac',
    '.key dir',
    '.key gen',
    '.key gen -N',
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
    '.global server port set <port> --uac',
    '.global server firewall status',
    '.global server firewall allow --uac',
    '.global server firewall remove --uac',
    '.global server shell powershell --uac'
)) {
    Assert-SshAccessTestContains $Chinese $Required "Chinese help should contain $Required"
    Assert-SshAccessTestContains $English $Required "English help should contain $Required"
}

Assert-SshAccessTestTrue `
    (-not $Chinese.Contains("$EntryCommand .key generate")) `
    'Help should present the preferred short generation spelling.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains("$EntryCommand .key fingerprint")) `
    'Help should present the preferred short fingerprint spelling.'
Assert-SshAccessTestTrue `
    (-not $English.Contains("$EntryCommand .key generate")) `
    'English help should present the preferred short generation spelling.'
Assert-SshAccessTestTrue `
    (-not $English.Contains("$EntryCommand .key fingerprint")) `
    'English help should present the preferred short fingerprint spelling.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains("$EntryCommand .key fing")) `
    'Help should not retain the replaced fing spelling.'
Assert-SshAccessTestTrue `
    (-not $English.Contains("$EntryCommand .key fing")) `
    'English help should not retain the replaced fing spelling.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains("$EntryCommand .key cd")) `
    'Help should not imply that a child command can change the caller directory.'
Assert-SshAccessTestTrue `
    (-not $English.Contains("$EntryCommand .key cd")) `
    'English help should not imply that a child command can change the caller directory.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('.agent ')) `
    'Help should not expose ssh-agent as a top-level namespace.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains("$EntryCommand .grant")) `
    'Help should not expose the old top-level grant command.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains("$EntryCommand /?")) `
    'Help should not advertise the unsupported legacy alias.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('.global server port status')) `
    'Help should keep port state in aggregate server status.'
Assert-SshAccessTestTrue `
    (-not $English.Contains('.global server port status')) `
    'English help should keep port state in aggregate server status.'
Assert-SshAccessTestTrue `
    (-not $Chinese.Contains('.global server shell status')) `
    'Help should keep shell state in aggregate server status.'
Assert-SshAccessTestTrue `
    (-not $English.Contains('.global server shell status')) `
    'English help should keep shell state in aggregate server status.'

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

foreach ($Alias in @('.h', '-h', '--help')) {
    $AliasEnglish = Invoke-SshAccessHelpTestCommand `
        -Arguments @($Alias, 'en') `
        -ExpectedExitCode 0
    Assert-SshAccessTestEqual `
        $AliasEnglish `
        $English `
        "$Alias en should behave exactly like .help en."

    $AliasChinese = Invoke-SshAccessHelpTestCommand `
        -Arguments @($Alias, 'zh') `
        -ExpectedExitCode 0
    Assert-SshAccessTestEqual `
        $AliasChinese `
        $Chinese `
        "$Alias zh should behave exactly like .help zh."
}

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
} finally {
    if ([IO.File]::Exists($Entry)) {
        [IO.File]::Delete($Entry)
    }
}
