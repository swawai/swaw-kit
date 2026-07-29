Set-StrictMode -Version 2.0

function Get-SshAccessDefaultShellRegistryPath {
    return 'HKLM:\SOFTWARE\OpenSSH'
}

function Get-SshAccessCmdPath {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    return Join-Path $Context.WindowsRoot 'System32\cmd.exe'
}

function Get-SshAccessWindowsPowerShellPath {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    return Join-Path $Context.WindowsRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Get-SshAccessShellKind {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [AllowNull()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return 'Invalid'
    }
    if ($Path.Equals((Get-SshAccessCmdPath -Context $Context), [StringComparison]::OrdinalIgnoreCase)) {
        return 'Cmd'
    }
    if ($Path.Equals((Get-SshAccessWindowsPowerShellPath -Context $Context), [StringComparison]::OrdinalIgnoreCase)) {
        return 'WindowsPowerShell'
    }
    return 'Custom'
}

function New-SshAccessDefaultCmdShellState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [AllowNull()][object]$CommandOption,
        [AllowNull()][object]$EscapeArguments
    )

    return [pscustomobject]@{
        Status              = 'Known'
        Kind                = 'Cmd'
        Path                = Get-SshAccessCmdPath -Context $Context
        Configured          = $false
        RegistryValue       = $null
        CommandOption       = $CommandOption
        EscapeArguments     = $EscapeArguments
        CompanionConfigured = ($null -ne $CommandOption -or $null -ne $EscapeArguments)
        Error               = $null
    }
}

function Get-SshAccessShellState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $RegistryPath = Get-SshAccessDefaultShellRegistryPath
    try {
        if (-not (Test-Path -LiteralPath $RegistryPath -PathType Container -ErrorAction Stop)) {
            return New-SshAccessDefaultCmdShellState `
                -Context $Context `
                -CommandOption $null `
                -EscapeArguments $null
        }
        $Properties = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
        $DefaultShellProperty = $Properties.PSObject.Properties['DefaultShell']
        $CommandOptionProperty = $Properties.PSObject.Properties['DefaultShellCommandOption']
        $EscapeArgumentsProperty = $Properties.PSObject.Properties['DefaultShellEscapeArguments']
        $CommandOption = if ($null -eq $CommandOptionProperty) {
            $null
        } else {
            $CommandOptionProperty.Value
        }
        $EscapeArguments = if ($null -eq $EscapeArgumentsProperty) {
            $null
        } else {
            $EscapeArgumentsProperty.Value
        }
        if ($null -eq $DefaultShellProperty) {
            return New-SshAccessDefaultCmdShellState `
                -Context $Context `
                -CommandOption $CommandOption `
                -EscapeArguments $EscapeArguments
        }

        $ConfiguredPath = [string]$DefaultShellProperty.Value
        return [pscustomobject]@{
            Status              = 'Known'
            Kind                = Get-SshAccessShellKind -Context $Context -Path $ConfiguredPath
            Path                = $ConfiguredPath
            Configured          = $true
            RegistryValue       = $ConfiguredPath
            CommandOption       = $CommandOption
            EscapeArguments     = $EscapeArguments
            CompanionConfigured = ($null -ne $CommandOption -or $null -ne $EscapeArguments)
            Error               = $null
        }
    } catch {
        return [pscustomobject]@{
            Status              = 'Unknown'
            Kind                = 'Unknown'
            Path                = $null
            Configured          = $null
            RegistryValue       = $null
            CommandOption       = $null
            EscapeArguments     = $null
            CompanionConfigured = $null
            Error               = Get-SshAccessErrorText -ErrorRecord $_
        }
    }
}

function Show-SshAccessShellState {
    [CmdletBinding(DefaultParameterSetName = 'Context')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Context')]
        [pscustomobject]$Context,
        [Parameter(Mandatory = $true, ParameterSetName = 'State')]
        [pscustomobject]$State
    )

    if ($PSCmdlet.ParameterSetName -eq 'Context') {
        $State = Get-SshAccessShellState -Context $Context
    }

    Write-SshAccessHeading -Text 'Windows OpenSSH server shell'
    Write-SshAccessField -Name 'Status' -Value $State.Status
    Write-SshAccessField -Name 'Shell' -Value $State.Kind
    Write-SshAccessField -Name 'Effective path' -Value $State.Path
    $ConfiguredText = if ($null -eq $State.Configured) {
        'Unknown'
    } elseif ($State.Configured) {
        'Yes'
    } else {
        'No (Windows default)'
    }
    Write-SshAccessField -Name 'Registry override' -Value $ConfiguredText
    Write-SshAccessField -Name 'Command option' -Value $State.CommandOption
    Write-SshAccessField -Name 'Escape arguments' -Value $State.EscapeArguments
    if ($State.CompanionConfigured -eq $true) {
        Write-SshAccessWarning -Message (
            'Companion shell registry values are configured and can change remote command behavior.'
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Error)) {
        Write-SshAccessField -Name 'Shell note' -Value $State.Error
    }
}

function Remove-SshAccessServerShellRegistryValues {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Container -ErrorAction Stop)) {
        return
    }
    $Properties = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
    foreach ($Name in $Names) {
        if ($null -ne $Properties.PSObject.Properties[$Name]) {
            Remove-ItemProperty `
                -LiteralPath $RegistryPath `
                -Name $Name `
                -ErrorAction Stop
        }
    }
}

function Set-SshAccessServerShellCmd {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $null = $Context
    Assert-SshAccessGlobalAdministrator
    $RegistryPath = Get-SshAccessDefaultShellRegistryPath
    Remove-SshAccessServerShellRegistryValues `
        -RegistryPath $RegistryPath `
        -Names @(
            'DefaultShellCommandOption',
            'DefaultShellEscapeArguments',
            'DefaultShell'
        )
    Write-Host 'OpenSSH server shell restored to the Windows default (cmd.exe).'
    Write-Host (
        'Cleared shell overrides: DefaultShell, ' +
        'DefaultShellCommandOption, DefaultShellEscapeArguments.'
    )
}

function Set-SshAccessServerShellPowerShell {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    Assert-SshAccessGlobalAdministrator
    $PowerShellPath = Get-SshAccessWindowsPowerShellPath -Context $Context
    if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        throw "Windows PowerShell executable not found: $PowerShellPath"
    }

    $RegistryPath = Get-SshAccessDefaultShellRegistryPath
    $null = New-Item -Path $RegistryPath -Force -ErrorAction Stop
    Remove-SshAccessServerShellRegistryValues `
        -RegistryPath $RegistryPath `
        -Names @(
            'DefaultShellCommandOption',
            'DefaultShellEscapeArguments'
        )
    # Commit the new shell only after every incompatible companion option has
    # been removed. A cleanup failure therefore leaves DefaultShell unchanged.
    $null = New-ItemProperty `
        -LiteralPath $RegistryPath `
        -Name 'DefaultShell' `
        -Value $PowerShellPath `
        -PropertyType String `
        -Force `
        -ErrorAction Stop
    Write-Host "OpenSSH server shell set to Windows PowerShell: $PowerShellPath"
    Write-Host (
        'Cleared companion options: DefaultShellCommandOption, ' +
        'DefaultShellEscapeArguments.'
    )
}
