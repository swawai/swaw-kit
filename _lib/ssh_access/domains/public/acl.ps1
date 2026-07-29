Set-StrictMode -Version 2.0

function Assert-SshAccessPathIsNotReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    try {
        $Attributes = [IO.File]::GetAttributes($Path)
    } catch [IO.FileNotFoundException] {
        return
    } catch [IO.DirectoryNotFoundException] {
        return
    }
    if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse point as $Description`: $Path"
    }
}

function New-SshAccessFileAccessRule {
    param(
        [Parameter(Mandatory = $true)][Security.Principal.SecurityIdentifier]$Sid,
        [Parameter(Mandatory = $true)][Security.AccessControl.FileSystemRights]$Rights,
        [Security.AccessControl.InheritanceFlags]$InheritanceFlags = [Security.AccessControl.InheritanceFlags]::None
    )

    return New-Object Security.AccessControl.FileSystemAccessRule(
        $Sid,
        $Rights,
        $InheritanceFlags,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
}

function New-SshAccessAuthorizedKeysSecurity {
    param([Parameter(Mandatory = $true)][pscustomobject]$Account)

    $SystemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $AdministratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $UserSid = New-Object Security.Principal.SecurityIdentifier($Account.Sid)

    $Security = New-Object Security.AccessControl.FileSecurity
    $Security.SetAccessRuleProtection($true, $false)
    if ($Account.IsAdministrator) {
        $Security.SetOwner($AdministratorsSid)
        [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $SystemSid -Rights FullControl))
        [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $AdministratorsSid -Rights FullControl))
    } else {
        $Security.SetOwner($UserSid)
        [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $UserSid -Rights FullControl))
        [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $SystemSid -Rights FullControl))
        [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $AdministratorsSid -Rights FullControl))
    }
    return $Security
}

function Set-SshAccessAuthorizedKeysAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Account
    )

    $Security = New-SshAccessAuthorizedKeysSecurity -Account $Account
    $File = New-Object IO.FileInfo($Path)
    $File.SetAccessControl($Security)
}

function New-SshAccessSshDirectorySecurity {
    param([Parameter(Mandatory = $true)][pscustomobject]$Account)

    $SystemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $AdministratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $UserSid = New-Object Security.Principal.SecurityIdentifier($Account.Sid)
    $Inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit

    $Security = New-Object Security.AccessControl.DirectorySecurity
    $Security.SetAccessRuleProtection($true, $false)
    $Security.SetOwner($UserSid)
    [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $UserSid -Rights FullControl -InheritanceFlags $Inheritance))
    [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $SystemSid -Rights FullControl -InheritanceFlags $Inheritance))
    [void]$Security.AddAccessRule((New-SshAccessFileAccessRule -Sid $AdministratorsSid -Rights FullControl -InheritanceFlags $Inheritance))
    return $Security
}

function Initialize-SshAccessAuthorizedKeysDirectory {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Account
    )

    $Directory = Split-Path -Parent $Account.AuthorizedKeysPath
    Assert-SshAccessPathIsNotReparsePoint -Path $Directory -Description 'the authorized_keys directory'
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        return
    }

    if (-not $Account.IsAdministrator) {
        if (-not (Test-Path -LiteralPath $Account.ProfilePath -PathType Container)) {
            throw "The local profile directory does not exist: $($Account.ProfilePath)"
        }
        [void](New-Item -ItemType Directory -Path $Directory -ErrorAction Stop)
        Assert-SshAccessPathIsNotReparsePoint -Path $Directory -Description 'the .ssh directory'
        $Security = New-SshAccessSshDirectorySecurity -Account $Account
        $DirectoryInfo = New-Object IO.DirectoryInfo($Directory)
        $DirectoryInfo.SetAccessControl($Security)
        return
    }

    [void](New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop)
    Assert-SshAccessPathIsNotReparsePoint -Path $Directory -Description 'the OpenSSH configuration directory'
}
