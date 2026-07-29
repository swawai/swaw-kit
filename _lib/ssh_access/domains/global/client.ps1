Set-StrictMode -Version 2.0

function Get-SshAccessClientCapabilityName {
    return 'OpenSSH.Client~~~~0.0.1.0'
}

function ConvertTo-SshAccessSingleLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    return (($Text -replace '[\r\n]+', ' ').Trim())
}

function Get-SshAccessErrorText {
    param([Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$ErrorRecord)

    return ConvertTo-SshAccessSingleLine -Text $ErrorRecord.Exception.Message
}

function Assert-SshAccessGlobalAdministrator {
    if (-not (Test-SshAccessAdministrator)) {
        throw 'This operation requires administrator privileges.'
    }
}

function Get-SshAccessWindowsCapabilityState {
    param([Parameter(Mandatory = $true)][string]$Name)

    $Command = Get-Command 'Get-WindowsCapability' -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $Command) {
        return [pscustomobject]@{
            Name  = $Name
            State = 'Unknown'
            Error = 'Get-WindowsCapability is unavailable.'
        }
    }

    try {
        $Capability = Get-WindowsCapability -Online -Name $Name -ErrorAction Stop
        if ($null -eq $Capability -or
            $null -eq $Capability.PSObject.Properties['State'] -or
            [string]::IsNullOrWhiteSpace([string]$Capability.State)) {
            return [pscustomobject]@{
                Name  = $Name
                State = 'Unknown'
                Error = 'Windows returned no capability state.'
            }
        }
        return [pscustomobject]@{
            Name  = $Name
            State = [string]$Capability.State
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Name  = $Name
            State = 'Unknown'
            Error = Get-SshAccessErrorText -ErrorRecord $_
        }
    }
}

function Install-SshAccessWindowsCapability {
    param([Parameter(Mandatory = $true)][string]$Name)

    Assert-SshAccessGlobalAdministrator
    $Command = Get-Command 'Add-WindowsCapability' -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $Command) {
        throw 'Add-WindowsCapability is unavailable on this Windows installation.'
    }

    $Current = Get-SshAccessWindowsCapabilityState -Name $Name
    if ($Current.State -eq 'Installed') {
        return [pscustomobject]@{
            Changed       = $false
            RestartNeeded = $false
        }
    }
    if ($Current.State -ne 'NotPresent') {
        throw "Windows capability '$Name' is in state '$($Current.State)'; refusing to install while its state is not known to be NotPresent."
    }

    $Result = Add-WindowsCapability -Online -Name $Name -ErrorAction Stop
    $RestartNeeded = $false
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['RestartNeeded']) {
        $RestartNeeded = [bool]$Result.RestartNeeded
    }
    return [pscustomobject]@{
        Changed       = $true
        RestartNeeded = $RestartNeeded
    }
}

function Remove-SshAccessWindowsCapability {
    param([Parameter(Mandatory = $true)][string]$Name)

    Assert-SshAccessGlobalAdministrator
    $Command = Get-Command 'Remove-WindowsCapability' -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $Command) {
        throw 'Remove-WindowsCapability is unavailable on this Windows installation.'
    }

    $Current = Get-SshAccessWindowsCapabilityState -Name $Name
    if ($Current.State -eq 'NotPresent') {
        return [pscustomobject]@{
            Changed       = $false
            RestartNeeded = $false
        }
    }
    if ($Current.State -ne 'Installed') {
        throw "Windows capability '$Name' is in state '$($Current.State)'; refusing to remove it while its ownership is uncertain."
    }

    $Result = Remove-WindowsCapability -Online -Name $Name -ErrorAction Stop
    $RestartNeeded = $false
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['RestartNeeded']) {
        $RestartNeeded = [bool]$Result.RestartNeeded
    }
    return [pscustomobject]@{
        Changed       = $true
        RestartNeeded = $RestartNeeded
    }
}

function Resolve-SshAccessGlobalExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$PreferredPath,
        [Parameter(Mandatory = $true)][string]$CommandName
    )

    if (Test-Path -LiteralPath $PreferredPath -PathType Leaf) {
        return $PreferredPath
    }
    # This domain reports the Windows optional feature, not an unrelated
    # OpenSSH binary supplied by Git, Cygwin, or an earlier PATH entry.
    $null = $CommandName
    return $null
}

function Get-SshAccessExecutableProbe {
    param(
        [Parameter(Mandatory = $true)][string]$PreferredPath,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ProbeArguments
    )

    $Path = Resolve-SshAccessGlobalExecutable `
        -PreferredPath $PreferredPath `
        -CommandName $CommandName
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            Presence = 'Missing'
            Probe    = 'Unavailable'
            Path     = $null
            ExitCode = $null
            Output   = $null
            Error    = $null
        }
    }

    try {
        $Result = Invoke-SshAccessCapturedProcess `
            -Executable $Path `
            -Arguments $ProbeArguments
        $Output = if (-not [string]::IsNullOrWhiteSpace($Result.StdOut)) {
            $Result.StdOut
        } else {
            $Result.StdErr
        }
        return [pscustomobject]@{
            Presence = 'Present'
            Probe    = 'Operational'
            Path     = $Path
            ExitCode = [int]$Result.ExitCode
            Output   = ConvertTo-SshAccessSingleLine -Text $Output
            Error    = $null
        }
    } catch {
        return [pscustomobject]@{
            Presence = 'Present'
            Probe    = 'Error'
            Path     = $Path
            ExitCode = $null
            Output   = $null
            Error    = Get-SshAccessErrorText -ErrorRecord $_
        }
    }
}

function Get-SshAccessClientState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Capability = Get-SshAccessWindowsCapabilityState -Name (Get-SshAccessClientCapabilityName)
    $ExecutablePath = Join-Path $Context.WindowsRoot 'System32\OpenSSH\ssh.exe'
    $Executable = Get-SshAccessExecutableProbe `
        -PreferredPath $ExecutablePath `
        -CommandName 'ssh.exe' `
        -ProbeArguments @('-V')

    $Installation = 'Unknown'
    if ($Capability.State -eq 'Installed' -or $Executable.Presence -eq 'Present') {
        $Installation = 'Installed'
    } elseif ($Capability.State -eq 'NotPresent' -and $Executable.Presence -eq 'Missing') {
        $Installation = 'NotInstalled'
    }

    return [pscustomobject]@{
        Installation = $Installation
        Capability   = $Capability
        Executable   = $Executable
    }
}

function Show-SshAccessClientState {
    [CmdletBinding(DefaultParameterSetName = 'Context')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Context')]
        [pscustomobject]$Context,
        [Parameter(Mandatory = $true, ParameterSetName = 'State')]
        [pscustomobject]$State
    )

    if ($PSCmdlet.ParameterSetName -eq 'Context') {
        $State = Get-SshAccessClientState -Context $Context
    }

    Write-SshAccessHeading -Text 'Windows OpenSSH client'
    Write-SshAccessField -Name 'Installation' -Value $State.Installation
    Write-SshAccessField -Name 'Capability' -Value $State.Capability.State
    Write-SshAccessField -Name 'Executable' -Value $State.Executable.Path
    Write-SshAccessField -Name 'Executable probe' -Value $State.Executable.Probe
    if (-not [string]::IsNullOrWhiteSpace($State.Executable.Output)) {
        Write-SshAccessField -Name 'Version' -Value $State.Executable.Output
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Capability.Error)) {
        Write-SshAccessField -Name 'Capability note' -Value $State.Capability.Error
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Executable.Error)) {
        Write-SshAccessField -Name 'Probe note' -Value $State.Executable.Error
    }
}

function Install-SshAccessClient {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $null = $Context
    $Result = Install-SshAccessWindowsCapability -Name (Get-SshAccessClientCapabilityName)
    if ($Result.Changed) {
        Write-Host 'OpenSSH client capability installed.'
    } else {
        Write-Host 'OpenSSH client capability is already installed.'
    }
    if ($Result.RestartNeeded) {
        Write-SshAccessWarning -Message 'Windows reports that a restart is required.'
    }
}
