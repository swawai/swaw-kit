Set-StrictMode -Version 2.0

function Test-SshAccessLocalUserIsAdministrator {
    param([Parameter(Mandatory = $true)][string]$UserSid)

    if ($null -eq (Get-Command `
            -Name Get-LocalGroupMember `
            -CommandType Function, Cmdlet `
            -ErrorAction SilentlyContinue)) {
        throw 'The Microsoft.PowerShell.LocalAccounts module is required to inspect local Administrators membership.'
    }

    $AdministratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    try {
        $Members = @(Get-LocalGroupMember -SID $AdministratorsSid -ErrorAction Stop)
    } catch {
        throw "Unable to inspect the built-in Administrators group. $($_.Exception.Message)"
    }

    foreach ($Member in $Members) {
        if ($null -ne $Member.SID -and
            [string]::Equals($Member.SID.Value, $UserSid, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-SshAccessProfilePath {
    param([Parameter(Mandatory = $true)][string]$UserSid)

    $RegistryPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$UserSid"
    try {
        $Profile = Get-ItemProperty -LiteralPath $RegistryPath -Name ProfileImagePath -ErrorAction Stop
    } catch {
        throw "No local profile is registered for user SID '$UserSid'. Sign in as that user once before granting SSH access."
    }

    $ProfilePath = [Environment]::ExpandEnvironmentVariables([string]$Profile.ProfileImagePath).Trim()
    if ([string]::IsNullOrWhiteSpace($ProfilePath) -or -not [IO.Path]::IsPathRooted($ProfilePath)) {
        throw "The registered profile path for user SID '$UserSid' is invalid."
    }
    return [IO.Path]::GetFullPath($ProfilePath)
}

function Resolve-SshAccessLocalUser {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    if ($null -eq (Get-Command `
            -Name Get-LocalUser `
            -CommandType Function, Cmdlet `
            -ErrorAction SilentlyContinue)) {
        throw 'The Microsoft.PowerShell.LocalAccounts module is required to resolve a local Windows user.'
    }

    try {
        $Users = @(
            Get-LocalUser -ErrorAction Stop |
                Where-Object {
                    $null -ne $_.SID -and
                    [string]::Equals(
                        $_.SID.Value,
                        $Context.AuthorizationUserSid,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
    } catch {
        throw (
            "Windows identity '$($Context.AuthorizationUserName)' " +
            "($($Context.AuthorizationUserSid)) " +
            'is not a supported local user. Domain and Entra users are not supported.'
        )
    }
    if ($Users.Count -ne 1 -or
        $null -eq $Users[0].SID) {
        throw (
            "Windows identity '$($Context.AuthorizationUserName)' " +
            "($($Context.AuthorizationUserSid)) " +
            'did not resolve to exactly one local Windows user. ' +
            'Domain and Entra users are not supported.'
        )
    }

    $User = $Users[0]
    $UserSid = $User.SID.Value
    $IsAdministrator = Test-SshAccessLocalUserIsAdministrator -UserSid $UserSid
    $CurrentIdentity = Get-SshAccessRequiredCurrentProcessIdentity
    $CurrentUserSid = $CurrentIdentity.Sid
    $IsCurrentUser = [string]::Equals($CurrentUserSid, $UserSid, [StringComparison]::OrdinalIgnoreCase)
    $ProfilePath = $null
    if (-not $IsAdministrator) {
        $ProfilePath = Get-SshAccessProfilePath -UserSid $UserSid
    }

    $AuthorizedKeysPath = if ($IsAdministrator) {
        Join-Path (Join-Path $Context.ProgramData 'ssh') 'administrators_authorized_keys'
    } else {
        Join-Path (Join-Path $ProfilePath '.ssh') 'authorized_keys'
    }

    return [pscustomobject]@{
        Name               = $User.Name
        Sid                = $UserSid
        Enabled            = [bool]$User.Enabled
        IsAdministrator    = $IsAdministrator
        IsCurrentUser      = $IsCurrentUser
        ProfilePath        = $ProfilePath
        AuthorizedKeysPath = [IO.Path]::GetFullPath($AuthorizedKeysPath)
    }
}
