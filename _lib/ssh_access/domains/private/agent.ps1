Set-StrictMode -Version 2.0

function Get-SshAccessServiceStartType {
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    $RegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    try {
        $StartValue = (Get-ItemProperty -LiteralPath $RegistryPath -Name Start -ErrorAction Stop).Start
        switch ([int]$StartValue) {
            2 { return 'Automatic' }
            3 { return 'Manual' }
            4 { return 'Disabled' }
            default { return "Other ($StartValue)" }
        }
    } catch {
        return 'Unknown'
    }
}

function Get-SshAccessAgentServiceState {
    $ServiceErrors = @()
    $Service = Get-Service `
        -Name 'ssh-agent' `
        -ErrorAction SilentlyContinue `
        -ErrorVariable ServiceErrors
    if ($null -eq $Service) {
        if ($ServiceErrors.Count -gt 0 -and
            $ServiceErrors[0].CategoryInfo.Category -ne
                [Management.Automation.ErrorCategory]::ObjectNotFound) {
            return [pscustomobject]@{
                Installed = $null
                Status    = 'Unknown'
                StartType = Get-SshAccessServiceStartType -ServiceName 'ssh-agent'
                Error     = $ServiceErrors[0].Exception.Message
            }
        }
        return [pscustomobject]@{
            Installed = $false
            Status    = 'not-installed'
            StartType = 'not-installed'
            Error     = ''
        }
    }

    return [pscustomobject]@{
        Installed = $true
        Status    = $Service.Status.ToString()
        StartType = Get-SshAccessServiceStartType -ServiceName 'ssh-agent'
        Error     = ''
    }
}

function Get-SshAccessPrivateState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Service = Get-SshAccessAgentServiceState
    if ($null -eq $Service.Installed) {
        return [pscustomobject]@{
            ServiceInstalled = $null
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'unavailable'
            BoundKey         = 'unknown'
            Error            = "The ssh-agent service state could not be read. $($Service.Error)"
        }
    }
    if ($Service.Installed -eq $false) {
        return [pscustomobject]@{
            ServiceInstalled = $false
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'unavailable'
            BoundKey         = 'unknown'
            Error            = 'ssh-agent is not installed, so its persistent identity store cannot be verified.'
        }
    }
    if ($Service.Status -ne 'Running') {
        return [pscustomobject]@{
            ServiceInstalled = $true
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'stopped'
            BoundKey         = 'unknown'
            Error            = 'ssh-agent is stopped; Windows may retain identities across service restarts.'
        }
    }

    try {
        $SshAdd = Resolve-SshAccessOpenSshExecutable -Context $Context -Name 'ssh-add.exe'
        $Result = Invoke-SshAccessCapturedProcess -Executable $SshAdd -Arguments @('-L')
    } catch {
        return [pscustomobject]@{
            ServiceInstalled = $true
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'unavailable'
            BoundKey         = 'unknown'
            Error            = $_.Exception.Message
        }
    }

    $Combined = ($Result.StdOut + [Environment]::NewLine + $Result.StdErr).Trim()
    if ($Result.ExitCode -eq 1 -and $Combined -match '(?i)no identities') {
        return [pscustomobject]@{
            ServiceInstalled = $true
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'empty'
            BoundKey         = 'not-loaded'
            Error            = ''
        }
    }
    if ($Result.ExitCode -ne 0) {
        return [pscustomobject]@{
            ServiceInstalled = $true
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'unavailable'
            BoundKey         = 'unknown'
            Error            = if ($Combined.Length -gt 0) {
                "ssh-add -L failed (exit $($Result.ExitCode)): $Combined"
            } else {
                "ssh-add -L failed with exit code $($Result.ExitCode)."
            }
        }
    }

    try {
        if (Test-Path -LiteralPath $Context.PrivateKeyPath -PathType Leaf) {
            $BoundFingerprint = Get-SshAccessPrivateKeyFingerprint -Context $Context
        } elseif (Test-Path -LiteralPath $Context.PublicKeyPath -PathType Leaf) {
            $BoundFingerprint = (Read-SshAccessPublicKeyFile -Path $Context.PublicKeyPath).Fingerprint
        } else {
            throw 'Neither bound key file exists, so a persistent agent identity cannot be identified.'
        }
    } catch {
        return [pscustomobject]@{
            ServiceInstalled = $true
            ServiceStatus    = $Service.Status
            ServiceStartType = $Service.StartType
            AgentAccess      = 'available'
            BoundKey         = 'unknown'
            Error            = $_.Exception.Message
        }
    }

    $Loaded = $false
    foreach ($Line in ($Result.StdOut -split '\r?\n')) {
        $Key = ConvertFrom-SshAccessPublicKeyLine -Line $Line
        if ($null -ne $Key -and
            [string]::Equals($Key.Fingerprint, $BoundFingerprint, [StringComparison]::Ordinal)) {
            $Loaded = $true
            break
        }
    }

    return [pscustomobject]@{
        ServiceInstalled = $true
        ServiceStatus    = $Service.Status
        ServiceStartType = $Service.StartType
        AgentAccess      = 'available'
        BoundKey         = if ($Loaded) { 'loaded' } else { 'not-loaded' }
        Error            = ''
    }
}

function Show-SshAccessPrivateState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [pscustomobject]$State = (Get-SshAccessPrivateState -Context $Context)
    )

    Write-SshAccessHeading 'Private key application'
    $InstalledText = if ($null -eq $State.ServiceInstalled) {
        'Unknown'
    } else {
        $State.ServiceInstalled
    }
    Write-SshAccessField 'Agent installed' $InstalledText
    Write-SshAccessField 'Agent service' $State.ServiceStatus
    Write-SshAccessField 'Agent startup' $State.ServiceStartType
    Write-SshAccessField 'Agent access' $State.AgentAccess
    Write-SshAccessField 'Bound key' $State.BoundKey
    if (-not [string]::IsNullOrWhiteSpace($State.Error)) {
        Write-SshAccessField 'Problem' $State.Error
    }
}

function Start-SshAccessAgentElevated {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][string[]]$DisplayArguments
    )

    $Script = @'
$ErrorActionPreference = 'Stop'
$Service = Get-Service -Name 'ssh-agent' -ErrorAction Stop
$StartValue = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent' -Name Start -ErrorAction Stop).Start
if ([int]$StartValue -eq 4) {
    Set-Service -Name 'ssh-agent' -StartupType Automatic
}
if ($Service.Status -ne 'Running') {
    Start-Service -Name 'ssh-agent'
}
(Get-Service -Name 'ssh-agent').WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
Write-Host 'ssh-agent is running.'
Write-Host ''
[void](Read-Host 'Press Enter to close')
exit 0
'@
    $Display = Format-SshAccessCommand `
        -CommandName $Context.CommandName `
        -Arguments $DisplayArguments
    return Start-SshAccessElevatedPowerShell -Script $Script -DisplayCommand $Display
}

function Start-SshAccessAgentForCurrentUser {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][bool]$Uac,
        [Parameter(Mandatory = $true)][string[]]$RetryArguments
    )

    $RetryCommand = Format-SshAccessCommand `
        -CommandName $Context.CommandName `
        -Arguments $RetryArguments
    $Service = Get-SshAccessAgentServiceState
    if ($null -eq $Service.Installed) {
        throw "The ssh-agent service state could not be read. $($Service.Error)"
    }
    if ($Service.Installed -eq $false) {
        throw "ssh-agent is not installed. Run: $(Format-SshAccessCommand -CommandName $Context.CommandName -Arguments @('.global', 'client', 'install', '--uac'))"
    }
    if ($Service.Status -eq 'Running') {
        return
    }

    if (Test-SshAccessAdministrator) {
        if ($Service.StartType -eq 'Disabled') {
            Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction Stop
        }
        Start-Service -Name 'ssh-agent' -ErrorAction Stop
        (Get-Service -Name 'ssh-agent').WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        return
    }

    if ($Service.StartType -ne 'Disabled') {
        try {
            Start-Service -Name 'ssh-agent' -ErrorAction Stop
            (Get-Service -Name 'ssh-agent').WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
            return
        } catch {
            if (-not $Uac) {
                throw "ssh-agent could not be started without administrator privileges. Run: $RetryCommand"
            }
        }
    } elseif (-not $Uac) {
        throw "ssh-agent is disabled. Run: $RetryCommand"
    }

    $ExitCode = Start-SshAccessAgentElevated `
        -Context $Context `
        -DisplayArguments $RetryArguments
    if ($ExitCode -ne 0) {
        throw "The elevated ssh-agent setup failed with exit code $ExitCode."
    }

    $Refreshed = Get-SshAccessAgentServiceState
    if ($Refreshed.Status -ne 'Running') {
        throw 'The elevated setup completed, but ssh-agent is not running.'
    }
}

function Remove-SshAccessBoundKeyFromAgent {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $IdentityPath = if (Test-Path -LiteralPath $Context.PublicKeyPath -PathType Leaf) {
        $Context.PublicKeyPath
    } elseif (Test-Path -LiteralPath $Context.PrivateKeyPath -PathType Leaf) {
        $Context.PrivateKeyPath
    } else {
        throw 'Neither bound key file exists; the agent identity cannot be selected safely.'
    }

    $SshAdd = Resolve-SshAccessOpenSshExecutable -Context $Context -Name 'ssh-add.exe'
    $ExitCode = Invoke-SshAccessConsoleProcess `
        -Executable $SshAdd `
        -Arguments @('-d', $IdentityPath)
    if ($ExitCode -eq 0) {
        Write-Host 'Unloaded the bound key from ssh-agent.' -ForegroundColor Green
    }
    return $ExitCode
}
