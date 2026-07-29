[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    $PrivatePath = Join-Path $ScratchRoot 'id_ed25519'
    $PublicPath = "$PrivatePath.pub"
    $Context = [pscustomobject]@{
        CommandName    = 'sshaccess.test'
        PrivateKeyPath = $PrivatePath
        PublicKeyPath  = $PublicPath
        WindowsRoot    = $env:SystemRoot
    }

    Write-Host '[TEST] Service-manager errors remain unknown'
    function Get-Service {
        [CmdletBinding()]
        param([string]$Name)

        Write-Error 'mock service access denied' -Category PermissionDenied
    }
    function Get-SshAccessServiceStartType {
        param([string]$ServiceName)

        return 'Unknown'
    }
    $UnreadableService = Get-SshAccessAgentServiceState
    Assert-SshAccessTestEqual `
        $UnreadableService.Installed `
        $null `
        'A service-manager error must not be reported as ssh-agent not installed.'
    Assert-SshAccessTestEqual `
        $UnreadableService.Status `
        'Unknown' `
        'A service-manager error should preserve an unknown service status.'

    Write-Host '[TEST] Private command grammar and explicit UAC'
    $script:PrivateLoadCalls = New-Object Collections.Generic.List[bool]
    $script:PrivateUnloadCalls = New-Object Collections.Generic.List[bool]
    function Invoke-SshAccessPrivateLoad {
        param(
            [pscustomobject]$Context,
            [bool]$Uac
        )

        $script:PrivateLoadCalls.Add($Uac)
        return 0
    }
    function Invoke-SshAccessPrivateUnload {
        param(
            [pscustomobject]$Context,
            [bool]$Uac
        )

        $script:PrivateUnloadCalls.Add($Uac)
        return 0
    }

    $Code = Invoke-SshAccessPrivateCommand `
        -Context $Context `
        -Arguments @('load')
    Assert-SshAccessTestEqual $Code 0 'Private load should dispatch.'
    Assert-SshAccessTestEqual `
        $script:PrivateLoadCalls[0] `
        $false `
        'Private load should not request elevation implicitly.'

    $Code = Invoke-SshAccessPrivateCommand `
        -Context $Context `
        -Arguments @('load', '--uac')
    Assert-SshAccessTestEqual $Code 0 'Private load --uac should dispatch.'
    Assert-SshAccessTestEqual `
        $script:PrivateLoadCalls[1] `
        $true `
        'Private load --uac should forward explicit elevation consent.'

    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessPrivateCommand -Context $Context -Arguments @('load', '--unknown') } `
        "*Unexpected argument '--unknown'*" `
        'Private load should reject unknown options.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessPrivateCommand -Context $Context -Arguments @('load', '--uac', '--uac') } `
        "*Duplicate option '--uac'*" `
        'Private load should reject duplicate UAC switches.'
    Assert-SshAccessTestEqual `
        $script:PrivateLoadCalls.Count `
        2 `
        'Invalid private load commands must fail before mutation.'

    $Code = Invoke-SshAccessPrivateCommand `
        -Context $Context `
        -Arguments @('unload')
    Assert-SshAccessTestEqual $Code 0 'Private unload should dispatch.'
    Assert-SshAccessTestEqual `
        $script:PrivateUnloadCalls[0] `
        $false `
        'Private unload should not request elevation implicitly.'

    $Code = Invoke-SshAccessPrivateCommand `
        -Context $Context `
        -Arguments @('unload', '--uac')
    Assert-SshAccessTestEqual $Code 0 'Private unload --uac should dispatch.'
    Assert-SshAccessTestEqual `
        $script:PrivateUnloadCalls[1] `
        $true `
        'Private unload --uac should forward explicit elevation consent.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessPrivateCommand -Context $Context -Arguments @('unload', '--unknown') } `
        "*Unexpected argument '--unknown'*" `
        'Private unload should reject unknown options.'
    Assert-SshAccessTestEqual `
        $script:PrivateUnloadCalls.Count `
        2 `
        'Invalid unload commands must fail before mutation.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessPrivateCommand -Context $Context -Arguments @('clear') } `
        "*Unknown .private command 'clear'*" `
        'A guessed agent-wide clear command must remain unsupported.'

    Write-Host '[TEST] Bound-key-only agent removal'
    [IO.File]::WriteAllText($PrivatePath, 'private')
    [IO.File]::WriteAllText($PublicPath, 'public')
    $script:AgentExecutableNames = New-Object Collections.Generic.List[string]
    $script:AgentProcessArguments = $null
    function Resolve-SshAccessOpenSshExecutable {
        param(
            [pscustomobject]$Context,
            [string]$Name
        )

        $script:AgentExecutableNames.Add($Name)
        return 'mock-ssh-add.exe'
    }
    function Invoke-SshAccessConsoleProcess {
        param(
            [string]$Executable,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )

        $script:AgentProcessArguments = [string[]]@($Arguments)
        return 0
    }

    $Code = Remove-SshAccessBoundKeyFromAgent -Context $Context
    Assert-SshAccessTestEqual $Code 0 'Bound-key removal should return the process exit code.'
    Assert-SshAccessTestEqual `
        $script:AgentExecutableNames[0] `
        'ssh-add.exe' `
        'Bound-key removal should resolve ssh-add.'
    Assert-SshAccessTestEqual `
        $script:AgentProcessArguments.Count `
        2 `
        'Bound-key removal should pass exactly an action and one identity.'
    Assert-SshAccessTestEqual `
        $script:AgentProcessArguments[0] `
        '-d' `
        'Bound-key removal must use ssh-add -d.'
    Assert-SshAccessTestEqual `
        $script:AgentProcessArguments[1] `
        $PublicPath `
        'Bound-key removal should select the bound public key precisely.'
    Assert-SshAccessTestTrue `
        (-not ($script:AgentProcessArguments -ccontains '-D')) `
        'Bound-key removal must never clear every agent identity.'

    Write-Host '[TEST] A stopped Windows agent remains unknown'
    function Get-SshAccessAgentServiceState {
        return [pscustomobject]@{
            Installed = $true
            Status    = 'Stopped'
            StartType = 'Automatic'
            Error     = ''
        }
    }
    $StoppedState = Get-SshAccessPrivateState -Context $Context
    Assert-SshAccessTestEqual `
        $StoppedState.BoundKey `
        'unknown' `
        'Windows can persist agent identities, so a stopped service must not be treated as empty.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access private tests: PASS' -ForegroundColor Green
