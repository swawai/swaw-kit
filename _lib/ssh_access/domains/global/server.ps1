Set-StrictMode -Version 2.0

function Get-SshAccessServerCapabilityName {
    return 'OpenSSH.Server~~~~0.0.1.0'
}

function Get-SshAccessServerServiceState {
    $ServiceErrors = @()
    $Service = Get-Service `
        -Name 'sshd' `
        -ErrorAction SilentlyContinue `
        -ErrorVariable ServiceErrors

    if ($null -eq $Service) {
        if ($ServiceErrors.Count -gt 0 -and
            $ServiceErrors[0].CategoryInfo.Category -ne
                [Management.Automation.ErrorCategory]::ObjectNotFound) {
            return [pscustomobject]@{
                Presence = 'Unknown'
                Status   = 'Unknown'
                Startup  = 'Unknown'
                Error    = Get-SshAccessErrorText -ErrorRecord $ServiceErrors[0]
            }
        }
        return [pscustomobject]@{
            Presence = 'Missing'
            Status   = 'Unavailable'
            Startup  = 'Unavailable'
            Error    = $null
        }
    }

    $Startup = 'Unknown'
    $StartupError = $null
    $RegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd'
    try {
        $Properties = Get-ItemProperty `
            -LiteralPath $RegistryPath `
            -Name 'Start' `
            -ErrorAction Stop
        switch ([int]$Properties.Start) {
            0 { $Startup = 'Boot' }
            1 { $Startup = 'System' }
            2 { $Startup = 'Automatic' }
            3 { $Startup = 'Manual' }
            4 { $Startup = 'Disabled' }
            default { $Startup = "Unknown ($($Properties.Start))" }
        }
    } catch {
        $StartupError = Get-SshAccessErrorText -ErrorRecord $_
    }

    return [pscustomobject]@{
        Presence = 'Present'
        Status   = [string]$Service.Status
        Startup  = $Startup
        Error    = $StartupError
    }
}

function Get-SshAccessServerListenerState {
    try {
        $Listeners = @(
            [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().
                GetActiveTcpListeners() |
                Where-Object { $_.Port -eq 22 }
        )
        return [pscustomobject]@{
            Status = if ($Listeners.Count -gt 0) { 'Listening' } else { 'NotListening' }
            Count  = $Listeners.Count
            Error  = $null
        }
    } catch {
        return [pscustomobject]@{
            Status = 'Unknown'
            Count  = $null
            Error  = Get-SshAccessErrorText -ErrorRecord $_
        }
    }
}

function Get-SshAccessServerState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Capability = Get-SshAccessWindowsCapabilityState -Name (Get-SshAccessServerCapabilityName)
    $ExecutablePath = Join-Path $Context.WindowsRoot 'System32\OpenSSH\sshd.exe'
    $Executable = Get-SshAccessExecutableProbe `
        -PreferredPath $ExecutablePath `
        -CommandName 'sshd.exe' `
        -ProbeArguments @('-?')
    $Service = Get-SshAccessServerServiceState
    $Listener = Get-SshAccessServerListenerState
    $Firewall = Get-SshAccessFirewallState
    $Shell = Get-SshAccessShellState -Context $Context

    $Installation = 'Unknown'
    if ($Capability.State -eq 'Installed' -or
        $Executable.Presence -eq 'Present' -or
        $Service.Presence -eq 'Present') {
        $Installation = 'Installed'
    } elseif ($Capability.State -eq 'NotPresent' -and
        $Executable.Presence -eq 'Missing' -and
        $Service.Presence -eq 'Missing') {
        $Installation = 'NotInstalled'
    }

    return [pscustomobject]@{
        Installation = $Installation
        Capability   = $Capability
        Executable   = $Executable
        Service      = $Service
        Listener     = $Listener
        Firewall     = $Firewall
        Shell        = $Shell
    }
}

function Show-SshAccessServerState {
    [CmdletBinding(DefaultParameterSetName = 'Context')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Context')]
        [pscustomobject]$Context,
        [Parameter(Mandatory = $true, ParameterSetName = 'State')]
        [pscustomobject]$State
    )

    if ($PSCmdlet.ParameterSetName -eq 'Context') {
        $State = Get-SshAccessServerState -Context $Context
    }

    Write-SshAccessHeading -Text 'Windows OpenSSH server'
    Write-SshAccessField -Name 'Installation' -Value $State.Installation
    Write-SshAccessField -Name 'Capability' -Value $State.Capability.State
    Write-SshAccessField -Name 'Executable' -Value $State.Executable.Path
    Write-SshAccessField -Name 'Executable probe' -Value $State.Executable.Probe
    Write-SshAccessField -Name 'Service' -Value $State.Service.Status
    Write-SshAccessField -Name 'Startup' -Value $State.Service.Startup
    Write-SshAccessField -Name 'TCP port 22' -Value $State.Listener.Status

    $FirewallText = $State.Firewall.Status
    if (-not [string]::IsNullOrWhiteSpace($State.Firewall.Source)) {
        $FirewallText = "$FirewallText ($($State.Firewall.Source))"
    }
    Write-SshAccessField -Name 'Firewall' -Value $FirewallText
    Write-SshAccessField -Name 'Default shell' -Value $State.Shell.Kind

    if (-not [string]::IsNullOrWhiteSpace($State.Capability.Error)) {
        Write-SshAccessField -Name 'Capability note' -Value $State.Capability.Error
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Executable.Error)) {
        Write-SshAccessField -Name 'Executable note' -Value $State.Executable.Error
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Service.Error)) {
        Write-SshAccessField -Name 'Service note' -Value $State.Service.Error
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Listener.Error)) {
        Write-SshAccessField -Name 'Listener note' -Value $State.Listener.Error
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Firewall.Error)) {
        Write-SshAccessField -Name 'Firewall note' -Value $State.Firewall.Error
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Shell.Error)) {
        Write-SshAccessField -Name 'Shell note' -Value $State.Shell.Error
    }
}

function Get-SshAccessOptionalServerService {
    try {
        return Get-Service -Name 'sshd' -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -eq
            [Management.Automation.ErrorCategory]::ObjectNotFound) {
            return $null
        }
        throw "Unable to query the sshd service. $($_.Exception.Message)"
    }
}

function Get-SshAccessRequiredServerService {
    $Service = Get-SshAccessOptionalServerService
    if ($null -eq $Service) {
        throw 'The sshd service is unavailable. Install the OpenSSH server first.'
    }
    return $Service
}

function Wait-SshAccessServerService {
    param(
        [Parameter(Mandatory = $true)][object]$Service,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Running', 'Stopped')]
        [string]$Status
    )

    $TargetStatus = [Enum]::Parse(
        $Service.Status.GetType(),
        $Status,
        $true
    )
    $Service.WaitForStatus($TargetStatus, [TimeSpan]::FromSeconds(20))
    $Service.Refresh()
    if ([string]$Service.Status -ne $Status) {
        throw "The sshd service did not reach state '$Status'."
    }
}

function Install-SshAccessServer {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $null = $Context
    Assert-SshAccessGlobalAdministrator
    $CapabilityResult = Install-SshAccessWindowsCapability `
        -Name (Get-SshAccessServerCapabilityName)

    $Service = Get-SshAccessOptionalServerService
    if ($null -eq $Service -and $CapabilityResult.RestartNeeded) {
        Write-Host 'OpenSSH server capability installed; Windows requires a restart before sshd can be initialized.'
        Write-SshAccessWarning -Message 'Restart Windows, then run the server install command again.'
        return
    }
    if ($null -eq $Service) {
        throw 'The sshd service is unavailable after installing the OpenSSH server capability.'
    }
    Set-Service -Name 'sshd' -StartupType Automatic -ErrorAction Stop
    if ([string]$Service.Status -ne 'Running') {
        Start-Service -Name 'sshd' -ErrorAction Stop
        $Service = Get-SshAccessRequiredServerService
        Wait-SshAccessServerService -Service $Service -Status 'Running'
    }

    Ensure-SshAccessServerFirewall
    if ($CapabilityResult.Changed) {
        Write-Host 'OpenSSH server capability installed.'
    } else {
        Write-Host 'OpenSSH server capability is already installed.'
    }
    Write-Host 'The sshd service is running with Automatic startup.'
    if ($CapabilityResult.RestartNeeded) {
        Write-SshAccessWarning -Message 'Windows reports that a restart is required.'
    }
}

function Start-SshAccessServer {
    Assert-SshAccessGlobalAdministrator
    $Service = Get-SshAccessRequiredServerService
    if ([string]$Service.Status -eq 'Running') {
        Write-Host 'The sshd service is already running.'
        return
    }

    Start-Service -Name 'sshd' -ErrorAction Stop
    $Service = Get-SshAccessRequiredServerService
    Wait-SshAccessServerService -Service $Service -Status 'Running'
    Write-Host 'The sshd service started.'
}

function Stop-SshAccessServer {
    Assert-SshAccessGlobalAdministrator
    $Service = Get-SshAccessRequiredServerService
    if ([string]$Service.Status -eq 'Stopped') {
        Write-Host 'The sshd service is already stopped.'
        return
    }

    Stop-Service -Name 'sshd' -ErrorAction Stop
    $Service = Get-SshAccessRequiredServerService
    Wait-SshAccessServerService -Service $Service -Status 'Stopped'
    Write-Host 'The sshd service stopped.'
}

function Uninstall-SshAccessServer {
    Assert-SshAccessGlobalAdministrator

    $CapabilityState = Get-SshAccessWindowsCapabilityState `
        -Name (Get-SshAccessServerCapabilityName)
    if ($CapabilityState.State -eq 'NotPresent') {
        $FirewallRemoved = Remove-SshAccessManagedFirewallRule
        Write-Host 'The Windows OpenSSH server capability is not installed.'
        if ($FirewallRemoved) {
            Write-Host "Removed SSH Access firewall rule '$(Get-SshAccessManagedFirewallRuleName)'."
        } else {
            Write-Host 'No SSH Access firewall rule needed removal.'
        }
        Write-SshAccessWarning -Message (
            'Any independently installed sshd service was left untouched.'
        )
        return
    }
    if ($CapabilityState.State -ne 'Installed') {
        throw "The Windows OpenSSH server capability state is '$($CapabilityState.State)'. Refusing to stop sshd or uninstall while capability ownership is uncertain."
    }

    $ServiceWasRunning = $false
    try {
        $Service = Get-SshAccessOptionalServerService
        if ($null -ne $Service) {
            $ServiceStatus = [string]$Service.Status
            if (@('Running', 'Stopped') -notcontains $ServiceStatus) {
                throw "The sshd service is in transitional state '$ServiceStatus'. Retry after it reaches Running or Stopped."
            }
            $ServiceWasRunning = $ServiceStatus -eq 'Running'
        }
        if ($ServiceWasRunning) {
            Stop-Service -Name 'sshd' -ErrorAction Stop
            $Service = Get-SshAccessRequiredServerService
            Wait-SshAccessServerService -Service $Service -Status 'Stopped'
            Write-Host 'The sshd service stopped.'
        }

        $CapabilityResult = Remove-SshAccessWindowsCapability `
            -Name (Get-SshAccessServerCapabilityName)
    } catch {
        $RemovalError = $_.Exception.Message
        $RecoveryError = $null
        if ($ServiceWasRunning) {
            try {
                $RemainingService = Get-SshAccessOptionalServerService
                if ($null -eq $RemainingService) {
                    throw 'The sshd service no longer exists.'
                }
                if ([string]$RemainingService.Status -ne 'Running') {
                    Start-Service -Name 'sshd' -ErrorAction Stop
                    $RemainingService = Get-SshAccessRequiredServerService
                    Wait-SshAccessServerService -Service $RemainingService -Status 'Running'
                }
            } catch {
                $RecoveryError = $_.Exception.Message
            }
        }
        if (-not $ServiceWasRunning) {
            throw "OpenSSH server uninstall did not complete. No previously running sshd service required recovery. $RemovalError"
        }
        if ([string]::IsNullOrWhiteSpace($RecoveryError)) {
            throw "OpenSSH server capability removal failed. The original sshd running state was restored. $RemovalError"
        }
        throw "OpenSSH server capability removal failed, and sshd could not be restored. Removal: $RemovalError Recovery: $RecoveryError"
    }
    $FirewallRemoved = Remove-SshAccessManagedFirewallRule

    if ($CapabilityResult.Changed) {
        Write-Host 'OpenSSH server capability uninstalled.'
    } else {
        Write-Host 'OpenSSH server capability was not installed.'
    }
    if ($FirewallRemoved) {
        Write-Host "Removed SSH Access firewall rule '$(Get-SshAccessManagedFirewallRuleName)'."
    } else {
        Write-Host 'No SSH Access firewall rule needed removal.'
    }
    Write-SshAccessWarning -Message (
        'SSH Access did not delete ProgramData\ssh configuration, host keys, or authorized keys.'
    )
    if ($CapabilityResult.RestartNeeded) {
        Write-SshAccessWarning -Message 'Windows reports that a restart is required.'
    }
}
