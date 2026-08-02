Set-StrictMode -Version 2.0

function Resolve-RdpClientHostAlias {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $Alias = $Value.Trim()
    if ([Uri]::CheckHostName($Alias) -ne [UriHostNameType]::Dns) {
        throw 'RDP_HOST_ALIAS must be a valid DNS host name without a port.'
    }
    return $Alias
}

function Split-RdpClientFullAddress {
    param([Parameter(Mandatory = $true)][string]$Address)

    $Value = $Address.Trim()
    if ($Value.Length -eq 0) {
        throw 'The full address RDP property cannot be empty.'
    }

    $HostName = $null
    $Port = $null
    $ParsedIp = $null
    if ([Net.IPAddress]::TryParse($Value, [ref]$ParsedIp)) {
        $HostName = $Value
    } elseif ($Value -match '^\[(?<Host>[^\]]+)\](?::(?<Port>[0-9]+))?$') {
        $HostName = $Matches.Host
        if ($Matches.Port.Length -gt 0) {
            $Port = [int]$Matches.Port
        }
    } elseif ($Value -match '^(?<Host>[^:\s]+)(?::(?<Port>[0-9]+))?$') {
        $HostName = $Matches.Host
        if ($Matches.Port.Length -gt 0) {
            $Port = [int]$Matches.Port
        }
    } else {
        throw "Unsupported full address value: $Value"
    }

    if ($null -ne $Port -and ($Port -lt 1 -or $Port -gt 65535)) {
        throw "The RDP port must be between 1 and 65535: $Port"
    }

    return [pscustomobject]@{
        Value = $Value
        Host  = $HostName
        Port  = $Port
    }
}

function Get-RdpClientEmbeddedLines {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) {
        throw "RDP entry file not found: $Path"
    }

    $Lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    $StartPattern = '^\s*goto\s+:RdpClientAfterEmbeddedRdpProperties\s*$'
    $EndPattern = '^\s*:RdpClientAfterEmbeddedRdpProperties\s*$'
    $StartIndexes = @()
    $EndIndexes = @()

    for ($Index = 0; $Index -lt $Lines.Length; $Index++) {
        if ($Lines[$Index] -match $StartPattern) {
            $StartIndexes += $Index
        }
        if ($Lines[$Index] -match $EndPattern) {
            $EndIndexes += $Index
        }
    }

    if ($StartIndexes.Count -ne 1 -or $EndIndexes.Count -ne 1) {
        throw 'The entry must contain exactly one embedded RDP goto and one matching label.'
    }

    $Start = $StartIndexes[0]
    $End = $EndIndexes[0]
    if ($End -le ($Start + 1)) {
        throw 'The embedded RDP block cannot be empty.'
    }
    return @($Lines[($Start + 1)..($End - 1)])
}

function Read-RdpClientEntryDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    $SourceLines = Get-RdpClientEmbeddedLines -Path $Path
    $Properties = New-Object 'Collections.Generic.List[object]'
    $Seen = @{}
    $FullAddress = $null
    $Username = $null

    for ($Index = 0; $Index -lt $SourceLines.Count; $Index++) {
        $Trimmed = $SourceLines[$Index].Trim()
        if ($Trimmed.Length -eq 0 -or $Trimmed.StartsWith('::')) {
            continue
        }
        if ($Trimmed -notmatch '^(?<Name>[^:]+):(?<Type>[sib]):(?<Value>.*)$') {
            throw "Invalid embedded RDP property at block line $($Index + 1): $Trimmed"
        }

        $Name = $Matches.Name.Trim()
        $Type = $Matches.Type.ToLowerInvariant()
        $Value = $Matches.Value
        $Key = $Name.ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) {
            throw "Duplicate embedded RDP property: $Name"
        }
        $Seen[$Key] = $true

        if ($Key -eq 'full address') {
            if ($Type -ne 's') {
                throw 'The full address RDP property must use string type s.'
            }
            $FullAddress = Split-RdpClientFullAddress -Address $Value
        }
        if ($Key -eq 'username') {
            if ($Type -ne 's') {
                throw 'The username RDP property must use string type s.'
            }
            $Username = $Value.Trim()
            if ($Username.Length -eq 0) {
                throw 'The username RDP property cannot be empty.'
            }
        }

        $Properties.Add([pscustomobject]@{
            Name  = $Name
            Key   = $Key
            Type  = $Type
            Value = $Value
        })
    }

    if ($null -eq $FullAddress) {
        throw 'The embedded RDP block must contain full address:s:.'
    }
    if ($null -eq $Username) {
        throw 'The embedded RDP block must contain username:s:.'
    }

    return [pscustomobject]@{
        Properties  = $Properties.ToArray()
        FullAddress = $FullAddress
        Username    = $Username
    }
}

function ConvertTo-RdpClientOutputLines {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Document,
        [AllowEmptyString()][string]$HostAlias
    )

    $Lines = New-Object 'Collections.Generic.List[string]'
    foreach ($Property in $Document.Properties) {
        if (@('signature', 'signscope') -contains $Property.Key) {
            continue
        }

        $Value = $Property.Value
        if ($Property.Key -eq 'full address') {
            $Value = $Document.FullAddress.Value
            if ($HostAlias.Length -gt 0) {
                $Value = $HostAlias
                if ($null -ne $Document.FullAddress.Port) {
                    $Value += ':' + $Document.FullAddress.Port
                }
            }
        }
        $Lines.Add(('{0}:{1}:{2}' -f $Property.Name, $Property.Type, $Value))
    }
    return $Lines.ToArray()
}
