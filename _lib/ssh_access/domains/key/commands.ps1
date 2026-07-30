Set-StrictMode -Version 2.0

function Invoke-SshAccessKeyGenerate {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [bool]$NoPassphrase = $false
    )

    $State = Get-SshAccessKeyState -Context $Context
    if ($State.PrivateExists -or $State.PublicExists) {
        throw "Refusing to overwrite an existing key file. Private: $($Context.PrivateKeyPath); public: $($Context.PublicKeyPath)"
    }

    $Parent = Split-Path -Parent $Context.PrivateKeyPath
    if ([string]::IsNullOrWhiteSpace($Parent)) {
        throw "The private key path has no parent directory: $($Context.PrivateKeyPath)"
    }
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Parent -Force)
    }

    $TemporaryPrivatePath = Join-Path $Parent (
        '.sshaccess-generate-' + [Guid]::NewGuid().ToString('N')
    )
    $TemporaryPublicPath = $TemporaryPrivatePath + '.pub'
    $SshKeygen = Resolve-SshAccessOpenSshExecutable -Context $Context -Name 'ssh-keygen.exe'
    Write-Host "Generating $($Context.KeyType) key pair:"
    Write-Host "  $($Context.PrivateKeyPath)"
    [string[]]$KeygenArguments = @(
        '-t', $Context.KeyType,
        '-f', $TemporaryPrivatePath,
        '-C', $Context.KeyComment
    )
    if ($NoPassphrase) {
        $KeygenArguments += @('-N', '')
    }
    try {
        $ExitCode = Invoke-SshAccessConsoleProcess `
            -Executable $SshKeygen `
            -Arguments $KeygenArguments `
            -WorkingDirectory $Parent

        if ($ExitCode -ne 0) {
            throw "ssh-keygen failed with exit code $ExitCode."
        }
        if (-not (Test-Path -LiteralPath $TemporaryPrivatePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $TemporaryPublicPath -PathType Leaf)) {
            throw 'ssh-keygen reported success but did not create both temporary key files.'
        }

        $PublicKey = Read-SshAccessPublicKeyFile -Path $TemporaryPublicPath
        if ((Test-Path -LiteralPath $Context.PrivateKeyPath) -or
            (Test-Path -LiteralPath $Context.PublicKeyPath)) {
            throw 'A target key path appeared during generation; refusing to overwrite it.'
        }

        # Move the non-secret public key first. File.Move never overwrites an
        # existing destination, so even a concurrent creator wins safely.
        [IO.File]::Move($TemporaryPublicPath, $Context.PublicKeyPath)
        try {
            [IO.File]::Move($TemporaryPrivatePath, $Context.PrivateKeyPath)
        } catch {
            $MoveError = $_
            try {
                $MovedPublicKey = Read-SshAccessPublicKeyFile -Path $Context.PublicKeyPath
                if ([string]::Equals(
                        $MovedPublicKey.Identity,
                        $PublicKey.Identity,
                        [StringComparison]::Ordinal
                    )) {
                    Remove-Item -LiteralPath $Context.PublicKeyPath -Force
                }
            } catch {
                # Preserve any path that can no longer be proven to be ours.
            }
            throw $MoveError
        }

        Write-Host "Generated: $($PublicKey.Fingerprint)" -ForegroundColor Green
        return 0
    } finally {
        foreach ($TemporaryPath in @($TemporaryPrivatePath, $TemporaryPublicPath)) {
            if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-SshAccessKeyFingerprint {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $PublicKey = Read-SshAccessPublicKeyFile -Path $Context.PublicKeyPath
    Write-Host $PublicKey.Fingerprint
    return 0
}

function Start-SshAccessKeyDirectoryExplorer {
    param(
        [Parameter(Mandatory = $true)][string]$ExplorerPath,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $StartInfo = New-Object Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $ExplorerPath
    $StartInfo.Arguments = ConvertTo-SshAccessWindowsArguments -Arguments @($Directory)
    $StartInfo.WorkingDirectory = $Directory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $false

    $Process = [Diagnostics.Process]::Start($StartInfo)
    if ($null -eq $Process) {
        throw "Failed to open the key directory: $Directory"
    }
    $Process.Dispose()
}

function Open-SshAccessKeyDirectory {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Directory = Split-Path -Parent $Context.PublicKeyPath
    if ([string]::IsNullOrWhiteSpace($Directory) -or
        -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "The key directory does not exist: $Directory. Generate the key pair first or create its parent directory."
    }

    $ExplorerPath = Join-Path $Context.WindowsRoot 'explorer.exe'
    if (-not (Test-Path -LiteralPath $ExplorerPath -PathType Leaf)) {
        throw "Trusted Windows File Explorer was not found: $ExplorerPath"
    }

    Start-SshAccessKeyDirectoryExplorer `
        -ExplorerPath $ExplorerPath `
        -Directory $Directory
    Write-Host "Opened key directory: $Directory"
    return 0
}

function Invoke-SshAccessElevatedAuthorizationCheck {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $BootstrapPath = Join-Path $Context.KitRoot 'runtime\bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
        throw "Bootstrap script not found; cannot elevate the authorization check: $BootstrapPath"
    }

    $EnvironmentScript = Get-SshAccessContextEnvironmentScript -Context $Context
    $BootstrapLiteral = ConvertTo-SshAccessPowerShellLiteral $BootstrapPath
    $KitRootLiteral = ConvertTo-SshAccessPowerShellLiteral $Context.KitRoot
    $Script = @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
$EnvironmentScript
. $BootstrapLiteral
`$ProbeContext = New-SshAccessContext -KitRoot $KitRootLiteral
`$State = Get-SshAccessPublicState -Context `$ProbeContext
Write-Host ('Authorization check: ' + `$State.Authorization)
if (-not [string]::IsNullOrWhiteSpace(`$State.Error)) {
    Write-Host ('Reason: ' + `$State.Error)
}
`$ExitCode = if (`$State.Authorization -eq 'not-granted') {
    0
} elseif (@('granted', 'option-bound', 'ambiguous') -contains `$State.Authorization) {
    40
} else {
    41
}
Write-Host ''
[void](Read-Host 'Press Enter to close')
exit `$ExitCode
"@
    $Display = Format-SshAccessCommand `
        -CommandName $Context.CommandName `
        -Arguments @('.key', 'delete', '--yes', '--uac')
    return Start-SshAccessElevatedPowerShell -Script $Script -DisplayCommand $Display
}

function Assert-SshAccessKeyNotAuthorized {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][bool]$Uac
    )

    $PublicState = Get-SshAccessPublicState -Context $Context
    if (@('granted', 'option-bound', 'ambiguous') -contains $PublicState.Authorization) {
        throw "The public-key identity is still referenced in authorized_keys. Run '$(Format-SshAccessCommand -CommandName $Context.CommandName -Arguments @('.public', 'revoke'))' first."
    }
    if ($PublicState.Authorization -eq 'not-granted') {
        return
    }

    if (Test-SshAccessAdministrator) {
        throw "The authorization state remains unknown in an elevated process. $($PublicState.Error)"
    }
    if (-not $Uac) {
        $Retry = Format-SshAccessCommand `
            -CommandName $Context.CommandName `
            -Arguments @('.key', 'delete', '--yes', '--uac')
        throw "The authorization state could not be verified; refusing to orphan an authorization. $($PublicState.Error) Run: $Retry"
    }

    $ProbeExitCode = Invoke-SshAccessElevatedAuthorizationCheck -Context $Context
    switch ($ProbeExitCode) {
        0 { return }
        40 {
            throw "The public-key identity is still referenced in authorized_keys. Revoke it before deleting the key files."
        }
        default {
            throw "The elevated authorization check failed or remained unknown (exit $ProbeExitCode). Key files were not deleted."
        }
    }
}

function Invoke-SshAccessKeyDelete {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][bool]$Uac
    )

    $KeyState = Get-SshAccessKeyState -Context $Context
    if (-not $KeyState.PrivateExists -and -not $KeyState.PublicExists) {
        Write-Host 'The bound key files are already absent.'
        return 0
    }

    if ($KeyState.PrivateExists -and -not $KeyState.PublicExists) {
        throw 'The public key file is missing. Refusing to delete the private key because an existing authorization can no longer be identified safely.'
    }
    if ($KeyState.PublicExists -and $KeyState.PublicKeyState -ne 'valid') {
        throw "Refusing to delete while the public key cannot be identified. $($KeyState.Error)"
    }
    if ($KeyState.PrivateExists -and
        $KeyState.PublicExists -and
        $KeyState.PairConsistency -ne 'matching') {
        throw "Refusing to delete a mismatched or unverifiable key pair. $($KeyState.Error)"
    }

    if ($KeyState.PublicExists) {
        Assert-SshAccessKeyNotAuthorized -Context $Context -Uac $Uac
    }

    $AgentService = Get-SshAccessAgentServiceState
    if ($AgentService.Installed -eq $true -and $AgentService.Status -ne 'Running') {
        Start-SshAccessAgentForCurrentUser `
            -Context $Context `
            -Uac $Uac `
            -RetryArguments @('.key', 'delete', '--yes', '--uac')
    }
    $PrivateState = Get-SshAccessPrivateState -Context $Context
    if ($PrivateState.BoundKey -eq 'loaded') {
        [int]$UnloadExitCode = Remove-SshAccessBoundKeyFromAgent -Context $Context
        if ($UnloadExitCode -ne 0) {
            throw "The bound private key could not be unloaded; key files were not deleted."
        }
    } elseif ($PrivateState.BoundKey -eq 'unknown') {
        throw "The ssh-agent state could not be verified; key files were not deleted. $($PrivateState.Error)"
    }

    foreach ($Path in @($Context.PrivateKeyPath, $Context.PublicKeyPath)) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Remove-Item -LiteralPath $Path -Force
            Write-Host "Deleted: $Path"
        }
    }
    return 0
}

function Invoke-SshAccessKeyCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    if ($Arguments.Count -eq 0) {
        throw "Missing .key command. Usage: $($Context.CommandName) .key status|dir|gen|fp|delete"
    }

    $Action = $Arguments[0].ToLowerInvariant()
    if ($Action -eq 'generate') {
        $Action = 'gen'
    }
    if ($Action -eq 'fingerprint') {
        $Action = 'fp'
    }
    [string[]]$Rest = @($Arguments | Select-Object -Skip 1)
    switch ($Action) {
        'status' {
            Assert-SshAccessNoArguments -Arguments $Rest -Usage "$($Context.CommandName) .key status"
            Show-SshAccessKeyState -Context $Context
            return 0
        }
        'dir' {
            Assert-SshAccessNoArguments -Arguments $Rest -Usage "$($Context.CommandName) .key dir"
            return Open-SshAccessKeyDirectory -Context $Context
        }
        'gen' {
            $Options = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('-N') `
                -Usage "$($Context.CommandName) .key gen [-N]"
            return Invoke-SshAccessKeyGenerate `
                -Context $Context `
                -NoPassphrase ($Options.ContainsKey('-N'))
        }
        'fp' {
            Assert-SshAccessNoArguments -Arguments $Rest -Usage "$($Context.CommandName) .key fp"
            return Invoke-SshAccessKeyFingerprint -Context $Context
        }
        'delete' {
            $Switches = Get-SshAccessSwitchSet `
                -Arguments $Rest `
                -Allowed @('--yes', '--uac') `
                -Usage "$($Context.CommandName) .key delete --yes [--uac]"
            if (-not $Switches.ContainsKey('--yes')) {
                throw "Deletion requires --yes. Usage: $($Context.CommandName) .key delete --yes [--uac]"
            }
            return Invoke-SshAccessKeyDelete `
                -Context $Context `
                -Uac ($Switches.ContainsKey('--uac'))
        }
        default {
            throw "Unknown .key command '$($Arguments[0])'."
        }
    }
}
