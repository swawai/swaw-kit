Set-StrictMode -Version 2.0

function Get-SshAccessPublicState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $State = [ordered]@{
        Domain             = 'public'
        UserName           = $Context.AuthorizationUserName
        UserSid            = $null
        UserEnabled        = $null
        IsAdministrator    = $null
        IsCurrentUser      = $null
        Shared             = $null
        AuthorizedKeysPath = $null
        PublicKeyPath      = $Context.PublicKeyPath
        PublicKeyExists    = (Test-Path -LiteralPath $Context.PublicKeyPath -PathType Leaf)
        Authorization      = 'unknown'
        Granted            = $null
        MatchCount         = $null
        DirectMatchCount   = $null
        OptionBoundCount   = $null
        ConfigPath         = $null
        ConfigCompatible   = $null
        KeyAuthentication  = $null
        Error              = $null
    }

    try {
        $Account = Resolve-SshAccessLocalUser -Context $Context
        $State.UserName = $Account.Name
        $State.UserSid = $Account.Sid
        $State.UserEnabled = $Account.Enabled
        $State.IsAdministrator = $Account.IsAdministrator
        $State.IsCurrentUser = $Account.IsCurrentUser
        $State.Shared = $Account.IsAdministrator
        $State.AuthorizedKeysPath = $Account.AuthorizedKeysPath

        $ConfigState = Get-SshAccessSshdConfigState -Context $Context -Account $Account
        $State.ConfigPath = $ConfigState.Path
        $State.ConfigCompatible = $ConfigState.Compatible
        $State.KeyAuthentication = $ConfigState.PublicKeyAuthentication
        $ConfigurationError = if ($ConfigState.Compatible) {
            $null
        } else {
            [string]::Join(' ', [string[]]@($ConfigState.Issues))
        }
        if (-not $ConfigState.AuthorizedKeysCompatible) {
            $State.Error = $ConfigurationError
        } elseif ($State.PublicKeyExists) {
            $Key = Get-SshAccessBoundPublicKey -Context $Context
            $References = Get-SshAccessAuthorizedKeyReferenceState `
                -Path $Account.AuthorizedKeysPath `
                -Key $Key
            $State.MatchCount = $References.IdentityReferenceCount
            $State.DirectMatchCount = $References.PlainAuthorizationCount
            $State.OptionBoundCount = $References.OptionBoundReferenceCount
            $State.Granted = ($References.PlainAuthorizationCount -gt 0)
            $State.Authorization = switch ($References.State) {
                'plain' { 'granted' }
                'option-bound' { 'option-bound' }
                'ambiguous' { 'ambiguous' }
                default { 'not-granted' }
            }
            if ($References.State -eq 'option-bound') {
                $State.Error = 'The bound public-key identity is still referenced only by option-bound authorized_keys line(s).'
            } elseif ($References.State -eq 'ambiguous') {
                $State.Error = 'The bound public-key identity has both plain and option-bound authorized_keys references.'
            }
        } else {
            $State.MatchCount = 0
            $State.DirectMatchCount = 0
            $State.OptionBoundCount = 0
            $State.Granted = $false
            $State.Authorization = 'not-granted'
        }
        if (-not [string]::IsNullOrWhiteSpace($ConfigurationError) -and
            [string]::IsNullOrWhiteSpace($State.Error)) {
            $State.Error = $ConfigurationError
        } elseif (-not [string]::IsNullOrWhiteSpace($ConfigurationError) -and
            -not $State.Error.Contains($ConfigurationError)) {
            $State.Error += [Environment]::NewLine + $ConfigurationError
        }
    } catch {
        if (Test-SshAccessAccessDeniedError -ErrorRecord $_) {
            $ErrorLines = New-Object Collections.Generic.List[string]
            $ErrorLines.Add('Access denied while reading SSH authorization.')
            if (-not [string]::IsNullOrWhiteSpace($State.AuthorizedKeysPath)) {
                $ErrorLines.Add(
                    "  Authorization file: $($State.AuthorizedKeysPath)"
                )
            }
            if (-not (Test-SshAccessAdministrator)) {
                $Retry = Format-SshAccessCommand `
                    -CommandName $Context.CommandName `
                    -Arguments @('.status', 'public', '--uac')
                $ErrorLines.Add("  Retry: $Retry")
            }
            $State.Error = [string]::Join(
                [Environment]::NewLine,
                [string[]]$ErrorLines
            )
        } else {
            $State.Error = $_.Exception.Message
        }
    }

    return [pscustomobject]$State
}

function Show-SshAccessPublicState {
    [CmdletBinding(DefaultParameterSetName = 'Context')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Context')]
        [pscustomobject]$Context,
        [Parameter(Mandatory = $true, ParameterSetName = 'State')]
        [pscustomobject]$State
    )

    if ($PSCmdlet.ParameterSetName -eq 'Context') {
        $State = Get-SshAccessPublicState -Context $Context
    }

    Write-SshAccessHeading 'Public access'
    Write-SshAccessField -Name 'User' -Value $State.UserName
    Write-SshAccessField -Name 'User SID' -Value $State.UserSid
    Write-SshAccessField -Name 'User enabled' -Value $State.UserEnabled
    Write-SshAccessField -Name 'Administrators' -Value $State.IsAdministrator
    Write-SshAccessField -Name 'Authorized keys' -Value $State.AuthorizedKeysPath
    Write-SshAccessField -Name 'Authorization' -Value $State.Authorization
    Write-SshAccessField -Name 'Identity references' -Value $State.MatchCount
    Write-SshAccessField -Name 'Direct matches' -Value $State.DirectMatchCount
    Write-SshAccessField -Name 'Option-bound matches' -Value $State.OptionBoundCount
    Write-SshAccessField -Name 'Config compatible' -Value $State.ConfigCompatible
    Write-SshAccessField -Name 'Key authentication' -Value $State.KeyAuthentication
    if ($State.Shared -eq $true) {
        Write-SshAccessWarning 'This authorization file is shared by every member of the built-in Administrators group.'
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Error)) {
        Write-SshAccessWarning $State.Error
    }
}

function Invoke-SshAccessPublicMutation {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('grant', 'revoke')][string]$Operation,
        [Parameter(Mandatory = $true)][bool]$Uac
    )

    $Account = Resolve-SshAccessLocalUser -Context $Context
    if (-not $Account.IsAdministrator -and -not $Account.IsCurrentUser) {
        throw (
            "SSH Access v1 refuses to modify another ordinary user's profile. " +
            "Run the entry as local user '$($Account.Name)', or manage that user's authorized_keys manually."
        )
    }
    if ($Operation -eq 'grant' -and -not $Account.Enabled) {
        throw "Local Windows user '$($Account.Name)' is disabled."
    }

    if ($Account.IsAdministrator) {
        $ElevatedExitCode = Invoke-SshAccessAdminCommand `
            -Context $Context `
            -Arguments @('.public', $Operation) `
            -Uac $Uac
        if ($null -ne $ElevatedExitCode) {
            return [int]$ElevatedExitCode
        }
    }

    [void](Assert-SshAccessAuthorizedKeysConfiguration `
        -Context $Context `
        -Account $Account `
        -RequirePublicKeyAuthentication ($Operation -eq 'grant'))
    if ($Operation -eq 'grant' -and
        (Test-Path -LiteralPath $Context.PrivateKeyPath -PathType Leaf)) {
        $KeyState = Get-SshAccessKeyState -Context $Context
        if ($KeyState.PairConsistency -ne 'matching') {
            throw "The bound private and public keys do not match or could not be verified. $($KeyState.Error)"
        }
    }
    $Key = Get-SshAccessBoundPublicKey -Context $Context
    if ($Account.IsAdministrator) {
        Write-SshAccessWarning 'This authorization file is shared by every member of the built-in Administrators group.'
    }

    if ($Operation -eq 'grant') {
        $Result = Add-SshAccessAuthorizedKey -Account $Account -Key $Key
        if ($Result.Changed) {
            Write-Host "Granted the bound public key to local user '$($Account.Name)'."
        } else {
            Write-Host "The bound public key is already granted to local user '$($Account.Name)'."
        }
        Write-Host "  $($Account.AuthorizedKeysPath)"
        return 0
    }

    $Result = Remove-SshAccessAuthorizedKey -Account $Account -Key $Key
    if ($Result.Changed) {
        Write-Host (
            "Revoked $($Result.MatchCount) public-key identity reference(s) " +
            "($($Result.PlainMatchCount) plain, $($Result.OptionBoundMatchCount) option-bound) " +
            "from local user '$($Account.Name)'."
        )
    } else {
        Write-Host "The bound public-key identity has no plain or option-bound reference for local user '$($Account.Name)'."
    }
    Write-Host "  $($Account.AuthorizedKeysPath)"
    return 0
}

function Invoke-SshAccessPublicCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = "$($Context.CommandName) .public <grant|revoke> [--uac]"
    if ($Arguments.Count -eq 0) {
        throw "Missing public command. Usage: $Usage"
    }
    $Operation = $Arguments[0].ToLowerInvariant()
    if (@('grant', 'revoke') -notcontains $Operation) {
        throw "Unknown public command '$($Arguments[0])'. Usage: $Usage"
    }

    $Options = Get-SshAccessSwitchSet `
        -Arguments @($Arguments | Select-Object -Skip 1) `
        -Allowed @('--uac') `
        -Usage "$($Context.CommandName) .public $Operation [--uac]"
    $Uac = $Options.ContainsKey('--uac')
    return Invoke-SshAccessPublicMutation -Context $Context -Operation $Operation -Uac $Uac
}
