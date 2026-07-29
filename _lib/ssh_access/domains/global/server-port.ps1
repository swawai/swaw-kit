Set-StrictMode -Version 2.0

function Get-SshAccessServerListenerState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    try {
        $Listeners = @(
            [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().
                GetActiveTcpListeners() |
                Where-Object { $_.Port -eq $Port }
        )
        return [pscustomobject]@{
            Port   = $Port
            Status = if ($Listeners.Count -gt 0) {
                'Listening'
            } else {
                'NotListening'
            }
            Count  = $Listeners.Count
            Error  = $null
        }
    } catch {
        return [pscustomobject]@{
            Port   = $Port
            Status = 'Unknown'
            Count  = $null
            Error  = Get-SshAccessErrorText -ErrorRecord $_
        }
    }
}

function Test-SshAccessServerPortListening {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    return (Get-SshAccessServerListenerState -Port $Port).Status -eq 'Listening'
}

function Wait-SshAccessServerPortListener {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $Deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $State = Get-SshAccessServerListenerState -Port $Port
        if ($State.Status -eq 'Listening') {
            return
        }
        if ($State.Status -eq 'Unknown') {
            throw "Cannot verify TCP/$Port listener state. $($State.Error)"
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "sshd did not begin listening on TCP/$Port."
}

function Assert-SshAccessServerPortAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$CurrentPort
    )

    if ($Port -eq $CurrentPort) {
        return
    }
    if (Test-SshAccessServerPortListening -Port $Port) {
        throw "TCP/$Port is already listening; refusing to move sshd onto a port in use."
    }
}

function Assert-SshAccessSshdConfiguration {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $Executable = Resolve-SshAccessOpenSshExecutable `
        -Context $Context `
        -Name 'sshd.exe'
    $Result = Invoke-SshAccessCapturedProcess `
        -Executable $Executable `
        -Arguments @('-t', '-f', $ConfigPath)
    if ($Result.ExitCode -eq 0) {
        return
    }
    $Detail = ([string]$Result.StdErr).Trim()
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        $Detail = ([string]$Result.StdOut).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        $Detail = "sshd.exe exited with code $($Result.ExitCode)."
    }
    throw "sshd configuration validation failed. $Detail"
}

function Restart-SshAccessServerForPortChange {
    $Service = Get-SshAccessRequiredServerService
    $Status = [string]$Service.Status
    if (@('Running', 'Stopped') -notcontains $Status) {
        throw "The sshd service is in transitional state '$Status'."
    }
    if ($Status -eq 'Running') {
        Stop-Service -Name 'sshd' -ErrorAction Stop
        $Service = Get-SshAccessRequiredServerService
        Wait-SshAccessServerService -Service $Service -Status 'Stopped'
    }

    Start-Service -Name 'sshd' -ErrorAction Stop
    $Service = Get-SshAccessRequiredServerService
    Wait-SshAccessServerService -Service $Service -Status 'Running'
}

function Assert-SshAccessRunningServerForPortChange {
    $Service = Get-SshAccessRequiredServerService
    $Status = [string]$Service.Status
    if ($Status -ne 'Running') {
        throw "The sshd service must be Running before changing its port; current state: $Status."
    }
}

function Resolve-SshAccessServerPortNumber {
    param([Parameter(Mandatory = $true)][string]$Value)

    $Port = 0
    if (-not [int]::TryParse($Value, [ref]$Port) -or
        $Port -lt 1 -or
        $Port -gt 65535) {
        throw 'The SSH server port must be an integer from 1 to 65535.'
    }
    return $Port
}

function Set-SshAccessServerPort {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    Assert-SshAccessGlobalAdministrator
    $ConfigPath = Get-SshAccessSshdConfigPath -Context $Context
    $Lock = Enter-SshAccessSshdConfigLock -ConfigPath $ConfigPath
    try {
        $State = Get-SshAccessServerPortConfigurationState -Context $Context
        $CurrentPort = Assert-SshAccessManagedServerPortState -State $State
        Assert-SshAccessRunningServerForPortChange
        Assert-SshAccessServerPortAvailable `
            -Port $Port `
            -CurrentPort $CurrentPort
        Assert-SshAccessSshdConfiguration `
            -Context $Context `
            -ConfigPath $ConfigPath

        # Normalize ownership while the old listener is still active. Recovery
        # can therefore restore reachability by reconciling this same port.
        Ensure-SshAccessServerFirewall -Port $CurrentPort

        [byte[]]$OriginalBytes = $State.Document.Bytes
        [byte[]]$CandidateBytes = New-SshAccessServerPortConfigBytes `
            -State $State `
            -Port $Port
        $ConfigChanged = -not (
            Test-SshAccessByteArrayEqual `
                -Left $OriginalBytes `
                -Right $CandidateBytes
        )
        $ConfigWritten = $false
        $FirewallMutationAttempted = $false
        $RestartAttempted = $false
        try {
            if ($ConfigChanged) {
                Write-SshAccessSshdConfigAtomic `
                    -Path $ConfigPath `
                    -Bytes $CandidateBytes `
                    -ExpectedBytes $OriginalBytes
                $ConfigWritten = $true
            }
            Assert-SshAccessSshdConfiguration `
                -Context $Context `
                -ConfigPath $ConfigPath

            if ($ConfigChanged) {
                $FirewallMutationAttempted = $true
                Ensure-SshAccessServerFirewall -Port $Port
            }

            $ListenerReady = Test-SshAccessServerPortListening -Port $Port
            if ($ConfigChanged -or -not $ListenerReady) {
                $RestartAttempted = $true
                Restart-SshAccessServerForPortChange
                Wait-SshAccessServerPortListener -Port $Port
            }
        } catch {
            $ChangeError = $_.Exception.Message
            $RecoveryErrors = New-Object Collections.Generic.List[string]
            if ($ConfigWritten) {
                try {
                    Write-SshAccessSshdConfigAtomic `
                        -Path $ConfigPath `
                        -Bytes $OriginalBytes `
                        -ExpectedBytes $CandidateBytes
                } catch {
                    $RecoveryErrors.Add(
                        "configuration restore: $($_.Exception.Message)"
                    )
                }
            }
            if ($FirewallMutationAttempted -or $ConfigWritten) {
                try {
                    Ensure-SshAccessServerFirewall -Port $CurrentPort
                } catch {
                    $RecoveryErrors.Add(
                        "firewall restore: $($_.Exception.Message)"
                    )
                }
            }
            if ($RestartAttempted) {
                try {
                    Restart-SshAccessServerForPortChange
                    Wait-SshAccessServerPortListener -Port $CurrentPort
                } catch {
                    $RecoveryErrors.Add(
                        "sshd restore: $($_.Exception.Message)"
                    )
                }
            }

            if ($RecoveryErrors.Count -eq 0) {
                throw "SSH port change failed; TCP/$CurrentPort was restored. $ChangeError"
            }
            throw (
                'SSH port change failed and recovery was incomplete. ' +
                "Change: $ChangeError Recovery: " +
                ([string]::Join(' ', [string[]]@($RecoveryErrors)))
            )
        }

        if ($ConfigChanged) {
            Write-Host "OpenSSH server port changed: TCP/$CurrentPort -> TCP/$Port"
        } else {
            Write-Host "OpenSSH server port is already TCP/$Port."
        }
        Write-Host "sshd configuration validated; firewall and listener are ready on TCP/$Port."
    } finally {
        if ($null -ne $Lock) {
            $Lock.Dispose()
        }
    }
}
