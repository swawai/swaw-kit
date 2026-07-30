[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    $WindowsRoot = Join-Path $ScratchRoot 'Windows'
    $ExplorerPath = Join-Path $WindowsRoot 'explorer.exe'
    $KeyDirectory = Join-Path $ScratchRoot 'key pair'
    [void][IO.Directory]::CreateDirectory($WindowsRoot)
    [void][IO.Directory]::CreateDirectory($KeyDirectory)
    [IO.File]::WriteAllText($ExplorerPath, 'test placeholder')

    $Context = [pscustomobject]@{
        CommandName    = 'sshaccess.test'
        PublicKeyPath  = Join-Path $KeyDirectory 'id_ed25519.pub'
        WindowsRoot    = $WindowsRoot
    }

    $script:ExplorerStartCount = 0
    $script:StartedExplorerPath = $null
    $script:StartedDirectory = $null
    function Start-SshAccessKeyDirectoryExplorer {
        param(
            [Parameter(Mandatory = $true)][string]$ExplorerPath,
            [Parameter(Mandatory = $true)][string]$Directory
        )

        $script:ExplorerStartCount++
        $script:StartedExplorerPath = $ExplorerPath
        $script:StartedDirectory = $Directory
    }

    Write-Host '[TEST] .key dir opens the existing bound-key directory'
    $ExitCode = Open-SshAccessKeyDirectory -Context $Context
    Assert-SshAccessTestEqual $ExitCode 0 '.key dir should report success.'
    Assert-SshAccessTestEqual `
        $script:ExplorerStartCount `
        1 `
        'The Explorer adapter should be called exactly once.'
    Assert-SshAccessTestEqual `
        $script:StartedExplorerPath `
        $ExplorerPath `
        'Explorer should be resolved only from the trusted Windows root.'
    Assert-SshAccessTestEqual `
        $script:StartedDirectory `
        $KeyDirectory `
        'Explorer should receive the declared public key parent directory.'

    Write-Host '[TEST] .key dir grammar is strict'
    $script:ExplorerStartCount = 0
    $ExitCode = Invoke-SshAccessKeyCommand -Context $Context -Arguments @('dir')
    Assert-SshAccessTestEqual $ExitCode 0 'The canonical .key dir spelling should dispatch.'
    Assert-SshAccessTestEqual `
        $script:ExplorerStartCount `
        1 `
        'The canonical command should open exactly once.'
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessKeyCommand `
                -Context $Context `
                -Arguments @('dir', 'unexpected')
        } `
        '*Usage: sshaccess.test .key dir*' `
        '.key dir should reject extra arguments.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('cd') } `
        "*Unknown .key command 'cd'*" `
        '.key cd should not create a false change-directory promise.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('open') } `
        "*Unknown .key command 'open'*" `
        '.key open should not become a second spelling for the same operation.'

    Write-Host '[TEST] .key dir has no implicit filesystem mutation'
    $MissingDirectory = Join-Path $ScratchRoot 'missing'
    $MissingContext = [pscustomobject]@{
        CommandName    = 'sshaccess.test'
        PublicKeyPath  = Join-Path $MissingDirectory 'id_ed25519.pub'
        WindowsRoot    = $WindowsRoot
    }
    $script:ExplorerStartCount = 0
    Assert-SshAccessTestThrowsLike `
        { Open-SshAccessKeyDirectory -Context $MissingContext } `
        '*key directory does not exist*' `
        'A missing key directory should be reported instead of created.'
    Assert-SshAccessTestTrue `
        (-not [IO.Directory]::Exists($MissingDirectory)) `
        '.key dir must not create the configured directory.'
    Assert-SshAccessTestEqual `
        $script:ExplorerStartCount `
        0 `
        'Explorer should not start for a missing directory.'

    Write-Host '[TEST] .key dir refuses an untrusted Explorer fallback'
    Remove-Item -LiteralPath $ExplorerPath -Force
    Assert-SshAccessTestThrowsLike `
        { Open-SshAccessKeyDirectory -Context $Context } `
        '*Trusted Windows File Explorer was not found*' `
        'The command should not search PATH when trusted explorer.exe is absent.'
    Assert-SshAccessTestEqual `
        $script:ExplorerStartCount `
        0 `
        'No fallback executable should start.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access key-directory tests: PASS' -ForegroundColor Green
