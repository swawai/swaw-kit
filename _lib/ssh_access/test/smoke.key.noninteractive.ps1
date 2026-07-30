[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    function Resolve-SshAccessOpenSshExecutable {
        param(
            [pscustomobject]$Context,
            [string]$Name
        )
        return 'mock-ssh-keygen.exe'
    }

    $script:KeygenArguments = @()
    function Invoke-SshAccessConsoleProcess {
        param(
            [string]$Executable,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )

        $script:KeygenArguments = @($Arguments)
        $OutputPath = $Arguments[[Array]::IndexOf($Arguments, '-f') + 1]
        [IO.File]::WriteAllText($OutputPath, 'generated-private')
        [IO.File]::WriteAllText(
            "$OutputPath.pub",
            (New-SshAccessTestPublicKeyLine -Seed 73 -Comment 'generated'),
            (New-Object Text.UTF8Encoding($false))
        )
        return 0
    }

    Write-Host '[TEST] -N supplies an explicit empty ssh-keygen passphrase'
    $PrivatePath = Join-Path $ScratchRoot 'without-passphrase\id_ed25519'
    $Context = [pscustomobject]@{
        CommandName    = 'sshaccess.test'
        PrivateKeyPath = $PrivatePath
        PublicKeyPath  = "$PrivatePath.pub"
        KeyType        = 'ed25519'
        KeyComment     = 'test'
    }
    $ExitCode = Invoke-SshAccessKeyGenerate `
        -Context $Context `
        -NoPassphrase $true
    Assert-SshAccessTestEqual $ExitCode 0 'Non-interactive generation should succeed.'
    $PassphraseIndex = [Array]::IndexOf($script:KeygenArguments, '-N')
    Assert-SshAccessTestTrue `
        ($PassphraseIndex -ge 0) `
        'Non-interactive generation should pass ssh-keygen -N.'
    Assert-SshAccessTestEqual `
        $script:KeygenArguments[$PassphraseIndex + 1] `
        '' `
        'The -N argument should be an explicit empty passphrase.'

    Write-Host '[TEST] Default generation preserves ssh-keygen prompting'
    $PrivatePath = Join-Path $ScratchRoot 'interactive\id_ed25519'
    $Context.PrivateKeyPath = $PrivatePath
    $Context.PublicKeyPath = "$PrivatePath.pub"
    $script:KeygenArguments = @()
    $ExitCode = Invoke-SshAccessKeyGenerate -Context $Context
    Assert-SshAccessTestEqual $ExitCode 0 'Default generation should succeed.'
    Assert-SshAccessTestTrue `
        ([Array]::IndexOf($script:KeygenArguments, '-N') -lt 0) `
        'Default generation should let ssh-keygen prompt for a passphrase.'

    Write-Host '[TEST] .key gen -N grammar is strict'
    $script:GenerateNoPassphrase = $null
    function Invoke-SshAccessKeyGenerate {
        param(
            [pscustomobject]$Context,
            [bool]$NoPassphrase = $false
        )
        $script:GenerateNoPassphrase = $NoPassphrase
        return 0
    }
    $ExitCode = Invoke-SshAccessKeyCommand `
        -Context $Context `
        -Arguments @('gen', '-N')
    Assert-SshAccessTestEqual $ExitCode 0 '.key gen -N should dispatch.'
    Assert-SshAccessTestEqual `
        $script:GenerateNoPassphrase `
        $true `
        '.key gen -N should select empty-passphrase generation.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('gen', '-N', '-N') } `
        "*Duplicate option '-N'*" `
        'Duplicate -N should fail before generation.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('gen', '--no-passphrase') } `
        "*Unexpected argument '--no-passphrase'*" `
        'Undocumented generation options should be rejected.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access non-interactive key-generation tests: PASS' -ForegroundColor Green
