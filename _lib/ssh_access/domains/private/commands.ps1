Set-StrictMode -Version 2.0

function Invoke-SshAccessPrivateLoad {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][bool]$Uac
    )

    $KeyState = Get-SshAccessKeyState -Context $Context
    if ($KeyState.PairState -ne 'complete' -or
        $KeyState.PublicKeyState -ne 'valid' -or
        $KeyState.PairConsistency -ne 'matching') {
        throw "A complete, matching bound key pair is required. $($KeyState.Error) Run: $(Format-SshAccessCommand -CommandName $Context.CommandName -Arguments @('.key', 'status'))"
    }

    Start-SshAccessAgentForCurrentUser `
        -Context $Context `
        -Uac $Uac `
        -RetryArguments @('.private', 'load', '--uac')
    $State = Get-SshAccessPrivateState -Context $Context
    if ($State.BoundKey -eq 'loaded') {
        Write-Host 'The bound key is already loaded.'
        return 0
    }
    if ($State.BoundKey -eq 'unknown') {
        throw "The ssh-agent state could not be verified. $($State.Error)"
    }

    $SshAdd = Resolve-SshAccessOpenSshExecutable -Context $Context -Name 'ssh-add.exe'
    $ExitCode = Invoke-SshAccessConsoleProcess `
        -Executable $SshAdd `
        -Arguments @($Context.PrivateKeyPath)
    if ($ExitCode -ne 0) {
        throw "ssh-add failed with exit code $ExitCode."
    }
    Write-Host 'Loaded the bound private key into ssh-agent.' -ForegroundColor Green
    return 0
}

function Invoke-SshAccessPrivateUnload {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][bool]$Uac
    )

    $KeyState = Get-SshAccessKeyState -Context $Context
    if (-not $KeyState.PublicExists -or $KeyState.PublicKeyState -ne 'valid') {
        throw "A valid bound public key is required to unload the persistent agent identity. $($KeyState.Error)"
    }
    if ($KeyState.PrivateExists -and $KeyState.PairConsistency -ne 'matching') {
        throw "The bound private and public keys do not match or could not be verified. $($KeyState.Error)"
    }

    $Service = Get-SshAccessAgentServiceState
    if ($Service.Installed -and $Service.Status -ne 'Running') {
        Start-SshAccessAgentForCurrentUser `
            -Context $Context `
            -Uac $Uac `
            -RetryArguments @('.private', 'unload', '--uac')
    }
    $State = Get-SshAccessPrivateState -Context $Context
    if ($State.BoundKey -eq 'not-loaded') {
        Write-Host 'The bound key is not loaded.'
        return 0
    }
    if ($State.BoundKey -eq 'unknown') {
        throw "The ssh-agent state could not be verified. $($State.Error)"
    }

    $ExitCode = Remove-SshAccessBoundKeyFromAgent -Context $Context
    if ($ExitCode -ne 0) {
        throw "ssh-add -d failed with exit code $ExitCode."
    }
    return 0
}

function Invoke-SshAccessPrivateCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    if ($Arguments.Count -eq 0) {
        throw "Missing .private command. Usage: $($Context.CommandName) .private status|load|unload"
    }

    $Action = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Action) {
        'status' {
            Assert-SshAccessNoArguments -Arguments $Rest -Usage "$($Context.CommandName) .private status"
            Show-SshAccessPrivateState -Context $Context
            return 0
        }
        'load' {
            $Switches = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .private load [--uac]"
            return Invoke-SshAccessPrivateLoad -Context $Context -Uac $Switches.ContainsKey('--uac')
        }
        'unload' {
            $Switches = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .private unload [--uac]"
            return Invoke-SshAccessPrivateUnload `
                -Context $Context `
                -Uac ($Switches.ContainsKey('--uac'))
        }
        default {
            throw "Unknown .private command '$($Arguments[0])'."
        }
    }
}
