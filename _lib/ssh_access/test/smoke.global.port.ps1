[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot
try {
    $SshDirectory = Join-Path $ScratchRoot 'ssh'
    [void][IO.Directory]::CreateDirectory($SshDirectory)
    $ConfigPath = Join-Path $SshDirectory 'sshd_config'
    $Context = [pscustomobject]@{
        ProgramData = $ScratchRoot
        WindowsRoot = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::Windows
        )
    }
    $Utf8 = New-Object Text.UTF8Encoding($false)

    function Set-TestSshdConfig {
        param([string]$Text)

        [IO.File]::WriteAllText($ConfigPath, $Text, $Utf8)
    }

    Write-Host '[TEST] Port parser recognizes the Windows default and one explicit port'
    Set-TestSshdConfig "#Port 22`r`nMatch Group administrators`r`n"
    $State = Get-SshAccessServerPortConfigurationState -Context $Context
    Assert-SshAccessTestEqual $State.Status 'Known' 'The default config should be manageable.'
    Assert-SshAccessTestEqual $State.Port 22 'A commented Port should retain the OpenSSH default.'
    Assert-SshAccessTestEqual $State.Source 'Default' 'The default port source should be explicit.'
    [byte[]]$Candidate = New-SshAccessServerPortConfigBytes -State $State -Port 2222
    $CandidateText = $Utf8.GetString($Candidate)
    Assert-SshAccessTestContains `
        $CandidateText `
        "Port 2222`r`nMatch Group administrators" `
        'A generated Port directive should stay before the first Match block.'

    Set-TestSshdConfig "  Port 2200 # retained`nMatch All`n"
    $State = Get-SshAccessServerPortConfigurationState -Context $Context
    Assert-SshAccessTestEqual $State.Port 2200 'One explicit port should be detected.'
    [byte[]]$Candidate = New-SshAccessServerPortConfigBytes -State $State -Port 2201
    Assert-SshAccessTestContains `
        ($Utf8.GetString($Candidate)) `
        '  Port 2201 # retained' `
        'Changing an explicit port should preserve indentation and its inline comment.'

    Write-Host '[TEST] Complex sshd port layouts fail closed'
    foreach ($Case in @(
        [pscustomobject]@{
            Text    = "Port 22`nPort 2222`n"
            Pattern = '*Multiple active Port directives*'
        },
        [pscustomobject]@{
            Text    = "ListenAddress 127.0.0.1:2222`n"
            Pattern = '*port-qualified ListenAddress*'
        },
        [pscustomobject]@{
            Text    = "Include sshd_config.d/*.conf`n"
            Pattern = '*Include is not managed*'
        }
    )) {
        Set-TestSshdConfig $Case.Text
        $State = Get-SshAccessServerPortConfigurationState -Context $Context
        Assert-SshAccessTestEqual `
            $State.Status `
            'Unsupported' `
            'A complex port layout should be visible but not mutable.'
        Assert-SshAccessTestThrowsLike `
            { Assert-SshAccessManagedServerPortState -State $State } `
            $Case.Pattern `
            'A complex port layout should fail before mutation.'
    }

    Write-Host '[TEST] Port change coordinates config, firewall, restart, and listener'
    Set-TestSshdConfig "#Port 22`r`nMatch Group administrators`r`n"
    $script:ActiveTestPort = 22
    $script:PortRestartCalls = 0
    $script:PortFirewallCalls = New-Object Collections.Generic.List[int]
    $script:FailListenerPort = 0
    $script:FailValidationPort = 0

    function Assert-SshAccessGlobalAdministrator {
    }
    function Get-SshAccessRequiredServerService {
        return [pscustomobject]@{ Status = 'Running' }
    }
    function Assert-SshAccessSshdConfiguration {
        param(
            [pscustomobject]$Context,
            [string]$ConfigPath
        )

        $Text = [IO.File]::ReadAllText($ConfigPath)
        if ($Text -match '(?im)^\s*Port\s+(\d+)\s*' -and
            [int]$Matches[1] -eq $script:FailValidationPort) {
            throw "mock validation failure on TCP/$($Matches[1])"
        }
    }
    function Ensure-SshAccessServerFirewall {
        param([int]$Port)

        $script:PortFirewallCalls.Add($Port)
    }
    function Test-SshAccessServerPortListening {
        param([int]$Port)

        return $script:ActiveTestPort -eq $Port
    }
    function Restart-SshAccessServerForPortChange {
        $script:PortRestartCalls++
        $Text = [IO.File]::ReadAllText($ConfigPath)
        if ($Text -match '(?im)^\s*Port\s+(\d+)\s*') {
            $script:ActiveTestPort = [int]$Matches[1]
        } else {
            $script:ActiveTestPort = 22
        }
    }
    function Wait-SshAccessServerPortListener {
        param([int]$Port)

        if ($Port -eq $script:FailListenerPort) {
            throw "mock listener failure on TCP/$Port"
        }
        if ($script:ActiveTestPort -ne $Port) {
            throw "mock listener mismatch on TCP/$Port"
        }
    }

    Set-SshAccessServerPort -Context $Context -Port 2222
    $ChangedText = [IO.File]::ReadAllText($ConfigPath)
    Assert-SshAccessTestContains `
        $ChangedText `
        'Port 2222' `
        'A successful port change should commit sshd_config.'
    Assert-SshAccessTestEqual `
        ([string]::Join(',', [int[]]@($script:PortFirewallCalls))) `
        '22,2222' `
        'A port change should normalize old coverage before allowing the new port.'
    Assert-SshAccessTestEqual `
        $script:PortRestartCalls `
        1 `
        'A changed port should restart sshd once.'

    Write-Host '[TEST] Reapplying the ready port is idempotent'
    $script:PortFirewallCalls.Clear()
    $script:PortRestartCalls = 0
    Set-SshAccessServerPort -Context $Context -Port 2222
    Assert-SshAccessTestEqual `
        ([string]::Join(',', [int[]]@($script:PortFirewallCalls))) `
        '2222' `
        'An idempotent set should only reconcile current firewall coverage.'
    Assert-SshAccessTestEqual `
        $script:PortRestartCalls `
        0 `
        'An already listening port should not restart sshd.'

    Write-Host '[TEST] Candidate validation failure restores bytes without restarting sshd'
    $script:PortFirewallCalls.Clear()
    $script:FailValidationPort = 2201
    Assert-SshAccessTestThrowsLike `
        { Set-SshAccessServerPort -Context $Context -Port 2201 } `
        '*TCP/2222 was restored*' `
        'A rejected candidate should report that the original config was restored.'
    Assert-SshAccessTestContains `
        ([IO.File]::ReadAllText($ConfigPath)) `
        'Port 2222' `
        'A rejected candidate must restore the original config bytes.'
    Assert-SshAccessTestEqual `
        $script:PortRestartCalls `
        0 `
        'A candidate rejected before service restart must not disrupt sshd.'
    $script:FailValidationPort = 0

    Write-Host '[TEST] Listener failure restores config, firewall, and old listener'
    $script:PortFirewallCalls.Clear()
    $script:PortRestartCalls = 0
    $script:FailListenerPort = 2200
    Assert-SshAccessTestThrowsLike `
        { Set-SshAccessServerPort -Context $Context -Port 2200 } `
        '*TCP/2222 was restored*' `
        'A failed listener verification should report successful recovery.'
    $RestoredText = [IO.File]::ReadAllText($ConfigPath)
    Assert-SshAccessTestContains `
        $RestoredText `
        'Port 2222' `
        'Recovery should restore the prior sshd_config bytes.'
    Assert-SshAccessTestEqual `
        ([string]::Join(',', [int[]]@($script:PortFirewallCalls))) `
        '2222,2200,2222' `
        'Recovery should restore firewall coverage for the old port.'
    Assert-SshAccessTestEqual `
        $script:PortRestartCalls `
        2 `
        'Recovery should restart once for the candidate and once for the old port.'
    Assert-SshAccessTestEqual `
        $script:ActiveTestPort `
        2222 `
        'Recovery should leave the old listener active.'
    Assert-SshAccessTestEqual `
        @(
            Get-ChildItem -LiteralPath $SshDirectory -Force |
                Where-Object { $_.Name -like '.sshd_config.*' }
        ).Count `
        0 `
        'Successful commits and recovery should clean temporary config backups.'

    Write-Host 'ssh access global port tests: PASS' -ForegroundColor Green
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}
