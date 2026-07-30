Set-StrictMode -Version 2.0

function Get-SshAccessCurrentProcessIdentity {
    try {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if ($null -eq $Identity -or $null -eq $Identity.User) {
                throw 'The current Windows process identity has no user SID.'
            }
            $Name = [string]$Identity.Name
            if ([string]::IsNullOrWhiteSpace($Name)) {
                $Name = $Identity.User.Value
            }
            return [pscustomobject]@{
                Name  = $Name
                Sid   = $Identity.User.Value
                Error = ''
            }
        } finally {
            if ($null -ne $Identity) {
                $Identity.Dispose()
            }
        }
    } catch {
        return [pscustomobject]@{
            Name  = 'unknown'
            Sid   = 'unknown'
            Error = $_.Exception.Message
        }
    }
}

function Get-SshAccessRequiredCurrentProcessIdentity {
    $Identity = Get-SshAccessCurrentProcessIdentity
    if (-not [string]::IsNullOrWhiteSpace($Identity.Error)) {
        throw "Unable to resolve the current Windows user. $($Identity.Error)"
    }
    return $Identity
}

function Get-SshAccessAuthorizationOriginIdentity {
    $Name = [Environment]::GetEnvironmentVariable(
        'SSH_ACCESS_ORIGIN_USER_NAME'
    )
    $SidText = [Environment]::GetEnvironmentVariable(
        'SSH_ACCESS_ORIGIN_USER_SID'
    )
    $HasName = -not [string]::IsNullOrWhiteSpace($Name)
    $HasSid = -not [string]::IsNullOrWhiteSpace($SidText)
    if (-not $HasName -and -not $HasSid) {
        return Get-SshAccessRequiredCurrentProcessIdentity
    }
    if (-not $HasName -or -not $HasSid) {
        throw 'The internal SSH Access authorization identity is incomplete.'
    }

    $Name = $Name.Trim()
    if ($Name.IndexOfAny([char[]]@("`r", "`n", [char]0)) -ge 0) {
        throw 'The internal SSH Access authorization user name is invalid.'
    }
    try {
        $Sid = New-Object Security.Principal.SecurityIdentifier($SidText.Trim())
    } catch {
        throw 'The internal SSH Access authorization user SID is invalid.'
    }
    return [pscustomobject]@{
        Name  = $Name
        Sid   = $Sid.Value
        Error = ''
    }
}

function Get-SshAccessCommandName {
    $CommandName = [Environment]::GetEnvironmentVariable('SSH_ACCESS_ENTRY_COMMAND')
    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        return 'sshaccess'
    }
    return $CommandName.Trim()
}

function Get-SshAccessEntryFileName {
    $EntryFile = [Environment]::GetEnvironmentVariable('SSH_ACCESS_ENTRY_FILE')
    if ([string]::IsNullOrWhiteSpace($EntryFile)) {
        return Get-SshAccessCommandName
    }

    try {
        $FileName = [IO.Path]::GetFileName(
            [Environment]::ExpandEnvironmentVariables($EntryFile.Trim())
        )
        if (-not [string]::IsNullOrWhiteSpace($FileName)) {
            return $FileName
        }
    } catch {
        # Help remains available even if an embedding caller supplied a bad path.
    }
    return Get-SshAccessCommandName
}

function New-SshAccessHelpContext {
    param([Parameter(Mandatory = $true)][string]$KitRoot)

    return [pscustomobject]@{
        CommandName   = Get-SshAccessCommandName
        EntryFileName = Get-SshAccessEntryFileName
        HelpRoot      = Join-Path $KitRoot 'help'
    }
}

function Assert-SshAccessEntryProtocol {
    $Protocol = [Environment]::GetEnvironmentVariable('SSH_ACCESS_PROTOCOL')
    if ($Protocol -ne '1') {
        throw 'Unsupported or missing SSH_ACCESS_PROTOCOL. Run this kit through an SSH access entry command.'
    }
}

function New-SshAccessContext {
    param([Parameter(Mandatory = $true)][string]$KitRoot)

    Assert-SshAccessEntryProtocol

    $PublicKeyPath = [Environment]::GetEnvironmentVariable('SSH_ACCESS_PUBLIC_KEY_PATH')
    if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
        throw 'SSH_ACCESS_PUBLIC_KEY_PATH is required.'
    }
    $PublicKeyPath = [Environment]::ExpandEnvironmentVariables($PublicKeyPath.Trim())
    if (-not [IO.Path]::IsPathRooted($PublicKeyPath)) {
        throw 'SSH_ACCESS_PUBLIC_KEY_PATH must be an absolute path.'
    }
    $PublicKeyPath = [IO.Path]::GetFullPath($PublicKeyPath)
    if (-not $PublicKeyPath.EndsWith('.pub', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals(
            (Split-Path -Leaf $PublicKeyPath),
            '.pub',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'SSH_ACCESS_PUBLIC_KEY_PATH must name a .pub file with a non-empty base name.'
    }
    $PrivateKeyPath = $PublicKeyPath.Substring(0, $PublicKeyPath.Length - 4)

    $OriginIdentity = Get-SshAccessAuthorizationOriginIdentity

    $KeyType = [Environment]::GetEnvironmentVariable('SSH_ACCESS_KEY_TYPE')
    if ([string]::IsNullOrWhiteSpace($KeyType)) {
        $KeyType = 'ed25519'
    }
    $KeyType = $KeyType.Trim().ToLowerInvariant()
    if (@('ed25519', 'ecdsa', 'rsa') -notcontains $KeyType) {
        throw "Unsupported SSH_ACCESS_KEY_TYPE '$KeyType'. Supported values: ed25519, ecdsa, rsa."
    }

    $KeyComment = [Environment]::GetEnvironmentVariable('SSH_ACCESS_KEY_COMMENT')
    if ($null -eq $KeyComment) {
        $KeyComment = ''
    }
    if ($KeyComment.IndexOfAny([char[]]@("`r", "`n", [char]0)) -ge 0) {
        throw 'SSH_ACCESS_KEY_COMMENT must be a single line.'
    }

    $EntryFile = [Environment]::GetEnvironmentVariable('SSH_ACCESS_ENTRY_FILE')
    if (-not [string]::IsNullOrWhiteSpace($EntryFile)) {
        $EntryFile = [Environment]::ExpandEnvironmentVariables($EntryFile.Trim())
        if ([IO.Path]::IsPathRooted($EntryFile)) {
            $EntryFile = [IO.Path]::GetFullPath($EntryFile)
        }
    }

    $WindowsPaths = Get-SshAccessTrustedWindowsPaths
    $ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($ProgramData) -or -not [IO.Path]::IsPathRooted($ProgramData)) {
        throw 'The Windows common application data path is unavailable or invalid.'
    }

    return [pscustomobject]@{
        Protocol       = 1
        CommandName    = Get-SshAccessCommandName
        EntryFile      = $EntryFile
        KitRoot        = $KitRoot
        KitCommand     = Join-Path $KitRoot 'kit.cmd'
        KitScript      = Join-Path $KitRoot 'kit.ps1'
        HelpRoot       = Join-Path $KitRoot 'help'
        PrivateKeyPath = $PrivateKeyPath
        PublicKeyPath  = $PublicKeyPath
        AuthorizationUserName = $OriginIdentity.Name
        AuthorizationUserSid  = $OriginIdentity.Sid
        KeyType        = $KeyType
        KeyComment     = $KeyComment
        ProgramData    = [IO.Path]::GetFullPath($ProgramData)
        WindowsRoot    = $WindowsPaths.WindowsRoot
        SystemDirectory = $WindowsPaths.SystemDirectory
        NativeSystemDirectory = $WindowsPaths.NativeSystemDirectory
    }
}
