Set-StrictMode -Version 2.0

function Remove-SshAccessSshdConfigComment {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    $InQuotes = $false
    $Escaped = $false
    for ($Index = 0; $Index -lt $Line.Length; $Index++) {
        $Character = $Line[$Index]
        if ($Escaped) {
            $Escaped = $false
            continue
        }
        if ($Character -eq '\' -and $InQuotes) {
            $Escaped = $true
            continue
        }
        if ($Character -eq '"') {
            $InQuotes = -not $InQuotes
            continue
        }
        if ($Character -eq '#' -and -not $InQuotes) {
            return $Line.Substring(0, $Index)
        }
    }
    return $Line
}

function Split-SshAccessSshdConfigFields {
    param([Parameter(Mandatory = $true)][string]$Text)

    $Fields = New-Object Collections.Generic.List[string]
    $Builder = New-Object Text.StringBuilder
    $InQuotes = $false
    $Escaped = $false

    foreach ($Character in $Text.ToCharArray()) {
        if ($Escaped) {
            [void]$Builder.Append($Character)
            $Escaped = $false
            continue
        }
        if ($Character -eq '\' -and $InQuotes) {
            $Escaped = $true
            [void]$Builder.Append($Character)
            continue
        }
        if ($Character -eq '"') {
            $InQuotes = -not $InQuotes
            continue
        }
        if ([char]::IsWhiteSpace($Character) -and -not $InQuotes) {
            if ($Builder.Length -gt 0) {
                $Fields.Add($Builder.ToString())
                [void]$Builder.Clear()
            }
            continue
        }
        [void]$Builder.Append($Character)
    }
    if ($Builder.Length -gt 0) {
        $Fields.Add($Builder.ToString())
    }
    return @($Fields)
}

function Test-SshAccessDefaultUserAuthorizedKeysValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Paths
    )

    if ($Paths.Count -eq 0) {
        return $false
    }
    $FoundPrimary = $false
    foreach ($Path in $Paths) {
        $Normalized = $Path.Trim().Replace('\', '/').ToLowerInvariant()
        if ($Normalized -eq '.ssh/authorized_keys') {
            $FoundPrimary = $true
            continue
        }
        if ($Normalized -ne '.ssh/authorized_keys2') {
            return $false
        }
    }
    return $FoundPrimary
}

function Test-SshAccessDefaultAdministratorAuthorizedKeysValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Paths,
        [Parameter(Mandatory = $true)][pscustomobject]$Context
    )

    if ($Paths.Count -ne 1) {
        return $false
    }
    $Normalized = $Paths[0].Trim().Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    if ($Normalized -eq '__programdata__/ssh/administrators_authorized_keys') {
        return $true
    }
    $Expected = (Join-Path (Join-Path $Context.ProgramData 'ssh') 'administrators_authorized_keys')
    $Expected = $Expected.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    return $Normalized -eq $Expected
}

function Test-SshAccessAdministratorMatch {
    param([Parameter(Mandatory = $true)][string[]]$Fields)

    if ($Fields.Count -ne 3 -or
        -not [string]::Equals($Fields[0], 'match', [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($Fields[1], 'group', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $Group = $Fields[2]
    foreach ($KnownName in @('administrators', 'S-1-5-32-544')) {
        if ([string]::Equals($Group, $KnownName, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    try {
        $AdministratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $LocalizedAccount = $AdministratorsSid.Translate(
            [Security.Principal.NTAccount]
        ).Value
        if ([string]::Equals(
                $Group,
                $LocalizedAccount,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return $true
        }
        $Separator = $LocalizedAccount.LastIndexOf('\')
        return $Separator -ge 0 -and
            [string]::Equals(
                $Group,
                $LocalizedAccount.Substring($Separator + 1),
                [StringComparison]::OrdinalIgnoreCase
            )
    } catch {
        return $false
    }
}

function Get-SshAccessSshdConfigState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][pscustomobject]$Account
    )

    $ConfigPath = Join-Path (Join-Path $Context.ProgramData 'ssh') 'sshd_config'
    $Issues = New-Object Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        if ($Account.IsAdministrator) {
            $Issues.Add(
                'sshd_config is missing, so the Administrators AuthorizedKeysFile mapping cannot be verified.'
            )
        }
        return [pscustomobject]@{
            Path                      = $ConfigPath
            Exists                    = $false
            Compatible                = ($Issues.Count -eq 0)
            AdministratorMappingFound = $false
            Issues                    = @($Issues)
        }
    }

    try {
        $Lines = [IO.File]::ReadAllLines($ConfigPath)
    } catch {
        $Issues.Add("Cannot read sshd_config: $($_.Exception.Message)")
        return [pscustomobject]@{
            Path                      = $ConfigPath
            Exists                    = $true
            Compatible                = $false
            AdministratorMappingFound = $false
            Issues                    = @($Issues)
        }
    }

    $Scope = 'global'
    $AdministratorMappingFound = $false
    for ($LineIndex = 0; $LineIndex -lt $Lines.Length; $LineIndex++) {
        $Content = (Remove-SshAccessSshdConfigComment -Line $Lines[$LineIndex]).Trim()
        if ([string]::IsNullOrWhiteSpace($Content)) {
            continue
        }
        $Fields = @(Split-SshAccessSshdConfigFields -Text $Content)
        if ($Fields.Count -eq 0) {
            continue
        }

        $Directive = $Fields[0].ToLowerInvariant()
        if ($Directive -eq 'include') {
            $Issues.Add("Line $($LineIndex + 1): Include is not supported by this version of SSH Access.")
            continue
        }
        if ($Directive -eq 'match') {
            if ($Fields.Count -eq 2 -and
                [string]::Equals($Fields[1], 'all', [StringComparison]::OrdinalIgnoreCase)) {
                $Scope = 'global'
            } elseif (Test-SshAccessAdministratorMatch -Fields $Fields) {
                $Scope = 'administrators'
            } else {
                $Scope = 'other-match'
            }
            continue
        }
        if ($Directive -ne 'authorizedkeysfile') {
            continue
        }

        $Paths = @($Fields | Select-Object -Skip 1)
        if ($Scope -eq 'global') {
            if (-not (Test-SshAccessDefaultUserAuthorizedKeysValue -Paths $Paths)) {
                $Issues.Add("Line $($LineIndex + 1): non-default global AuthorizedKeysFile is not supported.")
            }
            continue
        }
        if ($Scope -eq 'administrators' -and
            (Test-SshAccessDefaultAdministratorAuthorizedKeysValue -Paths $Paths -Context $Context)) {
            $AdministratorMappingFound = $true
            continue
        }
        $Issues.Add("Line $($LineIndex + 1): conditional or non-default AuthorizedKeysFile is not supported.")
    }

    if ($Account.IsAdministrator -and -not $AdministratorMappingFound) {
        $Issues.Add('The standard Administrators AuthorizedKeysFile mapping is missing.')
    }

    return [pscustomobject]@{
        Path                      = $ConfigPath
        Exists                    = $true
        Compatible                = ($Issues.Count -eq 0)
        AdministratorMappingFound = $AdministratorMappingFound
        Issues                    = @($Issues)
    }
}

function Assert-SshAccessAuthorizedKeysConfiguration {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][pscustomobject]$Account
    )

    $State = Get-SshAccessSshdConfigState -Context $Context -Account $Account
    if (-not $State.Compatible) {
        $Detail = [string]::Join(' ', [string[]]@($State.Issues))
        throw "Unsupported sshd AuthorizedKeysFile configuration in '$($State.Path)'. $Detail"
    }
    return $State
}
