$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

$Utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8

function Get-RdpClientNativeArchitecture {
    $Architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        $Architecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        throw 'Windows architecture environment variables are unavailable.'
    }
    switch ($Architecture.ToUpperInvariant()) {
        'AMD64' { return 'AMD64' }
        'ARM64' { return 'ARM64' }
        'X86' { return 'x86' }
        default { throw "Unsupported Windows architecture: $Architecture" }
    }
}

function Get-RdpClientPsExecDownload {
    param([Parameter(Mandatory = $true)][string]$Architecture)

    switch ($Architecture) {
        'AMD64' {
            return [pscustomobject]@{
                FileName = 'PsExec64.exe'
                Uri      = 'https://live.sysinternals.com/PsExec64.exe'
            }
        }
        'ARM64' {
            return [pscustomobject]@{
                FileName = 'PsExec64a.exe'
                Uri      = 'https://live.sysinternals.com/ARM64/PsExec64a.exe'
            }
        }
        'x86' {
            return [pscustomobject]@{
                FileName = 'PsExec.exe'
                Uri      = 'https://live.sysinternals.com/PsExec.exe'
            }
        }
        default { throw "Unsupported Windows architecture: $Architecture" }
    }
}

function Get-RdpClientPsExecSignature {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    $Subject = ''
    if ($null -ne $Signature.SignerCertificate) {
        $Subject = [string]$Signature.SignerCertificate.Subject
    }
    return [pscustomobject]@{
        Status    = [string]$Signature.Status
        Subject   = $Subject
        IsTrusted = (
            [string]$Signature.Status -eq 'Valid' -and
            $Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'
        )
    }
}

function Get-RdpClientSshServerAddress {
    $Parts = @([string]$env:SSH_CONNECTION -split '\s+' | Where-Object {
        $_.Length -gt 0
    })
    if ($Parts.Count -lt 4) {
        throw 'SSH_CONNECTION is unavailable; the peer identity cannot be verified.'
    }
    $Address = $null
    if (-not [Net.IPAddress]::TryParse($Parts[2], [ref]$Address)) {
        throw "SSH_CONNECTION contains an invalid peer address: $($Parts[2])"
    }
    if ($Address.IsIPv4MappedToIPv6) {
        return $Address.MapToIPv4().ToString()
    }
    return $Address.ToString()
}

function Assert-RdpClientExpectedPeer {
    param(
        [Parameter(Mandatory = $true)][string]$PeerAddress,
        [Parameter(Mandatory = $true)][object[]]$ExpectedAddresses
    )

    if (-not @($ExpectedAddresses | Where-Object {
        [string]::Equals(
            [string]$_,
            $PeerAddress,
            [StringComparison]::OrdinalIgnoreCase
        )
    }).Count) {
        throw (
            "SSH peer $PeerAddress does not match the RDP full address " +
            "($($ExpectedAddresses -join ', '))."
        )
    }
}

function Write-RdpClientPsExecHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$PeerAddress,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Write-Output "[RDP] Peer PsExec $Title"
    Write-Output "  Peer:         $env:COMPUTERNAME ($PeerAddress via SSH)"
    Write-Output "  SSH account:  $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Output "  Architecture: $Architecture"
    Write-Output "  Path:         $Path"
}

try {
    $PayloadBase64 = '__RDP_CLIENT_PSEXEC_PAYLOAD__'
    $PayloadJson = $Utf8.GetString([Convert]::FromBase64String($PayloadBase64))
    $Request = $PayloadJson | ConvertFrom-Json
    $PeerAddress = Get-RdpClientSshServerAddress
    Assert-RdpClientExpectedPeer `
        -PeerAddress $PeerAddress `
        -ExpectedAddresses @($Request.ExpectedAddresses)

    $Architecture = Get-RdpClientNativeArchitecture
    $Download = Get-RdpClientPsExecDownload -Architecture $Architecture
    $LocalAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
        throw 'The peer SSH account has no LocalApplicationData directory.'
    }
    $ManagedDirectory = Join-Path $LocalAppData 'swaw-kit\rdp-client'
    $ManagedPath = Join-Path $ManagedDirectory 'psexec.exe'
    $Present = [IO.File]::Exists($ManagedPath)
    $Signature = $null
    if ($Present) {
        $Signature = Get-RdpClientPsExecSignature -Path $ManagedPath
    }

    if ($Request.Action -eq 'status') {
        Write-RdpClientPsExecHeader `
            -Title 'status' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        if (-not $Present) {
            Write-Output '  State:        ABSENT'
            exit 0
        }
        $Version = [Diagnostics.FileVersionInfo]::GetVersionInfo($ManagedPath).FileVersion
        $Hash = (Get-FileHash -LiteralPath $ManagedPath -Algorithm SHA256).Hash
        Write-Output '  State:        PRESENT'
        Write-Output "  Version:      $Version"
        Write-Output "  Signature:    $($Signature.Status)"
        Write-Output "  Signer:       $($Signature.Subject)"
        Write-Output "  SHA-256:      $Hash"
        exit 0
    }

    if ($Request.Action -eq 'add') {
        if ([bool]$Request.DryRun) {
            Write-RdpClientPsExecHeader `
                -Title 'add plan' `
                -PeerAddress $PeerAddress `
                -Architecture $Architecture `
                -Path $ManagedPath
            if ($Present -and $Signature.IsTrusted) {
                Write-Output '  PRESENT valid Microsoft-signed PsExec'
            } elseif ($Present) {
                Write-Output "  REPLACE $ManagedPath"
            } else {
                Write-Output "  ADD     $ManagedPath"
            }
            Write-Output "  SOURCE  $($Download.Uri)"
            Write-Output '  VERIFY  Authenticode signer=Microsoft Corporation'
            Write-Output '[RDP] Dry run: no peer changes were made.'
            exit 0
        }
        if ($Present -and $Signature.IsTrusted) {
            Write-RdpClientPsExecHeader `
                -Title 'add' `
                -PeerAddress $PeerAddress `
                -Architecture $Architecture `
                -Path $ManagedPath
            Write-Output '[RDP] Microsoft-signed PsExec is already present.'
            exit 0
        }

        [IO.Directory]::CreateDirectory($ManagedDirectory) | Out-Null
        $TemporaryPath = Join-Path $ManagedDirectory (
            '.psexec-' + [Guid]::NewGuid().ToString('N') + '.exe'
        )
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $Download.Uri `
                -OutFile $TemporaryPath
            $DownloadedSignature = Get-RdpClientPsExecSignature -Path $TemporaryPath
            if (-not $DownloadedSignature.IsTrusted) {
                throw (
                    'Downloaded PsExec failed Microsoft Authenticode verification: ' +
                    "$($DownloadedSignature.Status), $($DownloadedSignature.Subject)"
                )
            }
            Move-Item -LiteralPath $TemporaryPath -Destination $ManagedPath -Force
        } finally {
            if ([IO.File]::Exists($TemporaryPath)) {
                Remove-Item -LiteralPath $TemporaryPath -Force
            }
        }
        Write-RdpClientPsExecHeader `
            -Title 'add' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        Write-Output "[RDP] Added $($Download.FileName) from Microsoft Sysinternals Live."
        exit 0
    }

    if ($Request.Action -eq 'remove') {
        if ([bool]$Request.DryRun) {
            Write-RdpClientPsExecHeader `
                -Title 'remove plan' `
                -PeerAddress $PeerAddress `
                -Architecture $Architecture `
                -Path $ManagedPath
            if ($Present) {
                Write-Output "  REMOVE  $ManagedPath"
            } else {
                Write-Output '  ABSENT  no managed PsExec file'
            }
            Write-Output '[RDP] Dry run: no peer changes were made.'
            exit 0
        }
        if ($Present) {
            Remove-Item -LiteralPath $ManagedPath -Force
        }
        if ([IO.Directory]::Exists($ManagedDirectory) -and
            @(Get-ChildItem -LiteralPath $ManagedDirectory -Force).Count -eq 0) {
            [IO.Directory]::Delete($ManagedDirectory)
        }
        Write-RdpClientPsExecHeader `
            -Title 'remove' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        if ($Present) {
            Write-Output '[RDP] Removed the managed PsExec file.'
        } else {
            Write-Output '[RDP] Managed PsExec was already absent.'
        }
        exit 0
    }

    if (-not $Present) {
        throw 'Managed PsExec is absent. Run .peer psexec add first.'
    }
    if (-not $Signature.IsTrusted) {
        throw (
            'Managed PsExec does not have a valid Microsoft signature. ' +
            'Run .peer psexec add to replace it.'
        )
    }
    Write-RdpClientPsExecHeader `
        -Title 'run' `
        -PeerAddress $PeerAddress `
        -Architecture $Architecture `
        -Path $ManagedPath
    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $PsExecOutput = @(& $ManagedPath @($Request.Arguments) 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
    $PsExecOutput | ForEach-Object { Write-Output ([string]$_) }
    exit $ExitCode
} catch {
    Write-Output "[ERROR] $($_.Exception.Message)"
    exit 1
}
