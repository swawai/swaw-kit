Set-StrictMode -Version 2.0

function Invoke-SshAccessGlobalClientCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = "$($Context.CommandName) .global client status|install [--uac]"
    if ($Arguments.Count -eq 0) {
        throw "Missing client command. Usage: $Usage"
    }

    $Action = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Action) {
        'status' {
            Assert-SshAccessNoArguments `
                -Arguments $Rest `
                -Usage "$($Context.CommandName) .global client status"
            $State = Get-SshAccessClientState -Context $Context
            Show-SshAccessClientState -State $State
            return 0
        }
        'install' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global client install [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'client', 'install') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Install-SshAccessClient -Context $Context
            return 0
        }
        default {
            throw "Unknown client command '$($Arguments[0])'. Usage: $Usage"
        }
    }
}

function Invoke-SshAccessGlobalServerShellCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = "$($Context.CommandName) .global server shell cmd|powershell [--uac]"
    if ($Arguments.Count -eq 0) {
        throw "Missing server shell command. Usage: $Usage"
    }

    $Action = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Action) {
        'cmd' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server shell cmd [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'shell', 'cmd') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Set-SshAccessServerShellCmd -Context $Context
            return 0
        }
        'powershell' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server shell powershell [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'shell', 'powershell') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Set-SshAccessServerShellPowerShell -Context $Context
            return 0
        }
        default {
            throw "Unknown server shell command '$($Arguments[0])'. Usage: $Usage"
        }
    }
}

function Invoke-SshAccessGlobalServerPortCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = "$($Context.CommandName) .global server port set <port> [--uac]"
    if ($Arguments.Count -eq 0) {
        throw "Missing server port command. Usage: $Usage"
    }
    $Action = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    if ($Action -ne 'set') {
        throw "Unknown server port command '$($Arguments[0])'. Usage: $Usage"
    }

    $Uac = $false
    $Values = New-Object Collections.Generic.List[string]
    foreach ($Argument in $Rest) {
        if ($Argument -eq '--uac') {
            if ($Uac) {
                throw "Duplicate option '--uac'. Usage: $Usage"
            }
            $Uac = $true
            continue
        }
        if ($Argument.StartsWith('--')) {
            throw "Unexpected argument '$Argument'. Usage: $Usage"
        }
        $Values.Add($Argument)
    }
    if ($Values.Count -ne 1) {
        throw "Port set requires exactly one port. Usage: $Usage"
    }
    $Port = Resolve-SshAccessServerPortNumber -Value $Values[0]
    $AdminResult = Invoke-SshAccessAdminCommand `
        -Context $Context `
        -Arguments @('.global', 'server', 'port', 'set', [string]$Port) `
        -Uac $Uac
    if ($null -ne $AdminResult) {
        return [int]$AdminResult
    }
    Set-SshAccessServerPort -Context $Context -Port $Port
    return 0
}

function Invoke-SshAccessGlobalServerFirewallCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = (
        "$($Context.CommandName) .global server firewall " +
        'status|allow|remove [--uac]'
    )
    if ($Arguments.Count -eq 0) {
        throw "Missing server firewall command. Usage: $Usage"
    }
    $Action = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Action) {
        'status' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server firewall status [--uac]"
            if ($Options.ContainsKey('--uac') -and
                -not (Test-SshAccessAdministrator)) {
                return Invoke-SshAccessElevatedCommand `
                    -Context $Context `
                    -Arguments @('.global', 'server', 'firewall', 'status')
            }
            Show-SshAccessFirewallState -Context $Context
            return 0
        }
        'allow' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server firewall allow [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'firewall', 'allow') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            $null = Get-SshAccessRequiredServerService
            $PortState = Get-SshAccessServerPortConfigurationState `
                -Context $Context
            $Port = Assert-SshAccessManagedServerPortState -State $PortState
            Ensure-SshAccessServerFirewall -Port $Port
            return 0
        }
        'remove' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server firewall remove [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'firewall', 'remove') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Remove-SshAccessServerFirewall -Context $Context
            return 0
        }
        default {
            throw "Unknown server firewall command '$($Arguments[0])'. Usage: $Usage"
        }
    }
}

function Invoke-SshAccessGlobalServerCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = (
        "$($Context.CommandName) .global server " +
        'status|install|start|stop|uninstall|port|firewall|shell'
    )
    if ($Arguments.Count -eq 0) {
        throw "Missing server command. Usage: $Usage"
    }

    $Action = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Action) {
        'status' {
            Assert-SshAccessNoArguments `
                -Arguments $Rest `
                -Usage "$($Context.CommandName) .global server status"
            $State = Get-SshAccessServerState -Context $Context
            Show-SshAccessServerState -State $State
            return 0
        }
        'install' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server install [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'install') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Install-SshAccessServer -Context $Context
            return 0
        }
        'start' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server start [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'start') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Start-SshAccessServer
            return 0
        }
        'stop' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--uac') `
                -Usage "$($Context.CommandName) .global server stop [--uac]"
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'stop') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Stop-SshAccessServer
            return 0
        }
        'uninstall' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--yes', '--uac') `
                -Usage "$($Context.CommandName) .global server uninstall --yes [--uac]"
            if (-not $Options.ContainsKey('--yes')) {
                throw "Uninstall requires --yes. Usage: $($Context.CommandName) .global server uninstall --yes [--uac]"
            }
            $AdminResult = Invoke-SshAccessAdminCommand `
                -Context $Context `
                -Arguments @('.global', 'server', 'uninstall', '--yes') `
                -Uac $Options.ContainsKey('--uac')
            if ($null -ne $AdminResult) {
                return [int]$AdminResult
            }
            Uninstall-SshAccessServer
            return 0
        }
        'shell' {
            return Invoke-SshAccessGlobalServerShellCommand `
                -Context $Context `
                -Arguments $Rest
        }
        'port' {
            return Invoke-SshAccessGlobalServerPortCommand `
                -Context $Context `
                -Arguments $Rest
        }
        'firewall' {
            return Invoke-SshAccessGlobalServerFirewallCommand `
                -Context $Context `
                -Arguments $Rest
        }
        default {
            throw "Unknown server command '$($Arguments[0])'. Usage: $Usage"
        }
    }
}

function Invoke-SshAccessGlobalCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = "$($Context.CommandName) .global client|server ..."
    if ($Arguments.Count -eq 0) {
        throw "Missing global command. Usage: $Usage"
    }

    $Domain = $Arguments[0].ToLowerInvariant()
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Domain) {
        'client' {
            return Invoke-SshAccessGlobalClientCommand -Context $Context -Arguments $Rest
        }
        'server' {
            return Invoke-SshAccessGlobalServerCommand -Context $Context -Arguments $Rest
        }
        default {
            throw "Unknown global command '$($Arguments[0])'. Usage: $Usage"
        }
    }
}
