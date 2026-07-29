Set-StrictMode -Version 2.0

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

    $PrivateKeyPath = [Environment]::GetEnvironmentVariable('SSH_ACCESS_PRIVATE_KEY_PATH')
    if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
        throw 'SSH_ACCESS_PRIVATE_KEY_PATH is required.'
    }
    $PrivateKeyPath = [Environment]::ExpandEnvironmentVariables($PrivateKeyPath.Trim())
    if (-not [IO.Path]::IsPathRooted($PrivateKeyPath)) {
        throw 'SSH_ACCESS_PRIVATE_KEY_PATH must be an absolute path.'
    }
    $PrivateKeyPath = [IO.Path]::GetFullPath($PrivateKeyPath)
    if ($PrivateKeyPath.EndsWith('.pub', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SSH_ACCESS_PRIVATE_KEY_PATH must name the private key, not a .pub file.'
    }
    $PublicKeyPath = $PrivateKeyPath + '.pub'

    $UserName = [Environment]::GetEnvironmentVariable('SSH_ACCESS_USER')
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        throw 'SSH_ACCESS_USER is required.'
    }
    $UserName = $UserName.Trim()
    if ($UserName.IndexOfAny([char[]]@('\', '/', '@')) -ge 0) {
        throw 'SSH_ACCESS_USER must be an unqualified local Windows user name.'
    }
    if ($UserName.IndexOfAny([char[]]@('*', '?', '[', ']')) -ge 0) {
        throw 'SSH_ACCESS_USER must be an exact user name, not a wildcard pattern.'
    }

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
        UserName       = $UserName
        KeyType        = $KeyType
        KeyComment     = $KeyComment
        ProgramData    = [IO.Path]::GetFullPath($ProgramData)
        WindowsRoot    = $WindowsPaths.WindowsRoot
        SystemDirectory = $WindowsPaths.SystemDirectory
        NativeSystemDirectory = $WindowsPaths.NativeSystemDirectory
    }
}
